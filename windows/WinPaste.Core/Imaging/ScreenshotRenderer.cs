using System.Text;
using SkiaSharp;

namespace WinPaste.Core.Imaging;

/// <summary>
/// 物理像素坐标系 SkiaSharp 截图渲染器：
/// - 7 种标注工具（矩形、圆框、箭头、画笔、荧光笔、空间哈希马赛克、带阴影自动判定文字）
/// - 原位翻译两阶段渲染（Pass 1 独立裁剪条渐变擦底，Pass 2 统一绘制译文）
/// </summary>
public static class ScreenshotRenderer
{
    public sealed record RenderedTranslationLayout(
        InPlaceTranslatedBlock Block,
        ScreenshotRect CoverRect,
        IReadOnlyList<string> Lines,
        SKRect DrawRect,
        float FontSize,
        float LineVisualHeight,
        float LineSpacing,
        float Ascent,
        bool IsCentered);

    public static SKBitmap RenderExportBitmap(
        SKBitmap sourceBitmap,
        ScreenshotRect selectionRect,
        IReadOnlyList<ScreenshotAnnotation> annotations,
        IReadOnlyList<InPlaceTranslatedBlock>? translatedBlocks = null)
    {
        int outW = Math.Max(1, (int)Math.Round(selectionRect.Width));
        int outH = Math.Max(1, (int)Math.Round(selectionRect.Height));

        var info = new SKImageInfo(outW, outH, SKColorType.Bgra8888, SKAlphaType.Premul);
        var result = new SKBitmap(info);
        using var canvas = new SKCanvas(result);
        canvas.Clear(SKColors.Transparent);

        canvas.Save();
        canvas.Translate(-(float)selectionRect.Left, -(float)selectionRect.Top);

        canvas.DrawBitmap(sourceBitmap, 0, 0);

        var sampler = new ScreenBitmapSampler(sourceBitmap);
        if (translatedBlocks is { Count: > 0 })
            DrawInPlaceTranslationBlocks(canvas, translatedBlocks, selectionRect);

        if (annotations.Count > 0)
            DrawAnnotations(canvas, annotations, sampler);

        canvas.Restore();
        return result;
    }

    public static byte[] EncodePng(SKBitmap bitmap)
    {
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    public static void DrawAnnotations(
        SKCanvas canvas,
        IReadOnlyList<ScreenshotAnnotation> annotations,
        ScreenBitmapSampler sampler)
    {
        foreach (var ann in annotations)
            DrawAnnotation(canvas, ann, sampler);
    }

    public static void DrawAnnotation(
        SKCanvas canvas,
        ScreenshotAnnotation ann,
        ScreenBitmapSampler sampler)
    {
        switch (ann.Tool)
        {
            case ScreenshotTool.Rectangle:
            {
                var r = ann.Rect;
                if (r.Width < 1 || r.Height < 1) return;
                using var paint = new SKPaint
                {
                    IsAntialias = true,
                    Style = SKPaintStyle.Stroke,
                    StrokeWidth = (float)ann.LineWidth,
                    StrokeJoin = SKStrokeJoin.Round,
                    Color = ann.Color.ToSKColor()
                };
                canvas.DrawRect(r.ToSKRect(), paint);
                break;
            }
            case ScreenshotTool.Ellipse:
            {
                var r = ann.Rect;
                if (r.Width < 1 || r.Height < 1) return;
                using var paint = new SKPaint
                {
                    IsAntialias = true,
                    Style = SKPaintStyle.Stroke,
                    StrokeWidth = (float)ann.LineWidth,
                    Color = ann.Color.ToSKColor()
                };
                canvas.DrawOval(r.ToSKRect(), paint);
                break;
            }
            case ScreenshotTool.Arrow:
            {
                double dx = ann.EndPoint.X - ann.StartPoint.X;
                double dy = ann.EndPoint.Y - ann.StartPoint.Y;
                double len = Math.Sqrt(dx * dx + dy * dy);
                if (len < 2.0) return;

                double ux = dx / len;
                double uy = dy / len;
                double headLen = Math.Max(14.0, ann.LineWidth * 4.0);
                double headAngle = 0.46;
                double baseAngle = Math.Atan2(uy, ux);

                var shaftEnd = new SKPoint(
                    (float)(ann.EndPoint.X - ux * (0.65 * headLen)),
                    (float)(ann.EndPoint.Y - uy * (0.65 * headLen)));
                var neck = new SKPoint(
                    (float)(ann.EndPoint.X - ux * (0.72 * headLen)),
                    (float)(ann.EndPoint.Y - uy * (0.72 * headLen)));
                var wing1 = new SKPoint(
                    (float)(ann.EndPoint.X - headLen * Math.Cos(baseAngle - headAngle)),
                    (float)(ann.EndPoint.Y - headLen * Math.Sin(baseAngle - headAngle)));
                var wing2 = new SKPoint(
                    (float)(ann.EndPoint.X - headLen * Math.Cos(baseAngle + headAngle)),
                    (float)(ann.EndPoint.Y - headLen * Math.Sin(baseAngle + headAngle)));

                using var shaftPaint = new SKPaint
                {
                    IsAntialias = true,
                    Style = SKPaintStyle.Stroke,
                    StrokeWidth = (float)ann.LineWidth,
                    StrokeCap = SKStrokeCap.Round,
                    Color = ann.Color.ToSKColor()
                };
                canvas.DrawLine(ann.StartPoint.ToSKPoint(), shaftEnd, shaftPaint);

                using var headPath = new SKPath();
                headPath.MoveTo(ann.EndPoint.ToSKPoint());
                headPath.LineTo(wing1);
                headPath.LineTo(neck);
                headPath.LineTo(wing2);
                headPath.Close();

                using var headPaint = new SKPaint
                {
                    IsAntialias = true,
                    Style = SKPaintStyle.Fill,
                    Color = ann.Color.ToSKColor()
                };
                canvas.DrawPath(headPath, headPaint);
                break;
            }
            case ScreenshotTool.Pen:
            case ScreenshotTool.Highlighter:
            {
                if (ann.Points.Count < 2) return;
                bool isHighlighter = ann.Tool == ScreenshotTool.Highlighter;
                byte alpha = isHighlighter ? (byte)Math.Round(255 * 0.36) : ann.Color.A;
                float width = isHighlighter ? (float)(ann.LineWidth * 4.0) : (float)ann.LineWidth;

                using var path = new SKPath();
                path.MoveTo(ann.Points[0].ToSKPoint());
                for (int i = 1; i < ann.Points.Count - 1; i++)
                {
                    var cur = ann.Points[i];
                    var next = ann.Points[i + 1];
                    var mid = new SKPoint((float)((cur.X + next.X) * 0.5), (float)((cur.Y + next.Y) * 0.5));
                    path.QuadTo(cur.ToSKPoint(), mid);
                }
                path.LineTo(ann.Points[^1].ToSKPoint());

                using var paint = new SKPaint
                {
                    IsAntialias = true,
                    Style = SKPaintStyle.Stroke,
                    StrokeWidth = width,
                    StrokeCap = SKStrokeCap.Round,
                    StrokeJoin = SKStrokeJoin.Round,
                    Color = ann.Color.ToSKColor(alpha)
                };
                canvas.DrawPath(path, paint);
                break;
            }
            case ScreenshotTool.Mosaic:
            {
                var pts = ann.Points.Count >= 2
                    ? ann.Points
                    : [ann.StartPoint, ann.EndPoint];
                DrawMosaicStroke(canvas, pts, ann.LineWidth, sampler);
                break;
            }
            case ScreenshotTool.Text:
            {
                if (string.IsNullOrWhiteSpace(ann.Text)) return;
                DrawTextAnnotation(canvas, ann);
                break;
            }
        }
    }

    private static void DrawMosaicStroke(
        SKCanvas canvas,
        IReadOnlyList<ScreenshotPoint> points,
        double brushWidth,
        ScreenBitmapSampler sampler)
    {
        double blockSize = brushWidth <= 3.0 ? 8.0 : (brushWidth <= 5.0 ? 12.0 : 16.0);
        double radius = blockSize * 1.4;

        var drawnCells = new HashSet<long>();
        using var paint = new SKPaint
        {
            IsAntialias = false,
            Style = SKPaintStyle.Fill
        };

        void StampAt(ScreenshotPoint pt)
        {
            int minCol = (int)Math.Floor((pt.X - radius) / blockSize);
            int maxCol = (int)Math.Floor((pt.X + radius) / blockSize);
            int minRow = (int)Math.Floor((pt.Y - radius) / blockSize);
            int maxRow = (int)Math.Floor((pt.Y + radius) / blockSize);

            for (int row = minRow; row <= maxRow; row++)
            {
                for (int col = minCol; col <= maxCol; col++)
                {
                    double cx = (col + 0.5) * blockSize;
                    double cy = (row + 0.5) * blockSize;
                    if (Math.Sqrt((cx - pt.X) * (cx - pt.X) + (cy - pt.Y) * (cy - pt.Y)) > radius)
                        continue;

                    long key = unchecked((row * 73856093L) ^ (col * 19349663L));
                    if (!drawnCells.Add(key))
                        continue;

                    paint.Color = sampler.ColorAt(cx, cy).ToSKColor();
                    canvas.DrawRect(
                        (float)(col * blockSize),
                        (float)(row * blockSize),
                        (float)blockSize,
                        (float)blockSize,
                        paint);
                }
            }
        }

        if (points.Count == 1)
        {
            StampAt(points[0]);
            return;
        }

        double step = Math.Max(2.0, blockSize * 0.45);
        for (int i = 1; i < points.Count; i++)
        {
            var a = points[i - 1];
            var b = points[i];
            double dist = a.DistanceTo(b);
            int steps = Math.Max(1, (int)Math.Ceiling(dist / step));
            for (int s = 0; s <= steps; s++)
            {
                double t = (double)s / steps;
                StampAt(new ScreenshotPoint(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t));
            }
        }
    }

    private static void DrawTextAnnotation(SKCanvas canvas, ScreenshotAnnotation ann)
    {
        float fontSize = (float)ann.TextFontSize;
        using var font = CreateUiFont(fontSize, TranslationFontWeight.Medium);
        var metrics = font.Metrics;
        float lineHeight = (metrics.Descent - metrics.Ascent) + Math.Max(2f, fontSize * 0.14f);

        bool needsShadow = ann.Color.Luminance > 0.88;
        using var paint = new SKPaint
        {
            IsAntialias = true,
            Color = ann.Color.ToSKColor()
        };
        if (needsShadow)
        {
            paint.ImageFilter = SKImageFilter.CreateDropShadow(
                0f, 1f, 2.5f, 2.5f, new SKColor(0, 0, 0, 140));
        }

        var lines = ann.Text.Replace("\r\n", "\n").Split('\n');
        float baselineY = (float)ann.StartPoint.Y - metrics.Ascent;
        float startX = (float)ann.StartPoint.X;

        for (int i = 0; i < lines.Length; i++)
        {
            canvas.DrawText(lines[i], startX, baselineY + i * lineHeight, font, paint);
        }
    }

    public static List<RenderedTranslationLayout> ComputeTranslationLayouts(
        IReadOnlyList<InPlaceTranslatedBlock> blocks,
        ScreenshotRect selectionRect)
    {
        var baseRects = new ScreenshotRect[blocks.Count];
        for (int i = 0; i < blocks.Count; i++)
        {
            var b = blocks[i];
            baseRects[i] = new ScreenshotRect(
                selectionRect.Left + b.NormalizedRect.X * selectionRect.Width,
                selectionRect.Top + b.NormalizedRect.Y * selectionRect.Height,
                b.NormalizedRect.Width * selectionRect.Width,
                b.NormalizedRect.Height * selectionRect.Height);
        }

        var layouts = new List<RenderedTranslationLayout>(blocks.Count);

        for (int i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            var baseRect = baseRects[i];
            string text = string.IsNullOrEmpty(block.TranslatedText) ? block.OriginalText : block.TranslatedText;

            double effectiveLineH = block.NormalizedLineHeight > 0
                ? Math.Max(block.NormalizedLineHeight * selectionRect.Height, 8.0)
                : baseRect.Height / Math.Max(block.LineCount, 1);

            float minFontSize = 10.0f;
            float fontSize;
            IReadOnlyList<string> lines;
            SKRect drawRect;

            if (block.LineCount <= 1)
            {
                double leftLimit = selectionRect.Left + 4.0;
                double rightLimit = selectionRect.Right - 4.0;

                for (int j = 0; j < blocks.Count; j++)
                {
                    if (j == i) continue;
                    var other = baseRects[j];
                    double vertOverlap = Math.Min(baseRect.Bottom, other.Bottom) - Math.Max(baseRect.Top, other.Top);
                    if (vertOverlap <= 2.0) continue;

                    if (other.Left >= baseRect.Right - 2.0)
                        rightLimit = Math.Min(rightLimit, other.Left - 6.0);
                    else if (other.Right <= baseRect.Left + 2.0)
                        leftLimit = Math.Max(leftLimit, other.Right + 6.0);
                }

                double maxSingleLineWidth = block.IsCentered
                    ? Math.Max(baseRect.Width, 2.0 * Math.Max(0, Math.Min(baseRect.MidX - leftLimit, rightLimit - baseRect.MidX)))
                    : Math.Max(baseRect.Width, rightLimit - baseRect.Left);

                float initialFontSize = (float)Math.Clamp(effectiveLineH * 0.80, 11.0, 64.0);
                float minSingleFont = Math.Max(10.0f, initialFontSize * 0.62f);
                fontSize = initialFontSize;

                using var measureFont = CreateUiFont(fontSize, block.FontWeight);
                float singleWidth = measureFont.MeasureText(text);
                while (singleWidth > baseRect.Width + 2.0 && fontSize > minSingleFont)
                {
                    fontSize -= 0.5f;
                    measureFont.Size = fontSize;
                    singleWidth = measureFont.MeasureText(text);
                }

                var metrics = measureFont.Metrics;
                float lineVisH = Math.Max(metrics.Descent - metrics.Ascent, fontSize * 1.1f);
                float spacing = Math.Max(fontSize * 0.16f, 2.0f);

                if (singleWidth <= maxSingleLineWidth)
                {
                    lines = [text];
                    float drawW = singleWidth;
                    float drawX = block.IsCentered
                        ? (float)(baseRect.MidX - drawW * 0.5)
                        : (float)baseRect.Left;
                    float drawY = (float)(baseRect.MidY - lineVisH * 0.5);
                    drawRect = new SKRect(drawX, drawY, drawX + drawW, drawY + lineVisH);
                }
                else
                {
                    float wrapWidth = (float)Math.Max(maxSingleLineWidth, 24.0);
                    lines = WrapText(text, measureFont, wrapWidth);
                    float maxMeasuredW = lines.Count == 0 ? 0f : lines.Max(l => measureFont.MeasureText(l));
                    float totalH = lines.Count * lineVisH + Math.Max(0, lines.Count - 1) * spacing;
                    float drawX = block.IsCentered
                        ? (float)(baseRect.MidX - Math.Min(wrapWidth, maxMeasuredW) * 0.5)
                        : (float)baseRect.Left;
                    float drawY = (float)baseRect.Top;
                    float usedW = block.IsCentered ? Math.Min(wrapWidth, maxMeasuredW) : Math.Max((float)baseRect.Width, maxMeasuredW);
                    drawRect = new SKRect(drawX, drawY, drawX + usedW, drawY + totalH);
                }

                var cover = ComputeCoverRect(baseRect, drawRect, selectionRect);
                layouts.Add(new RenderedTranslationLayout(
                    block, cover, lines, drawRect, fontSize, lineVisH, spacing, metrics.Ascent, block.IsCentered));
            }
            else
            {
                fontSize = (float)Math.Clamp(effectiveLineH * 0.82, 11.0, 56.0);
                using var measureFont = CreateUiFont(fontSize, block.FontWeight);
                float wrapWidth = (float)Math.Max(baseRect.Width, 24.0);

                lines = WrapText(text, measureFont, wrapWidth);
                var metrics = measureFont.Metrics;
                float lineVisH = Math.Max(metrics.Descent - metrics.Ascent, fontSize * 1.1f);
                float spacing = Math.Max(fontSize * 0.16f, 2.0f);
                float totalH = lines.Count * lineVisH + Math.Max(0, lines.Count - 1) * spacing;

                while (totalH > baseRect.Height && fontSize > minFontSize)
                {
                    fontSize -= 0.5f;
                    measureFont.Size = fontSize;
                    lines = WrapText(text, measureFont, wrapWidth);
                    metrics = measureFont.Metrics;
                    lineVisH = Math.Max(metrics.Descent - metrics.Ascent, fontSize * 1.1f);
                    spacing = Math.Max(fontSize * 0.16f, 2.0f);
                    totalH = lines.Count * lineVisH + Math.Max(0, lines.Count - 1) * spacing;
                }

                float drawY = (block.IsBold && totalH < baseRect.Height * 0.75)
                    ? (float)(baseRect.MidY - totalH * 0.5)
                    : (float)baseRect.Top;
                drawRect = new SKRect((float)baseRect.Left, drawY, (float)baseRect.Right, drawY + totalH);

                var cover = ComputeCoverRect(baseRect, drawRect, selectionRect);
                layouts.Add(new RenderedTranslationLayout(
                    block, cover, lines, drawRect, fontSize, lineVisH, spacing, metrics.Ascent, block.IsCentered));
            }
        }

        return layouts;
    }

    private static ScreenshotRect ComputeCoverRect(
        ScreenshotRect baseRect,
        SKRect drawRect,
        ScreenshotRect selectionRect)
    {
        var drawAsRect = new ScreenshotRect(drawRect.Left, drawRect.Top, drawRect.Width, drawRect.Height);
        var union = baseRect.Union(drawAsRect).Inflate(4.0, 2.0).Intersect(selectionRect);
        return union.IsEmpty ? baseRect.Intersect(selectionRect) : union;
    }

    public static void DrawInPlaceTranslationBlocks(
        SKCanvas canvas,
        IReadOnlyList<InPlaceTranslatedBlock> blocks,
        ScreenshotRect selectionRect)
    {
        if (blocks.Count == 0) return;

        var layouts = ComputeTranslationLayouts(blocks, selectionRect);

        // Pass 1: Erase background cleanly for all blocks (with independent strip gradient clip)
        using var bgPaint = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Fill };
        foreach (var layout in layouts)
        {
            var cover = layout.CoverRect;
            if (cover.IsEmpty) continue;

            float radius = (float)Math.Min(cover.Height * 0.18, 4.0);
            var skCover = cover.ToSKRect();

            canvas.Save();
            using (var roundClip = new SKPath())
            {
                roundClip.AddRoundRect(skCover, radius, radius);
                canvas.ClipPath(roundClip, antialias: true);
            }

            var strips = layout.Block.StripColors;
            if (strips.Count >= 2)
            {
                float stripW = (float)(cover.Width / strips.Count);
                for (int s = 0; s < strips.Count; s++)
                {
                    var pair = strips[s];
                    float sx = (float)cover.Left + s * stripW;
                    var stripRect = new SKRect(sx - 0.5f, skCover.Top, sx + stripW + 0.5f, skCover.Bottom);

                    canvas.Save();
                    canvas.ClipRect(stripRect);
                    using var shader = SKShader.CreateLinearGradient(
                        new SKPoint(0, skCover.Top),
                        new SKPoint(0, skCover.Bottom),
                        [pair.Top.ToSKColor(), pair.Bottom.ToSKColor()],
                        (float[]?)null,
                        SKShaderTileMode.Clamp);
                    bgPaint.Shader = shader;
                    canvas.DrawRect(stripRect, bgPaint);
                    bgPaint.Shader = null;
                    canvas.Restore();
                }
            }
            else
            {
                bgPaint.Shader = null;
                bgPaint.Color = layout.Block.BackgroundColor.ToSKColor();
                canvas.DrawRect(skCover, bgPaint);
            }

            canvas.Restore();
        }

        // Pass 2: Draw all translated text strings on top
        using var textPaint = new SKPaint { IsAntialias = true };
        foreach (var layout in layouts)
        {
            using var font = CreateUiFont(layout.FontSize, layout.Block.FontWeight);
            textPaint.Color = layout.Block.TextColor.ToSKColor();

            float step = layout.LineVisualHeight + layout.LineSpacing;
            for (int lineIdx = 0; lineIdx < layout.Lines.Count; lineIdx++)
            {
                string line = layout.Lines[lineIdx];
                float baselineY = layout.DrawRect.Top - layout.Ascent + lineIdx * step;
                float x = layout.DrawRect.Left;
                if (layout.IsCentered)
                {
                    float w = font.MeasureText(line);
                    x = layout.DrawRect.MidX - w * 0.5f;
                }
                canvas.DrawText(line, x, baselineY, font, textPaint);
            }
        }
    }

    public static List<string> WrapText(string text, SKFont font, float maxWidth)
    {
        var result = new List<string>();
        if (string.IsNullOrEmpty(text))
            return result;

        var paragraphs = text.Replace("\r\n", "\n").Split('\n');
        foreach (var para in paragraphs)
        {
            if (para.Length == 0)
            {
                result.Add(string.Empty);
                continue;
            }

            var current = new StringBuilder();
            int i = 0;
            while (i < para.Length)
            {
                // Read next token: either CJK single char, whitespace, or ASCII word
                string token;
                char ch = para[i];
                if (char.IsWhiteSpace(ch))
                {
                    token = ch.ToString();
                    i++;
                }
                else if (IsCjkOrFullWidth(ch))
                {
                    token = ch.ToString();
                    i++;
                }
                else
                {
                    int start = i;
                    while (i < para.Length && !char.IsWhiteSpace(para[i]) && !IsCjkOrFullWidth(para[i]))
                        i++;
                    token = para[start..i];
                }

                if (current.Length == 0 && string.IsNullOrWhiteSpace(token))
                    continue;

                string candidate = current.ToString() + token;
                if (font.MeasureText(candidate) <= maxWidth)
                {
                    current.Append(token);
                }
                else
                {
                    if (current.Length > 0)
                    {
                        result.Add(current.ToString().TrimEnd());
                        current.Clear();
                    }

                    if (string.IsNullOrWhiteSpace(token))
                        continue;

                    if (font.MeasureText(token) <= maxWidth)
                    {
                        current.Append(token);
                    }
                    else
                    {
                        // Hard wrap oversized single token char by char
                        foreach (char c in token)
                        {
                            string next = current.ToString() + c;
                            if (current.Length > 0 && font.MeasureText(next) > maxWidth)
                            {
                                result.Add(current.ToString());
                                current.Clear();
                            }
                            current.Append(c);
                        }
                    }
                }
            }

            if (current.Length > 0)
                result.Add(current.ToString().TrimEnd());
        }

        return result;
    }

    private static bool IsCjkOrFullWidth(char ch) =>
        (ch >= '\u4E00' && ch <= '\u9FFF') ||
        (ch >= '\u3400' && ch <= '\u4DBF') ||
        (ch >= '\u3040' && ch <= '\u30FF') ||
        (ch >= '\uAC00' && ch <= '\uD7AF') ||
        (ch >= '\u3000' && ch <= '\u303F') ||
        (ch >= '\uFF00' && ch <= '\uFFEF');

    private static SKFont CreateUiFont(float size, TranslationFontWeight weight)
    {
        var skWeight = weight switch
        {
            TranslationFontWeight.Bold => SKFontStyleWeight.Bold,
            TranslationFontWeight.Medium => SKFontStyleWeight.SemiBold,
            _ => SKFontStyleWeight.Normal
        };
        var style = new SKFontStyle(skWeight, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright);

        // Windows 优先 Microsoft YaHei UI，macOS 回退 PingFang SC / 默认匹配中文字符
        SKTypeface? typeface =
            SKTypeface.FromFamilyName("Microsoft YaHei UI", style) ??
            SKTypeface.FromFamilyName("PingFang SC", style) ??
            SKFontManager.Default.MatchCharacter('中');

        if (typeface != null && typeface.FamilyName == SKTypeface.Default.FamilyName)
        {
            SKTypeface? cjkFallback = SKFontManager.Default.MatchCharacter("Segoe UI", style, null, '中')
                ?? SKFontManager.Default.MatchCharacter(null, style, null, '中');
            if (cjkFallback != null)
                typeface = cjkFallback;
        }

        return new SKFont(typeface ?? SKTypeface.Default, size)
        {
            Edging = SKFontEdging.Antialias,
            Subpixel = true
        };
    }
}
