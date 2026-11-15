using SkiaSharp;

namespace WinPaste.Core.OCR;

/// <summary>
/// OCR 图像增强预处理：根据背景亮度自适应反色、小尺寸图 2x 超分放大与轻微锐化
/// </summary>
public static class OcrImagePreprocessor
{
    public static bool IsDarkBackground(SKBitmap bitmap)
    {
        if (bitmap.Width <= 0 || bitmap.Height <= 0)
            return false;

        var info = new SKImageInfo(1, 1, SKColorType.Rgba8888, SKAlphaType.Premul);
        using var tiny = new SKBitmap(info);
        if (!bitmap.ScalePixels(tiny, new SKSamplingOptions(SKFilterMode.Linear)))
            return false;

        var c = tiny.GetPixel(0, 0);
        double lum = 0.299 * (c.Red / 255.0) + 0.587 * (c.Green / 255.0) + 0.114 * (c.Blue / 255.0);
        return lum < 0.40;
    }

    public static SKBitmap Preprocess(SKBitmap source)
    {
        int scale = (source.Width < 1200 || source.Height < 600) ? 2 : 1;
        int outW = Math.Max(1, source.Width * scale);
        int outH = Math.Max(1, source.Height * scale);
        bool isDark = IsDarkBackground(source);

        var info = new SKImageInfo(outW, outH, SKColorType.Rgba8888, SKAlphaType.Premul);
        var result = new SKBitmap(info);
        using var canvas = new SKCanvas(result);
        canvas.Clear(SKColors.White);

        using var paint = new SKPaint { IsAntialias = true };

        if (isDark)
        {
            // Invert + Contrast 1.25 + Brightness +0.05
            const float contrast = 1.25f;
            const float brightness = 0.05f;
            float invScale = -contrast;
            float offset = contrast * 1.0f + (0.5f * (1f - contrast)) + brightness;
            var matrix = new float[]
            {
                invScale, 0, 0, 0, offset,
                0, invScale, 0, 0, offset,
                0, 0, invScale, 0, offset,
                0, 0, 0, 1, 0
            };
            paint.ColorFilter = SKColorFilter.CreateColorMatrix(matrix);
        }

        // Mild sharpen convolution kernel (equivalent to CISharpenLuminance 0.35)
        var kernel = new float[]
        {
            0f, -0.35f, 0f,
            -0.35f, 2.40f, -0.35f,
            0f, -0.35f, 0f
        };
        paint.ImageFilter = SKImageFilter.CreateMatrixConvolution(
            new SKSizeI(3, 3),
            kernel,
            gain: 1f,
            bias: 0f,
            kernelOffset: new SKPointI(1, 1),
            tileMode: SKShaderTileMode.Clamp,
            convolveAlpha: false);

        using var img = SKImage.FromBitmap(source);
        var sampling = scale > 1
            ? new SKSamplingOptions(SKCubicResampler.Mitchell)
            : new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear);
        canvas.DrawImage(img, new SKRect(0, 0, outW, outH), sampling, paint);
        canvas.Flush();

        return result;
    }
}
