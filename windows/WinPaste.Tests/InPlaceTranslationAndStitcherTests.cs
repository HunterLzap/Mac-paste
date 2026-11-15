using SkiaSharp;
using WinPaste.Core.Imaging;
using WinPaste.Core.OCR;
using WinPaste.Core.Translation;
using Xunit;

namespace WinPaste.Tests;

public class InPlaceTranslationAndStitcherTests
{
    [Fact]
    public void StyleDetector_And_TwoPassRenderer_PreserveGradientAndButtonCentering()
    {
        const int w = 420;
        const int h = 240;
        using var src = new SKBitmap(w, h, SKColorType.Bgra8888, SKAlphaType.Premul);
        using (var canvas = new SKCanvas(src))
        {
            // Gradient top #184888 -> bottom #3090D0 for top half
            using var gradShader = SKShader.CreateLinearGradient(
                new SKPoint(0, 0),
                new SKPoint(0, 140),
                [new SKColor(0x18, 0x48, 0x88), new SKColor(0x30, 0x90, 0xD0)],
                (float[]?)null,
                SKShaderTileMode.Clamp);
            using (var gp = new SKPaint { Shader = gradShader })
                canvas.DrawRect(0, 0, w, 140, gp);

            // Light bottom half #F3F5F8
            canvas.DrawRect(0, 140, w, 100, new SKPaint { Color = new SKColor(0xF3, 0xF5, 0xF8) });

            // White text on gradient top
            using var font = new SKFont(SKTypeface.Default, 26);
            canvas.DrawText("Build Faster", 40, 72, font, new SKPaint { Color = SKColors.White, IsAntialias = true });

            // Dark button centered horizontally (< 42% width)
            canvas.DrawRoundRect(new SKRect(150, 165, 270, 205), 8, 8, new SKPaint { Color = new SKColor(0x1C, 0x22, 0x2D) });
            using var btnFont = new SKFont(SKTypeface.Default, 15);
            canvas.DrawText("Deploy", 184, 190, btnFont, new SKPaint { Color = SKColors.White, IsAntialias = true });
        }

        var sampler = new ScreenBitmapSampler(src);
        var sel = new ScreenshotRect(0, 0, w, h);

        var headingOcr = new OcrTextBlock(
            "Build Faster",
            new NormRect(38.0 / w, 46.0 / h, 160.0 / w, 32.0 / h),
            32.0 / h,
            LineCount: 1,
            IsCentered: false);

        var buttonOcr = new OcrTextBlock(
            "Deploy",
            new NormRect(178.0 / w, 174.0 / h, 64.0 / w, 20.0 / h),
            20.0 / h,
            LineCount: 1,
            IsCentered: false);

        var headingStyled = InPlaceStyleDetector.Detect(0, headingOcr, "更快构建", sampler, sel);
        var buttonStyled = InPlaceStyleDetector.Detect(1, buttonOcr, "立即部署", sampler, sel);

        Assert.True(headingStyled.StripColors.Count >= 2);
        // Gradient top strip should be darker blue than bottom strip
        Assert.True(headingStyled.StripColors[0].Top.B < headingStyled.StripColors[0].Bottom.B);
        Assert.True(headingStyled.IsBold); // 32px >= 24px
        Assert.True(headingStyled.TextColor.Luminance > 0.7);

        // Dark button auto-recognized as centered + dark bg
        Assert.True(buttonStyled.IsCentered);
        Assert.True(buttonStyled.BackgroundColor.Luminance < 0.35);
        Assert.Equal(TranslationFontWeight.Medium, buttonStyled.FontWeight);

        using var exported = ScreenshotRenderer.RenderExportBitmap(
            src,
            sel,
            [],
            [headingStyled, buttonStyled]);

        Assert.Equal(w, exported.Width);
        Assert.Equal(h, exported.Height);
        byte[] png = ScreenshotRenderer.EncodePng(exported);
        Assert.True(png.Length > 200);
        Assert.Equal(0x89, png[0]);
        Assert.Equal((byte)'P', png[1]);
    }

    [Fact]
    public void ScrollImageStitcher_ScrollDownUpAndPixelAccuracy()
    {
        const int w = 240;
        const int totalH = 720;
        const int viewH = 300;

        using var master = new SKBitmap(w, totalH, SKColorType.Bgra8888, SKAlphaType.Premul);
        using (var canvas = new SKCanvas(master))
        {
            canvas.Clear(SKColors.White);
            using var paint = new SKPaint { IsAntialias = true };
            using var font = new SKFont(SKTypeface.Default, 16);
            for (int y = 0; y < totalH; y += 24)
            {
                paint.Color = new SKColor((byte)((y * 37) % 200), (byte)((y * 71) % 200), 190);
                canvas.DrawRect(20, y + 2, w - 40, 18, paint);
                paint.Color = SKColors.Black;
                canvas.DrawText($"ROW-{y:D3}", 30, y + 16, font, paint);
            }
        }

        SKBitmap Slice(int startY)
        {
            var bmp = new SKBitmap(w, viewH, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var c = new SKCanvas(bmp);
            c.DrawBitmap(master, new SKRect(0, startY, w, startY + viewH), new SKRect(0, 0, w, viewH));
            return bmp;
        }

        var stitcher = new ScrollImageStitcher(cropInset: 0);

        using var f1 = Slice(100);
        var r1 = stitcher.Append(f1);
        Assert.True(r1.Appended);
        Assert.Equal(300, r1.TotalHeight);

        using var f1Dup = Slice(100);
        var rDup = stitcher.Append(f1Dup);
        Assert.True(rDup.NoMovement);
        Assert.Equal(300, rDup.TotalHeight);

        using var f2 = Slice(220); // +120px down
        var r2 = stitcher.Append(f2);
        Assert.True(r2.Appended);
        Assert.InRange(r2.AppendedRows, 118, 122);

        using var fBack = Slice(140); // scroll up inside canvas -> rollback, no growth
        int heightBeforeRollback = stitcher.TotalPixelHeight;
        var rBack = stitcher.Append(fBack);
        Assert.True(rBack.Appended);
        Assert.Equal(heightBeforeRollback, stitcher.TotalPixelHeight);

        using var fTopPrepend = Slice(0); // scroll above initial y=100 -> prepends 100 rows above stitched canvas
        var rPre = stitcher.Append(fTopPrepend);
        Assert.True(rPre.Appended);
        Assert.InRange(rPre.PrependedRows, 98, 102);

        using var stitched = stitcher.AssembleStitchedImage();
        Assert.NotNull(stitched);
        Assert.Equal(w, stitched!.Width);
        Assert.InRange(stitched.Height, 515, 525);
    }

    private sealed class StubHttpHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, int, HttpResponseMessage> _responder;
        public int CallCount { get; private set; }

        public StubHttpHandler(Func<HttpRequestMessage, int, HttpResponseMessage> responder) =>
            _responder = responder;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++;
            return Task.FromResult(_responder(request, CallCount));
        }
    }

    [Fact]
    public async Task TranslationService_BatchSuccess_And_FallbackOnMismatch()
    {
        // Case 1: Single batch request translates multiple items in 1 HTTP call
        var okHandler = new StubHttpHandler((_, _) =>
        {
            string json = "[[[\"你好\\n世界\", \"Hello\\nWorld\", null, null, 1]]]";
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(json) };
        });

        var okService = new TranslationService(okHandler);
        var res1 = await okService.TranslateBatchAsync(["Hello", "World"], targetCode: "zh-CN");
        Assert.Equal(1, okHandler.CallCount);
        Assert.Equal(["你好", "世界"], res1);

        // Case 2: Mismatched line count in batch -> triggers individual concurrent fallback
        var fbHandler = new StubHttpHandler((_, callIndex) =>
        {
            string body = callIndex == 1
                ? "[[[\"合并坏掉了\", \"A\\nB\", null, null, 1]]]"
                : callIndex == 2
                    ? "[[[\"甲\", \"A\", null, null, 1]]]"
                    : "[[[\"乙\", \"B\", null, null, 1]]]";
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(body) };
        });

        var fbService = new TranslationService(fbHandler);
        var res2 = await fbService.TranslateBatchAsync(["A", "B"], targetCode: "zh-CN");
        Assert.Equal(3, fbHandler.CallCount);
        Assert.Equal(2, res2.Length);
        Assert.Contains("甲", res2);
        Assert.Contains("乙", res2);
    }
}
