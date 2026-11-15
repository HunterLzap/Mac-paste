using WinPaste.Core.OCR;

namespace WinPaste.Core.Imaging;

/// <summary>
/// 1:1 复刻 Mac 版截图原位翻译视觉样式检测（ScreenshotOverlayView.swift detectBlockStyle）：
/// 外侧 14 点中值采样背景色、水平分片 3 点中值渐变条采样、块内前景文字色提取、字重与深色按钮居中识别。
/// </summary>
public static class InPlaceStyleDetector
{
    public static InPlaceTranslatedBlock Detect(
        int id,
        OcrTextBlock ocrBlock,
        string translatedText,
        ScreenBitmapSampler sampler,
        ScreenshotRect selectionRect)
    {
        var blockRect = new ScreenshotRect(
            selectionRect.Left + ocrBlock.NormalizedRect.X * selectionRect.Width,
            selectionRect.Top + ocrBlock.NormalizedRect.Y * selectionRect.Height,
            ocrBlock.NormalizedRect.Width * selectionRect.Width,
            ocrBlock.NormalizedRect.Height * selectionRect.Height);

        ScreenshotRect clampBounds = selectionRect.Width > 4 && selectionRect.Height > 4
            ? selectionRect.Inset(1, 1)
            : selectionRect;

        ScreenshotPoint ClampToSelection(ScreenshotPoint pt) => new(
            Math.Clamp(pt.X, clampBounds.Left, clampBounds.Right),
            Math.Clamp(pt.Y, clampBounds.Top, clampBounds.Bottom));

        const double margin = 3.0;
        ScreenshotPoint[] candidatePoints =
        [
            // Top 4 points
            new(blockRect.Left + blockRect.Width * 0.15, blockRect.Top - margin),
            new(blockRect.Left + blockRect.Width * 0.38, blockRect.Top - margin),
            new(blockRect.Left + blockRect.Width * 0.62, blockRect.Top - margin),
            new(blockRect.Left + blockRect.Width * 0.85, blockRect.Top - margin),
            // Bottom 4 points
            new(blockRect.Left + blockRect.Width * 0.15, blockRect.Bottom + margin),
            new(blockRect.Left + blockRect.Width * 0.38, blockRect.Bottom + margin),
            new(blockRect.Left + blockRect.Width * 0.62, blockRect.Bottom + margin),
            new(blockRect.Left + blockRect.Width * 0.85, blockRect.Bottom + margin),
            // Left 3 points
            new(blockRect.Left - margin, blockRect.Top + blockRect.Height * 0.2),
            new(blockRect.Left - margin, blockRect.Top + blockRect.Height * 0.5),
            new(blockRect.Left - margin, blockRect.Top + blockRect.Height * 0.8),
            // Right 3 points
            new(blockRect.Right + margin, blockRect.Top + blockRect.Height * 0.2),
            new(blockRect.Right + margin, blockRect.Top + blockRect.Height * 0.5),
            new(blockRect.Right + margin, blockRect.Top + blockRect.Height * 0.8),
        ];

        var outerPoints = new List<ScreenshotPoint>(14);
        foreach (var rawPt in candidatePoints)
        {
            var clamped = ClampToSelection(rawPt);
            if (!blockRect.Contains(clamped))
                outerPoints.Add(clamped);
        }

        if (outerPoints.Count == 0)
            outerPoints.Add(ClampToSelection(new ScreenshotPoint(blockRect.Left - margin, blockRect.MidY)));

        var bgSamples = outerPoints.Select(p => sampler.ColorAt(p.X, p.Y)).ToList();
        ScreenshotColor bgColor = MedianColor(bgSamples);
        double bgLum = bgColor.Luminance;

        ScreenshotColor EdgeSampleMedian(double cx, double cy)
        {
            var colors = new List<ScreenshotColor>(3);
            ReadOnlySpan<double> offsets = [-3.0, 0.0, 3.0];
            foreach (double dx in offsets)
            {
                var pt = ClampToSelection(new ScreenshotPoint(cx + dx, cy));
                if (!blockRect.Contains(pt))
                    colors.Add(sampler.ColorAt(pt.X, pt.Y));
            }
            return colors.Count > 0 ? MedianColor(colors) : bgColor;
        }

        double sampleMinX = Math.Max(blockRect.Left - 4.0, selectionRect.Left);
        double sampleMaxX = Math.Min(blockRect.Right + 4.0, selectionRect.Right);
        double sampleW = Math.Max(sampleMaxX - sampleMinX, blockRect.Width);
        int stripCount = Math.Clamp((int)Math.Ceiling(sampleW / 10.0), 1, 48);

        var stripColors = new List<StripGradientPair>(stripCount);
        for (int i = 0; i < stripCount; i++)
        {
            double sx = sampleMinX + (i + 0.5) * (sampleW / stripCount);
            var topColor = EdgeSampleMedian(sx, blockRect.Top - 5.0);
            var bottomColor = EdgeSampleMedian(sx, blockRect.Bottom + 5.0);
            stripColors.Add(new StripGradientPair(topColor, bottomColor));
        }

        // Foreground color extraction inside blockRect
        const int cols = 20;
        int rows = ocrBlock.LineCount >= 2 ? 12 : 6;
        var fgCandidates = new List<(ScreenshotColor Color, double Dist)>();
        for (int r = 0; r < rows; r++)
        {
            double sy = blockRect.Top + (r + 0.5) * (blockRect.Height / rows);
            for (int c = 0; c < cols; c++)
            {
                double sx = blockRect.Left + (c + 0.5) * (blockRect.Width / cols);
                var sample = sampler.ColorAt(sx, sy);
                double dist = sample.RgbDistance(bgColor);
                if (dist > 0.22)
                    fgCandidates.Add((sample, dist));
            }
        }

        ScreenshotColor textColor;
        if (fgCandidates.Count >= 4)
        {
            fgCandidates.Sort((a, b) => b.Dist.CompareTo(a.Dist));
            int keepCount = Math.Max(4, (int)Math.Ceiling(fgCandidates.Count * 0.60));
            textColor = MedianColor(fgCandidates.Take(keepCount).Select(x => x.Color).ToList());
        }
        else
        {
            textColor = bgLum > 0.55
                ? new ScreenshotColor(28, 33, 41)
                : new ScreenshotColor(240, 242, 247);
        }

        double trueLineH = ocrBlock.NormalizedLineHeight > 0
            ? Math.Max(ocrBlock.NormalizedLineHeight * selectionRect.Height, 8.0)
            : blockRect.Height / Math.Max(ocrBlock.LineCount, 1);

        bool isBold = trueLineH >= 24.0;
        bool isDarkButton = ocrBlock.LineCount == 1
            && blockRect.Width < selectionRect.Width * 0.42
            && bgLum < 0.35;
        bool isCentered = ocrBlock.IsCentered || isDarkButton;
        TranslationFontWeight fontWeight = isBold
            ? TranslationFontWeight.Bold
            : (isDarkButton ? TranslationFontWeight.Medium : TranslationFontWeight.Regular);

        return new InPlaceTranslatedBlock(
            Id: id,
            OriginalText: ocrBlock.Text,
            TranslatedText: translatedText,
            NormalizedRect: ocrBlock.NormalizedRect,
            NormalizedLineHeight: ocrBlock.NormalizedLineHeight,
            LineCount: ocrBlock.LineCount,
            IsCentered: isCentered,
            IsBold: isBold,
            FontWeight: fontWeight,
            BackgroundColor: bgColor,
            StripColors: stripColors,
            TextColor: textColor);
    }

    public static ScreenshotColor MedianColor(IReadOnlyList<ScreenshotColor> colors)
    {
        if (colors.Count == 0)
            return new ScreenshotColor(255, 255, 255, 255);
        if (colors.Count == 1)
            return colors[0];

        var rs = new byte[colors.Count];
        var gs = new byte[colors.Count];
        var bs = new byte[colors.Count];
        for (int i = 0; i < colors.Count; i++)
        {
            rs[i] = colors[i].R;
            gs[i] = colors[i].G;
            bs[i] = colors[i].B;
        }
        Array.Sort(rs);
        Array.Sort(gs);
        Array.Sort(bs);
        int mid = colors.Count / 2;
        return new ScreenshotColor(rs[mid], gs[mid], bs[mid], 255);
    }
}
