using SkiaSharp;
using WinPaste.Core.Models;

namespace WinPaste.Core.Storage;

/// <summary>
/// 图片落盘：原图 PNG 化（DIB/BMP/TIFF→PNG 防体积爆炸）+ 256px 缩略图，按像素指纹 SHA256 命名
/// </summary>
public static class ImageStore
{
    public const int MaxBytes = 50_000_000;

    private static readonly byte[] PngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    public sealed record SavedImage(
        string DataPath,
        string ThumbPath,
        string Hash,
        int PixelWidth,
        int PixelHeight,
        int PngByteCount);

    /// <summary>
    /// 像素指纹：解码 → 缩到 32×32 sRGB RGBA 位图（铺白底）→ SHA256。
    /// 同一张图即使剪贴板编码不同（PNG/BMP/DIB/回填重编码）也得到同一指纹，用于可靠去重。
    /// </summary>
    public static string? PixelFingerprint(byte[] data)
    {
        if (data.Length == 0)
            return null;

        using var bitmap = DecodeBitmap(data);
        if (bitmap is null || bitmap.Width <= 0 || bitmap.Height <= 0)
            return null;

        return PixelFingerprint(bitmap);
    }

    public static string? PixelFingerprint(SKBitmap bitmap)
    {
        if (bitmap.Width <= 0 || bitmap.Height <= 0)
            return null;

        const int side = 32;
        var info = new SKImageInfo(side, side, SKColorType.Rgba8888, SKAlphaType.Premul, SKColorSpace.CreateSrgb());
        using var surface = SKSurface.Create(info);
        if (surface is null)
            return null;

        var canvas = surface.Canvas;
        // 先铺白底：透明图合成结果确定，且 premultiplied 通道无未初始化字节
        canvas.Clear(SKColors.White);

        using var img = SKImage.FromBitmap(bitmap);
        using var paint = new SKPaint { IsAntialias = true };
        canvas.DrawImage(img, new SKRect(0, 0, side, side), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), paint);
        canvas.Flush();

        var buffer = new byte[side * side * 4];
        var handle = System.Runtime.InteropServices.GCHandle.Alloc(buffer, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            if (!surface.ReadPixels(info, handle.AddrOfPinnedObject(), side * 4, 0, 0))
                return null;
        }
        finally
        {
            handle.Free();
        }

        return HashHelper.Sha256Hex(buffer);
    }

    public static SavedImage? Save(byte[] data, AppPaths? paths = null)
    {
        if (data.Length == 0 || data.Length >= MaxBytes)
            return null;

        var appPaths = paths ?? AppPaths.Default;
        appPaths.EnsureDirectories();

        using var decoded = DecodeBitmap(data);
        if (decoded is null || decoded.Width <= 0 || decoded.Height <= 0)
            return null;

        byte[] pngBytes;
        if (data.AsSpan().StartsWith(PngMagic))
        {
            pngBytes = data;
        }
        else
        {
            using var skImage = SKImage.FromBitmap(decoded);
            using var encoded = skImage.Encode(SKEncodedImageFormat.Png, 100);
            if (encoded is null)
                return null;
            pngBytes = encoded.ToArray();
            if (pngBytes.Length == 0 || pngBytes.Length >= MaxBytes)
                return null;
        }

        var hash = PixelFingerprint(decoded);
        if (hash is null)
            return null;

        var imgPath = Path.Combine(appPaths.ImagesDir, $"{hash}.png");
        var thumbPath = Path.Combine(appPaths.ThumbsDir, $"{hash}.png");

        if (!File.Exists(imgPath))
            File.WriteAllBytes(imgPath, pngBytes);

        if (!File.Exists(thumbPath))
        {
            var thumbBytes = MakeThumbnailPng(decoded, 256);
            if (thumbBytes is not null)
                File.WriteAllBytes(thumbPath, thumbBytes);
        }

        return new SavedImage(
            DataPath: imgPath,
            ThumbPath: thumbPath,
            Hash: hash,
            PixelWidth: decoded.Width,
            PixelHeight: decoded.Height,
            PngByteCount: pngBytes.Length);
    }

    public static byte[]? MakeThumbnailPng(SKBitmap source, int maxPixelSize = 256)
    {
        if (source.Width <= 0 || source.Height <= 0)
            return null;

        var scale = Math.Min(1.0, (double)maxPixelSize / Math.Max(source.Width, source.Height));
        var tw = Math.Max(1, (int)Math.Round(source.Width * scale));
        var th = Math.Max(1, (int)Math.Round(source.Height * scale));

        var info = new SKImageInfo(tw, th, SKColorType.Rgba8888, SKAlphaType.Premul);
        using var scaled = new SKBitmap(info);
        if (!source.ScalePixels(scaled, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear)))
            return null;

        using var img = SKImage.FromBitmap(scaled);
        using var data = img.Encode(SKEncodedImageFormat.Png, 100);
        return data?.ToArray();
    }

    public static SKBitmap? DecodeBitmap(byte[] data)
    {
        try
        {
            using var ms = new MemoryStream(data, writable: false);
            return SKBitmap.Decode(ms);
        }
        catch
        {
            return null;
        }
    }

    public static string FormatFileSize(long bytes)
    {
        if (bytes < 1000) return $"{bytes} B";
        if (bytes < 1_000_000) return $"{bytes / 1000.0:0.#} KB";
        return $"{bytes / 1_000_000.0:0.#} MB";
    }
}
