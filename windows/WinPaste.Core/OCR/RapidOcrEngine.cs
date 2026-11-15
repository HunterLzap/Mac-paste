using RapidOcrNet;
using SkiaSharp;
using WinPaste.Core.Models;

namespace WinPaste.Core.OCR;

/// <summary>
/// 基于 RapidOcrNet (PP-OCRv5 / 可选 PP-OCRv6 多语言 ONNX) 的本地离线 OCR 引擎。
/// 内部使用 OcrImagePreprocessor 进行高分辨率暗底/小图增强，并输出归一化左上角坐标碎片。
/// </summary>
public sealed class RapidOcrEngine : IOcrEngine, IDisposable
{
    private readonly SemaphoreSlim _initLock = new(1, 1);
    private readonly object _inferLock = new();
    private RapidOcr? _ocr;
    private RapidOcrOptions _options = RapidOcrOptions.Default;
    private bool _disposed;

    public async Task<IReadOnlyList<OcrRawFragment>> RecognizeFragmentsAsync(
        SKBitmap bitmap,
        CancellationToken cancellationToken = default)
    {
        if (_disposed || bitmap.Width <= 0 || bitmap.Height <= 0)
            return [];

        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        if (_ocr == null)
            return [];

        return await Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();

            using SKBitmap? preprocessed = OcrImagePreprocessor.Preprocess(bitmap);
            SKBitmap target = preprocessed ?? bitmap;
            int w = target.Width;
            int h = target.Height;
            if (w <= 0 || h <= 0)
                return (IReadOnlyList<OcrRawFragment>)[];

            OcrResult result;
            lock (_inferLock)
            {
                cancellationToken.ThrowIfCancellationRequested();
                result = _ocr.Detect(target, _options);
            }

            if (result.TextBlocks == null || result.TextBlocks.Length == 0)
                return [];

            var fragments = new List<OcrRawFragment>(result.TextBlocks.Length);
            foreach (var tb in result.TextBlocks)
            {
                string text = (tb.Text ?? string.Empty).Trim();
                if (string.IsNullOrEmpty(text) || tb.BoxPoints == null || tb.BoxPoints.Length == 0)
                    continue;

                float minX = float.MaxValue, minY = float.MaxValue;
                float maxX = float.MinValue, maxY = float.MinValue;
                foreach (var pt in tb.BoxPoints)
                {
                    if (pt.X < minX) minX = pt.X;
                    if (pt.Y < minY) minY = pt.Y;
                    if (pt.X > maxX) maxX = pt.X;
                    if (pt.Y > maxY) maxY = pt.Y;
                }

                double nx = Math.Clamp(minX / w, 0.0, 1.0);
                double ny = Math.Clamp(minY / h, 0.0, 1.0);
                double nw = Math.Clamp((maxX - minX) / w, 0.0, 1.0 - nx);
                double nh = Math.Clamp((maxY - minY) / h, 0.0, 1.0 - ny);
                if (nw <= 0 || nh <= 0)
                    continue;

                fragments.Add(new OcrRawFragment(text, new NormRect(nx, ny, nw, nh)));
            }

            return (IReadOnlyList<OcrRawFragment>)fragments;
        }, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<OcrTextBlock>> RecognizeTextBlocksAsync(
        SKBitmap bitmap,
        IEnglishSpellChecker? spellChecker = null,
        CancellationToken cancellationToken = default)
    {
        var frags = await RecognizeFragmentsAsync(bitmap, cancellationToken).ConfigureAwait(false);
        return OcrBlockSegmenter.SegmentBlocks(frags, bitmap.Width, bitmap.Height, spellChecker);
    }

    public async Task<IReadOnlyList<string>> RecognizeLinesAsync(
        SKBitmap bitmap,
        CancellationToken cancellationToken = default)
    {
        var frags = await RecognizeFragmentsAsync(bitmap, cancellationToken).ConfigureAwait(false);
        return frags
            .OrderBy(f => f.TopLeftBox.MinY)
            .ThenBy(f => f.TopLeftBox.MinX)
            .Select(f => f.Text)
            .Where(t => !string.IsNullOrWhiteSpace(t))
            .ToList();
    }

    private async Task EnsureInitializedAsync(CancellationToken cancellationToken)
    {
        if (_ocr != null)
            return;

        await _initLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_ocr != null)
                return;

            await Task.Run(() =>
            {
                var ocr = new RapidOcr();

                // 1) 若存在 PP-OCRv6 多语言模型（支持中英日韩混合），优先加载
                if (TryFindV6Models(out var v6Set))
                {
                    ocr.InitModels(v6Set);
                    _options = RapidOcrOptions.PPOCRv6 with { DoAngle = false };
                }
                else if (TryFindCustomCjkV5Models(out string det, out string cls, out string rec, out string dict))
                {
                    ocr.InitModels(det, cls, rec, dict);
                    _options = RapidOcrOptions.Default with { DoAngle = false, ImgResize = 2048 };
                }
                else
                {
                    // 2) 使用 NuGet 内置默认 PP-OCRv5 模型（通过 AppContext.BaseDirectory 绝对路径定位，防开机自启工作目录偏移）
                    string v5Det = ResolveV5File("ch_PP-OCRv5_mobile_det.onnx");
                    string v5Cls = ResolveV5File("ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx");
                    string v5Rec = ResolveV5File("latin_PP-OCRv5_rec_mobile_infer.onnx");
                    string v5Dict = ResolveV5File("ppocrv5_latin_dict.txt");
                    if (File.Exists(v5Det) && File.Exists(v5Cls) && File.Exists(v5Rec) && File.Exists(v5Dict))
                        ocr.InitModels(v5Det, v5Cls, v5Rec, v5Dict);
                    else
                        ocr.InitModels();

                    _options = RapidOcrOptions.Default with { DoAngle = false, ImgResize = 2048 };
                }

                _ocr = ocr;
            }, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _initLock.Release();
        }
    }

    private static bool TryFindV6Models(out RapidOcrModelSet modelSet)
    {
        string[] candidateRoots =
        [
            Path.Combine(AppContext.BaseDirectory, "models", "v6"),
            Path.Combine(AppPaths.Default.OcrModelsDir, "v6")
        ];

        foreach (string dir in candidateRoots)
        {
            string det = Path.Combine(dir, "PP-OCRv6_det_small.onnx");
            string rec = Path.Combine(dir, "PP-OCRv6_rec_small.onnx");
            string dict = Path.Combine(dir, "ppocrv6_small_dict.txt");
            if (File.Exists(det) && File.Exists(rec) && File.Exists(dict))
            {
                string cls = Path.Combine(AppContext.BaseDirectory, "models", "v5", "ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx");
                if (!File.Exists(cls))
                    cls = Path.Combine(AppPaths.Default.OcrModelsDir, "v5", "ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx");

                modelSet = File.Exists(cls)
                    ? RapidOcrModelSet.PPOCRv6Small with
                    {
                        DetModelPath = det,
                        ClsModelPath = cls,
                        RecModelPath = rec,
                        KeysPath = dict
                    }
                    : RapidOcrModelSet.PPOCRv6Small with
                    {
                        DetModelPath = det,
                        RecModelPath = rec,
                        KeysPath = dict
                    };
                return true;
            }
        }

        modelSet = RapidOcrModelSet.PPOCRv6Small;
        return false;
    }

    private static bool TryFindCustomCjkV5Models(
        out string detPath,
        out string clsPath,
        out string recPath,
        out string dictPath)
    {
        string[] candidateRoots =
        [
            Path.Combine(AppContext.BaseDirectory, "models", "v5"),
            Path.Combine(AppPaths.Default.OcrModelsDir, "v5")
        ];

        foreach (string dir in candidateRoots)
        {
            string det = Path.Combine(dir, "ch_PP-OCRv5_mobile_det.onnx");
            string cls = Path.Combine(dir, "ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx");
            string rec = Path.Combine(dir, "ch_PP-OCRv5_rec_mobile_infer.onnx");
            string dict = Path.Combine(dir, "ppocrv5_dict.txt");
            if (!File.Exists(dict))
                dict = Path.Combine(dir, "ppocr_keys_v1.txt");

            if (File.Exists(det) && File.Exists(cls) && File.Exists(rec) && File.Exists(dict))
            {
                detPath = det;
                clsPath = cls;
                recPath = rec;
                dictPath = dict;
                return true;
            }
        }

        detPath = clsPath = recPath = dictPath = string.Empty;
        return false;
    }

    private static string ResolveV5File(string fileName)
    {
        string baseCandidate = Path.Combine(AppContext.BaseDirectory, "models", "v5", fileName);
        if (File.Exists(baseCandidate))
            return baseCandidate;

        string supportCandidate = Path.Combine(AppPaths.Default.OcrModelsDir, "v5", fileName);
        if (File.Exists(supportCandidate))
            return supportCandidate;

        return Path.Combine("models", "v5", fileName);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _ocr?.Dispose();
        _ocr = null;
        _initLock.Dispose();
    }
}
