using System.Runtime.InteropServices;
using SkiaSharp;

namespace WinPaste.Core.Imaging;

/// <summary>
/// 读取原图物理像素色彩（保留原始色彩空间，支持 O(1) 像素访问、放大镜取块与 HEX 取色）
/// </summary>
public sealed class ScreenBitmapSampler
{
    private readonly SKBitmap _bitmap;
    private readonly int _width;
    private readonly int _height;
    private readonly int _rowBytes;
    private readonly SKColorType _colorType;
    private readonly byte[]? _pixelCopy;

    public int Width => _width;
    public int Height => _height;

    public ScreenBitmapSampler(SKBitmap bitmap)
    {
        _bitmap = bitmap;
        _width = bitmap.Width;
        _height = bitmap.Height;
        _rowBytes = bitmap.RowBytes;
        _colorType = bitmap.ColorType;

        if ((_colorType == SKColorType.Bgra8888 || _colorType == SKColorType.Rgba8888) && _width > 0 && _height > 0)
        {
            nint ptr = bitmap.GetPixels();
            if (ptr != nint.Zero)
            {
                _pixelCopy = new byte[_rowBytes * _height];
                Marshal.Copy(ptr, _pixelCopy, 0, _pixelCopy.Length);
            }
        }
    }

    public ScreenshotColor ColorAt(double x, double y)
    {
        if (_width <= 0 || _height <= 0)
            return new ScreenshotColor(0, 0, 0, 255);

        int px = Math.Clamp((int)Math.Floor(x), 0, _width - 1);
        int py = Math.Clamp((int)Math.Floor(y), 0, _height - 1);
        return ColorAtInt(px, py);
    }

    public ScreenshotColor ColorAtInt(int px, int py)
    {
        if (_width <= 0 || _height <= 0)
            return new ScreenshotColor(0, 0, 0, 255);

        px = Math.Clamp(px, 0, _width - 1);
        py = Math.Clamp(py, 0, _height - 1);

        if (_pixelCopy != null)
        {
            int offset = py * _rowBytes + px * 4;
            if (_colorType == SKColorType.Bgra8888)
            {
                byte b = _pixelCopy[offset];
                byte g = _pixelCopy[offset + 1];
                byte r = _pixelCopy[offset + 2];
                return new ScreenshotColor(r, g, b, 255);
            }
            else // Rgba8888
            {
                byte r = _pixelCopy[offset];
                byte g = _pixelCopy[offset + 1];
                byte b = _pixelCopy[offset + 2];
                return new ScreenshotColor(r, g, b, 255);
            }
        }

        SKColor c = _bitmap.GetPixel(px, py);
        return new ScreenshotColor(c.Red, c.Green, c.Blue, 255);
    }

    /// <summary>
    /// 提取以物理坐标 (centerX, centerY) 为中心的 (2*radius+1) x (2*radius+1) 像素矩阵供放大镜渲染
    /// </summary>
    public ScreenshotColor[,] ExtractMagnifierPatch(int centerX, int centerY, int radius = 6)
    {
        int size = radius * 2 + 1;
        var grid = new ScreenshotColor[size, size];
        for (int dy = -radius; dy <= radius; dy++)
        {
            for (int dx = -radius; dx <= radius; dx++)
            {
                int sx = centerX + dx;
                int sy = centerY + dy;
                grid[dy + radius, dx + radius] = (sx >= 0 && sx < _width && sy >= 0 && sy < _height)
                    ? ColorAtInt(sx, sy)
                    : new ScreenshotColor(18, 22, 28, 255);
            }
        }
        return grid;
    }
}
