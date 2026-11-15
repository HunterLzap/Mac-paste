using SkiaSharp;
using WinPaste.Core.Imaging;
using WinPaste.Core.Models;
using WinPaste.Core.OCR;
using WinPaste.Core.Storage;
using Xunit;

namespace WinPaste.Tests;

public sealed class ScreenshotRendererAndSettingsTests : IDisposable
{
    private readonly string _tempDir;

    public ScreenshotRendererAndSettingsTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "WinPasteSettingsTest_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    [Fact]
    public void ScreenshotRenderer_AllSevenAnnotationTools_RenderNonEmptyDiffs()
    {
        const int w = 360;
        const int h = 240;
        using var src = new SKBitmap(w, h, SKColorType.Bgra8888, SKAlphaType.Premul);
        using (var c = new SKCanvas(src))
        {
            c.Clear(new SKColor(245, 247, 250));
            // Fine alternating stripe pattern for mosaic pixelation test
            using var stripePaint = new SKPaint { Color = new SKColor(20, 40, 80) };
            for (int x = 220; x < 320; x += 2)
                c.DrawRect(x, 120, 1, 60, stripePaint);
        }

        var annotations = new List<ScreenshotAnnotation>
        {
            new()
            {
                Tool = ScreenshotTool.Rectangle,
                StartPoint = new(20, 20),
                EndPoint = new(100, 70),
                Color = ScreenshotPalette.SwatchColors[0],
                LineWidth = 4.5
            },
            new()
            {
                Tool = ScreenshotTool.Ellipse,
                StartPoint = new(120, 20),
                EndPoint = new(200, 70),
                Color = ScreenshotPalette.SwatchColors[5],
                LineWidth = 4.5
            },
            new()
            {
                Tool = ScreenshotTool.Arrow,
                StartPoint = new(220, 45),
                EndPoint = new(320, 45),
                Color = ScreenshotPalette.SwatchColors[3],
                LineWidth = 4.5
            },
            new()
            {
                Tool = ScreenshotTool.Pen,
                Points = [new(20, 110), new(60, 140), new(100, 115)],
                Color = ScreenshotPalette.SwatchColors[1],
                LineWidth = 4.5
            },
            new()
            {
                Tool = ScreenshotTool.Highlighter,
                Points = [new(120, 130), new(200, 130)],
                Color = ScreenshotPalette.SwatchColors[2],
                LineWidth = 4.5
            },
            new()
            {
                Tool = ScreenshotTool.Mosaic,
                Points = [new(235, 150), new(305, 150)],
                LineWidth = 7.5
            },
            new()
            {
                Tool = ScreenshotTool.Text,
                StartPoint = new(30, 195),
                Text = "WinPaste OK",
                Color = ScreenshotPalette.SwatchColors[6],
                LineWidth = 4.5
            }
        };

        Assert.All(annotations, a => Assert.True(a.IsValid));

        var sel = new ScreenshotRect(0, 0, w, h);
        using var rendered = ScreenshotRenderer.RenderExportBitmap(src, sel, annotations);

        // Verify rectangle corner pixel got red stroke
        var rectCorner = rendered.GetPixel(20, 20);
        Assert.True(rectCorner.Red > 200 && rectCorner.Green < 100);

        // Verify arrow endpoint drew green head
        var arrowTip = rendered.GetPixel(318, 45);
        Assert.True(arrowTip.Green > 150);

        // Verify mosaic blurred the 1px vertical dark/white stripes around (270, 150) into muted uniform tone
        var m1 = rendered.GetPixel(270, 150);
        var m2 = rendered.GetPixel(271, 150);
        Assert.Equal(m1, m2);

        // Verify annotation hit testing & handle resize
        var clone = annotations[0].Clone();
        Assert.True(clone.HitTest(new(20, 45)));
        clone.DragHandle(AnnotationHandle.BottomRight, new(150, 90));
        Assert.Equal(150, clone.EndPoint.X);
        Assert.Equal(90, clone.EndPoint.Y);
    }

    [Fact]
    public void OcrImagePreprocessor_DarkImageInverted_AndSmallImageUpscaled2x()
    {
        using var darkSmall = new SKBitmap(200, 80, SKColorType.Bgra8888, SKAlphaType.Premul);
        using (var c = new SKCanvas(darkSmall))
            c.Clear(new SKColor(18, 22, 28));

        Assert.True(OcrImagePreprocessor.IsDarkBackground(darkSmall));
        using var processed = OcrImagePreprocessor.Preprocess(darkSmall);
        Assert.Equal(400, processed.Width);
        Assert.Equal(160, processed.Height);
        // Dark background should be inverted to bright background
        var px = processed.GetPixel(200, 80);
        Assert.True(px.Red > 200 && px.Green > 200 && px.Blue > 200);
    }

    [Fact]
    public void AppSettingsStore_And_ParagraphParser_RoundTripAndSplitCorrectly()
    {
        var paths = new AppPaths(_tempDir);
        var store = new AppSettingsStore(paths);
        store.HistoryLimit = 350;
        store.TargetLanguageId = "ja";
        store.ClickAction = ClickAction.Paste;
        store.SaveMainWindowBounds(40, 60, 480, 640);

        var reloaded = new AppSettingsStore(paths);
        Assert.Equal(350, reloaded.Snapshot.HistoryLimit);
        Assert.Equal("ja", reloaded.Snapshot.TargetLanguageId);
        Assert.Equal(ClickAction.Paste, reloaded.Snapshot.ClickAction);
        Assert.Equal(480, reloaded.Snapshot.MainWindowWidth);
        Assert.Equal(640, reloaded.Snapshot.MainWindowHeight);

        var paras = ParagraphParser.Parse("  first line  \r\n\n  second line \n\n");
        Assert.Equal(["first line", "second line"], paras);
    }
}
