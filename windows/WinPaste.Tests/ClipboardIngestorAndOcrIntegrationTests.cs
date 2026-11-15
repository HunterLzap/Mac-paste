using SkiaSharp;
using WinPaste.Core.Imaging;
using WinPaste.Core.Models;
using WinPaste.Core.OCR;
using WinPaste.Core.Storage;
using Xunit;

namespace WinPaste.Tests;

public sealed class ClipboardIngestorAndOcrIntegrationTests : IDisposable
{
    private readonly string _tempDir;
    private readonly AppPaths _paths;
    private readonly HistoryStore _store;

    public ClipboardIngestorAndOcrIntegrationTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "WinPasteInteg_" + Guid.NewGuid().ToString("N"));
        _paths = new AppPaths(_tempDir);
        _paths.EnsureDirectories();
        _store = new HistoryStore(_paths, () => 200);
    }

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    [Fact]
    public void ClipboardIngestor_PrioritizesFilesThenHtmlThenTsvThenTextAndSuppressesInternalWrites()
    {
        var ingestor = new ClipboardIngestor(_store, _paths);

        // Internal sequence suppressed
        ingestor.MarkInternalWrite(sequenceNumber: 10, text: "self copy");
        Assert.Null(ingestor.IngestSnapshot(10, text: "self copy"));

        // Internal hash suppressed even on later sequence
        Assert.Null(ingestor.IngestSnapshot(11, text: "self copy"));

        // File paths take priority over text
        var kFile = ingestor.IngestSnapshot(
            12,
            filePaths: ["C:\\work\\a.png", "C:\\work\\b.txt"],
            text: "ignored");
        Assert.Equal(ClipboardKind.ShortText, kFile);

        // HTML table parsed as Table even if plain text also exists
        var kHtml = ingestor.IngestSnapshot(
            13,
            html: "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>",
            text: "A B 1 2");
        Assert.Equal(ClipboardKind.Table, kHtml);

        // TSV parsed as Table
        var kTsv = ingestor.IngestSnapshot(14, text: "Name\tScore\nAlice\t98\nBob\t95");
        Assert.Equal(ClipboardKind.Table, kTsv);

        // Long text > 100 chars stored as LongText
        string longStr = new('X', 150);
        Assert.Equal(ClipboardKind.LongText, ingestor.IngestSnapshot(15, text: longStr));
    }

    [Fact]
    public async Task RapidOcrEngine_EndToEndRecognition_And_InPlacePipeline()
    {
        using var bmp = new SKBitmap(520, 180, SKColorType.Bgra8888, SKAlphaType.Premul);
        using (var canvas = new SKCanvas(bmp))
        {
            canvas.Clear(new SKColor(246, 248, 252));
            using var font = new SKFont(SKTypeface.Default, 32);
            using var paint = new SKPaint { IsAntialias = true, Color = new SKColor(24, 28, 35) };
            canvas.DrawText("WinPaste OCR Engine Ready", 36, 76, font, paint);
            canvas.DrawText("Translation Test 2026", 36, 128, font, paint);
        }

        using var ocr = new RapidOcrEngine();
        var blocks = await ocr.RecognizeTextBlocksAsync(bmp, EnglishSpellChecker.Shared);

        Assert.NotEmpty(blocks);
        string combined = string.Join(" ", blocks.Select(b => b.Text));
        Assert.Contains("WinPaste", combined, StringComparison.OrdinalIgnoreCase);

        // Feed recognized blocks into style detector + two-pass renderer
        var sampler = new ScreenBitmapSampler(bmp);
        var sel = new ScreenshotRect(0, 0, bmp.Width, bmp.Height);
        var translated = blocks
            .Select((b, idx) => InPlaceStyleDetector.Detect(idx, b, $"译文块 {idx + 1}", sampler, sel))
            .ToList();

        using var outBmp = ScreenshotRenderer.RenderExportBitmap(bmp, sel, [], translated);
        Assert.Equal(bmp.Width, outBmp.Width);
        Assert.Equal(bmp.Height, outBmp.Height);
    }

    [Fact]
    public void RapidOcrEngine_ExtractsEmbeddedV5Models_ForStandaloneSingleFileExe()
    {
        string[] modelFiles =
        [
            "ch_PP-OCRv5_mobile_det.onnx",
            "ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx",
            "latin_PP-OCRv5_rec_mobile_infer.onnx",
            "ppocrv5_latin_dict.txt"
        ];

        string destDir = Path.Combine(_tempDir, "extracted-v5");
        foreach (string file in modelFiles)
        {
            string dest = Path.Combine(destDir, file);
            Assert.True(RapidOcrEngine.TryExtractEmbeddedV5File(file, dest), $"Missing embedded resource: {file}");
            Assert.True(new FileInfo(dest).Length > 100);
        }
    }
}
