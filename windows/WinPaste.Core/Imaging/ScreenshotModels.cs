using SkiaSharp;

namespace WinPaste.Core.Imaging;

public enum ScreenshotTool
{
    Rectangle,
    Ellipse,
    Arrow,
    Pen,
    Highlighter,
    Mosaic,
    Text
}

public enum ResizeHandle
{
    TopLeft,
    Top,
    TopRight,
    Left,
    Right,
    BottomLeft,
    Bottom,
    BottomRight
}

public enum AnnotationHandle
{
    Start,
    End,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    Move
}

public enum TranslationFontWeight
{
    Regular,
    Medium,
    Bold
}

public readonly record struct ScreenshotPoint(double X, double Y)
{
    public SKPoint ToSKPoint() => new((float)X, (float)Y);

    public double DistanceTo(ScreenshotPoint other)
    {
        double dx = X - other.X;
        double dy = Y - other.Y;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    public ScreenshotPoint Offset(double dx, double dy) => new(X + dx, Y + dy);
}

public readonly record struct ScreenshotRect(double X, double Y, double Width, double Height)
{
    public double Left => X;
    public double Top => Y;
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double MidX => X + Width * 0.5;
    public double MidY => Y + Height * 0.5;
    public bool IsEmpty => Width <= 0 || Height <= 0;

    public static ScreenshotRect FromPoints(ScreenshotPoint a, ScreenshotPoint b)
    {
        double x = Math.Min(a.X, b.X);
        double y = Math.Min(a.Y, b.Y);
        double w = Math.Abs(b.X - a.X);
        double h = Math.Abs(b.Y - a.Y);
        return new ScreenshotRect(x, y, w, h);
    }

    public bool Contains(ScreenshotPoint pt) =>
        pt.X >= Left && pt.X <= Right && pt.Y >= Top && pt.Y <= Bottom;

    public bool Contains(double px, double py) =>
        px >= Left && px <= Right && py >= Top && py <= Bottom;

    public ScreenshotRect Inflate(double dx, double dy) =>
        new(X - dx, Y - dy, Width + dx * 2, Height + dy * 2);

    public ScreenshotRect Inset(double dx, double dy)
    {
        double nw = Math.Max(0, Width - dx * 2);
        double nh = Math.Max(0, Height - dy * 2);
        return new(X + dx, Y + dy, nw, nh);
    }

    public ScreenshotRect Union(ScreenshotRect other)
    {
        if (IsEmpty) return other;
        if (other.IsEmpty) return this;
        double x1 = Math.Min(Left, other.Left);
        double y1 = Math.Min(Top, other.Top);
        double x2 = Math.Max(Right, other.Right);
        double y2 = Math.Max(Bottom, other.Bottom);
        return new(x1, y1, x2 - x1, y2 - y1);
    }

    public ScreenshotRect Intersect(ScreenshotRect other)
    {
        double x1 = Math.Max(Left, other.Left);
        double y1 = Math.Max(Top, other.Top);
        double x2 = Math.Min(Right, other.Right);
        double y2 = Math.Min(Bottom, other.Bottom);
        return x2 > x1 && y2 > y1 ? new(x1, y1, x2 - x1, y2 - y1) : default;
    }

    public SKRect ToSKRect() => new((float)Left, (float)Top, (float)Right, (float)Bottom);
}

public readonly record struct ScreenshotColor(byte R, byte G, byte B, byte A = 255)
{
    public double RedNorm => R / 255.0;
    public double GreenNorm => G / 255.0;
    public double BlueNorm => B / 255.0;
    public double AlphaNorm => A / 255.0;

    public double Luminance => 0.299 * RedNorm + 0.587 * GreenNorm + 0.114 * BlueNorm;

    public string HexString => $"#{R:X2}{G:X2}{B:X2}";

    public double RgbDistance(ScreenshotColor other)
    {
        double dr = RedNorm - other.RedNorm;
        double dg = GreenNorm - other.GreenNorm;
        double db = BlueNorm - other.BlueNorm;
        return Math.Sqrt(dr * dr + dg * dg + db * db);
    }

    public SKColor ToSKColor(byte? overrideAlpha = null) =>
        new(R, G, B, overrideAlpha ?? A);
}

public static class ScreenshotPalette
{
    public static readonly IReadOnlyList<ScreenshotColor> SwatchColors =
    [
        new ScreenshotColor(255, 59, 48),   // Red
        new ScreenshotColor(255, 149, 0),   // Orange
        new ScreenshotColor(255, 209, 0),   // Yellow
        new ScreenshotColor(51, 199, 89),   // Green
        new ScreenshotColor(0, 199, 255),   // Cyan
        new ScreenshotColor(10, 133, 255),  // Blue
        new ScreenshotColor(176, 82, 222),  // Purple
        new ScreenshotColor(255, 255, 255)  // White
    ];

    public static readonly IReadOnlyList<(string Label, double Width)> StrokeWidths =
    [
        ("细", 2.5),
        ("中", 4.5),
        ("粗", 7.5)
    ];

    public static string ToolDisplayName(ScreenshotTool tool) => tool switch
    {
        ScreenshotTool.Rectangle => "矩形",
        ScreenshotTool.Ellipse => "圆框",
        ScreenshotTool.Arrow => "箭头",
        ScreenshotTool.Pen => "画笔",
        ScreenshotTool.Highlighter => "荧光笔",
        ScreenshotTool.Mosaic => "马赛克",
        ScreenshotTool.Text => "文字",
        _ => tool.ToString()
    };
}

public sealed class ScreenshotAnnotation
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public ScreenshotTool Tool { get; set; }
    public ScreenshotPoint StartPoint { get; set; }
    public ScreenshotPoint EndPoint { get; set; }
    public List<ScreenshotPoint> Points { get; set; } = [];
    public ScreenshotColor Color { get; set; } = ScreenshotPalette.SwatchColors[0];
    public double LineWidth { get; set; } = 4.5;
    public string Text { get; set; } = string.Empty;
    public double? CustomFontSize { get; set; }

    public ScreenshotRect Rect => ScreenshotRect.FromPoints(StartPoint, EndPoint);

    public double TextFontSize
    {
        get
        {
            if (CustomFontSize is > 0 and var custom)
                return custom;
            if (LineWidth <= 3.0) return 15.0;
            if (LineWidth <= 5.0) return 19.0;
            return 25.0;
        }
    }

    public bool IsValid => Tool switch
    {
        ScreenshotTool.Rectangle or ScreenshotTool.Ellipse or ScreenshotTool.Arrow =>
            StartPoint.DistanceTo(EndPoint) >= 3.0,
        ScreenshotTool.Pen or ScreenshotTool.Highlighter =>
            Points.Count >= 2 && HasAnySegmentLongerThan(2.0),
        ScreenshotTool.Mosaic =>
            Points.Count >= 2 || StartPoint.DistanceTo(EndPoint) >= 2.0,
        ScreenshotTool.Text =>
            !string.IsNullOrWhiteSpace(Text),
        _ => false
    };

    private bool HasAnySegmentLongerThan(double minLen)
    {
        ScreenshotPoint first = Points[0];
        for (int i = 1; i < Points.Count; i++)
        {
            if (first.DistanceTo(Points[i]) >= minLen)
                return true;
        }
        return false;
    }

    public ScreenshotAnnotation Clone() => new()
    {
        Id = Id,
        Tool = Tool,
        StartPoint = StartPoint,
        EndPoint = EndPoint,
        Points = [.. Points],
        Color = Color,
        LineWidth = LineWidth,
        Text = Text,
        CustomFontSize = CustomFontSize
    };

    public ScreenshotRect GetBoundingRect()
    {
        if (Tool is ScreenshotTool.Pen or ScreenshotTool.Highlighter or ScreenshotTool.Mosaic)
        {
            if (Points.Count == 0)
                return Rect;
            double minX = Points[0].X, maxX = Points[0].X;
            double minY = Points[0].Y, maxY = Points[0].Y;
            for (int i = 1; i < Points.Count; i++)
            {
                var p = Points[i];
                if (p.X < minX) minX = p.X;
                if (p.X > maxX) maxX = p.X;
                if (p.Y < minY) minY = p.Y;
                if (p.Y > maxY) maxY = p.Y;
            }
            double pad = Tool == ScreenshotTool.Highlighter ? LineWidth * 2.0 : LineWidth;
            return new ScreenshotRect(minX - pad, minY - pad, (maxX - minX) + pad * 2, (maxY - minY) + pad * 2);
        }

        if (Tool == ScreenshotTool.Text)
        {
            var lines = (Text ?? string.Empty).Replace("\r\n", "\n").Split('\n');
            double fontSize = TextFontSize;
            int maxChars = 1;
            foreach (var l in lines)
                maxChars = Math.Max(maxChars, l.Length);
            double estW = Math.Max(fontSize * 1.4, maxChars * fontSize * 0.68 + 12);
            double estH = Math.Max(fontSize * 1.35, lines.Length * fontSize * 1.25 + 6);
            return new ScreenshotRect(StartPoint.X, StartPoint.Y, estW, estH);
        }

        return Rect;
    }

    public bool HitTest(ScreenshotPoint point, double tolerance = 10.0)
    {
        switch (Tool)
        {
            case ScreenshotTool.Rectangle:
            {
                var r = Rect;
                var outer = r.Inflate(tolerance, tolerance);
                var inner = r.Inset(tolerance, tolerance);
                return outer.Contains(point) && (inner.IsEmpty || !inner.Contains(point));
            }
            case ScreenshotTool.Ellipse:
            {
                var r = Rect;
                if (r.Width < 2 || r.Height < 2)
                    return r.Inflate(tolerance, tolerance).Contains(point);
                double rx = r.Width * 0.5;
                double ry = r.Height * 0.5;
                double dx = point.X - r.MidX;
                double dy = point.Y - r.MidY;
                double norm = Math.Sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry));
                double ringTol = tolerance / Math.Max(8.0, Math.Min(rx, ry));
                return Math.Abs(norm - 1.0) <= ringTol;
            }
            case ScreenshotTool.Arrow:
                return DistancePointToSegment(point, StartPoint, EndPoint) <= tolerance;
            case ScreenshotTool.Pen:
            case ScreenshotTool.Highlighter:
            case ScreenshotTool.Mosaic:
            {
                double hitTol = Tool == ScreenshotTool.Highlighter
                    ? Math.Max(tolerance, LineWidth * 2.2)
                    : Math.Max(tolerance, LineWidth * 1.5);
                if (Points.Count == 1)
                    return point.DistanceTo(Points[0]) <= hitTol;
                for (int i = 1; i < Points.Count; i++)
                {
                    if (DistancePointToSegment(point, Points[i - 1], Points[i]) <= hitTol)
                        return true;
                }
                return false;
            }
            case ScreenshotTool.Text:
                return GetBoundingRect().Inflate(6, 4).Contains(point);
            default:
                return false;
        }
    }

    public AnnotationHandle? HitTestHandle(ScreenshotPoint point, double handleRadius = 9.0)
    {
        if (Tool == ScreenshotTool.Arrow)
        {
            if (point.DistanceTo(StartPoint) <= handleRadius) return AnnotationHandle.Start;
            if (point.DistanceTo(EndPoint) <= handleRadius) return AnnotationHandle.End;
            return null;
        }

        if (Tool is ScreenshotTool.Rectangle or ScreenshotTool.Ellipse)
        {
            var r = Rect;
            if (point.DistanceTo(new(r.Left, r.Top)) <= handleRadius) return AnnotationHandle.TopLeft;
            if (point.DistanceTo(new(r.Right, r.Top)) <= handleRadius) return AnnotationHandle.TopRight;
            if (point.DistanceTo(new(r.Left, r.Bottom)) <= handleRadius) return AnnotationHandle.BottomLeft;
            if (point.DistanceTo(new(r.Right, r.Bottom)) <= handleRadius) return AnnotationHandle.BottomRight;
        }

        return null;
    }

    public void MoveBy(double dx, double dy)
    {
        StartPoint = StartPoint.Offset(dx, dy);
        EndPoint = EndPoint.Offset(dx, dy);
        for (int i = 0; i < Points.Count; i++)
            Points[i] = Points[i].Offset(dx, dy);
    }

    public void DragHandle(AnnotationHandle handle, ScreenshotPoint target)
    {
        switch (handle)
        {
            case AnnotationHandle.Start:
                StartPoint = target;
                break;
            case AnnotationHandle.End:
                EndPoint = target;
                break;
            case AnnotationHandle.TopLeft:
            {
                var r = Rect;
                StartPoint = target;
                EndPoint = new(r.Right, r.Bottom);
                break;
            }
            case AnnotationHandle.TopRight:
            {
                var r = Rect;
                StartPoint = new(r.Left, target.Y);
                EndPoint = new(target.X, r.Bottom);
                break;
            }
            case AnnotationHandle.BottomLeft:
            {
                var r = Rect;
                StartPoint = new(target.X, r.Top);
                EndPoint = new(r.Right, target.Y);
                break;
            }
            case AnnotationHandle.BottomRight:
            {
                var r = Rect;
                StartPoint = new(r.Left, r.Top);
                EndPoint = target;
                break;
            }
        }
    }

    private static double DistancePointToSegment(ScreenshotPoint p, ScreenshotPoint a, ScreenshotPoint b)
    {
        double dx = b.X - a.X;
        double dy = b.Y - a.Y;
        double lenSq = dx * dx + dy * dy;
        if (lenSq <= 1e-6) return p.DistanceTo(a);
        double t = ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / lenSq;
        t = Math.Clamp(t, 0.0, 1.0);
        double projX = a.X + t * dx;
        double projY = a.Y + t * dy;
        return Math.Sqrt((p.X - projX) * (p.X - projX) + (p.Y - projY) * (p.Y - projY));
    }
}

public sealed record StripGradientPair(ScreenshotColor Top, ScreenshotColor Bottom);

public sealed record InPlaceTranslatedBlock(
    int Id,
    string OriginalText,
    string TranslatedText,
    OCR.NormRect NormalizedRect,
    double NormalizedLineHeight,
    int LineCount,
    bool IsCentered,
    bool IsBold,
    TranslationFontWeight FontWeight,
    ScreenshotColor BackgroundColor,
    IReadOnlyList<StripGradientPair> StripColors,
    ScreenshotColor TextColor);
