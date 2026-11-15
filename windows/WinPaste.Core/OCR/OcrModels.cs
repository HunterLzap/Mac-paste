using SkiaSharp;

namespace WinPaste.Core.OCR;

/// <summary>
/// 归一化矩形（左上角为原点，0..1）或 Vision 内部矩形（左下角为原点，0..1）
/// </summary>
public readonly record struct NormRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MaxX => X + Width;
    public double MidX => X + Width * 0.5;
    public double MinY => Y;
    public double MaxY => Y + Height;
    public double MidY => Y + Height * 0.5;
    public bool IsEmpty => Width <= 0 || Height <= 0;

    public NormRect Union(NormRect other)
    {
        if (IsEmpty) return other;
        if (other.IsEmpty) return this;
        double x1 = Math.Min(MinX, other.MinX);
        double y1 = Math.Min(MinY, other.MinY);
        double x2 = Math.Max(MaxX, other.MaxX);
        double y2 = Math.Max(MaxY, other.MaxY);
        return new NormRect(x1, y1, x2 - x1, y2 - y1);
    }

    public NormRect Intersect(NormRect other)
    {
        double x1 = Math.Max(MinX, other.MinX);
        double y1 = Math.Max(MinY, other.MinY);
        double x2 = Math.Min(MaxX, other.MaxX);
        double y2 = Math.Min(MaxY, other.MaxY);
        return x2 > x1 && y2 > y1
            ? new NormRect(x1, y1, x2 - x1, y2 - y1)
            : new NormRect(0, 0, 0, 0);
    }
}

/// <summary>
/// OCR 引擎输出的原始文本碎片（归一化左上角坐标系 0..1）
/// </summary>
public sealed record OcrRawFragment(string Text, NormRect TopLeftBox);

/// <summary>
/// OCR 分块结果模型（与 Mac 版 OCRTextBlock 100% 对齐）
/// </summary>
public sealed record OcrTextBlock(
    string Text,
    NormRect NormalizedRect,
    double NormalizedLineHeight,
    int LineCount,
    bool IsCentered);

public sealed record OcrLineSegment(
    string Text,
    NormRect Box,
    double TotalHeight,
    int Count)
{
    public string Text { get; set; } = Text;
    public NormRect Box { get; set; } = Box;
    public double TotalHeight { get; set; } = TotalHeight;
    public int Count { get; set; } = Count;
    public double AvgHeight => Math.Max(TotalHeight / Math.Max(Count, 1), Box.Height * 0.90);
}

public interface IOcrEngine
{
    Task<IReadOnlyList<OcrRawFragment>> RecognizeFragmentsAsync(SKBitmap bitmap, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<OcrTextBlock>> RecognizeTextBlocksAsync(SKBitmap bitmap, IEnglishSpellChecker? spellChecker = null, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<string>> RecognizeLinesAsync(SKBitmap bitmap, CancellationToken cancellationToken = default);
}

public interface IEnglishSpellChecker
{
    bool IsValidEnglishWord(string word);
}
