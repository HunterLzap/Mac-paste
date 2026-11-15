using System.IO;
using System.Windows;
using Microsoft.Win32;
using SkiaSharp;
using WinPaste.App.Interop;
using WinPaste.App.Windows;
using WinPaste.Core.Imaging;
using WinPaste.Core.OCR;
using WinPaste.Core.Storage;
using WinPaste.Core.Translation;

namespace WinPaste.App.Services;

public sealed class ScreenshotManager
{
    private readonly ClipboardMonitor _clipboardMonitor;
    private readonly HistoryStore _historyStore;
    private readonly AppSettingsStore _settings;
    private readonly IOcrEngine _ocrEngine;
    private readonly IEnglishSpellChecker _spellChecker;
    private readonly TranslationService _translator;

    private ScreenshotOverlayWindow? _activeOverlay;

    public bool IsCapturing => _activeOverlay != null;

    public event Action<SKBitmap, ScreenshotRect>? PinBitmapRequested;
    public event Action<ScreenshotRect>? StartScrollCaptureRequested;

    public ScreenshotManager(
        ClipboardMonitor clipboardMonitor,
        HistoryStore historyStore,
        AppSettingsStore settings,
        IOcrEngine ocrEngine,
        IEnglishSpellChecker spellChecker,
        TranslationService translator)
    {
        _clipboardMonitor = clipboardMonitor;
        _historyStore = historyStore;
        _settings = settings;
        _ocrEngine = ocrEngine;
        _spellChecker = spellChecker;
        _translator = translator;
    }

    public void StartCapture()
    {
        if (!OperatingSystem.IsWindows())
            return;

        if (_activeOverlay != null)
        {
            _activeOverlay.Activate();
            return;
        }

        // 先在内存抓全虚拟桌面物理像素，再零闪烁展开遮罩
        var vRect = NativeMethods.GetVirtualScreenPhysicalRect();
        var fullScreen = NativeMethods.CapturePhysicalRegion(vRect.Left, vRect.Top, vRect.Width, vRect.Height);
        if (fullScreen == null)
            return;

        var overlay = new ScreenshotOverlayWindow(
            fullScreen,
            vRect.Left,
            vRect.Top,
            _ocrEngine,
            _spellChecker,
            _translator,
            _settings);

        _activeOverlay = overlay;
        overlay.Closed += (_, _) =>
        {
            var res = overlay.Result;
            _activeOverlay = null;
            HandleCompletion(res);
            fullScreen.Dispose();
        };
        overlay.Show();
        overlay.Activate();
    }

    public bool FinishAndPinIfCapturing()
    {
        if (_activeOverlay == null)
            return false;
        _activeOverlay.FinishAndPinFromHotKey();
        return true;
    }

    private void HandleCompletion(ScreenshotOverlayWindow.CompletionResult? result)
    {
        if (result == null || result.Action == ScreenshotOverlayWindow.OverlayCompletionAction.Cancelled)
            return;

        if (result.Action == ScreenshotOverlayWindow.OverlayCompletionAction.StartScrollCapture)
        {
            StartScrollCaptureRequested?.Invoke(result.PhysicalSelectionRect);
            return;
        }

        using var bmp = result.CroppedBitmap;
        if (bmp == null) return;

        if (result.Action == ScreenshotOverlayWindow.OverlayCompletionAction.Saved)
        {
            var dlg = new SaveFileDialog
            {
                Filter = "PNG 图片 (*.png)|*.png",
                FileName = $"WinPaste_{DateTime.Now:yyyyMMdd_HHmmss}.png"
            };
            if (dlg.ShowDialog() == true)
                File.WriteAllBytes(dlg.FileName, ScreenshotRenderer.EncodePng(bmp));
            return;
        }

        if (result.Action == ScreenshotOverlayWindow.OverlayCompletionAction.Pinned)
        {
            byte[] png = ScreenshotRenderer.EncodePng(bmp);
            _clipboardMonitor.WritePngBytes(png);
            PinBitmapRequested?.Invoke(bmp.Copy(), result.PhysicalSelectionRect);
            return;
        }

        if (result.Action == ScreenshotOverlayWindow.OverlayCompletionAction.Copied)
        {
            byte[] png = ScreenshotRenderer.EncodePng(bmp);
            _clipboardMonitor.WritePngBytes(png);
            var saved = ImageStore.Save(png);
            if (saved != null)
            {
                _historyStore.Upsert(
                    Core.Models.ClipboardKind.Image,
                    $"{saved.PixelWidth}×{saved.PixelHeight}",
                    saved.DataPath,
                    saved.ThumbPath,
                    saved.Hash);
            }
        }
    }
}
