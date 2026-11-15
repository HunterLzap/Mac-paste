using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using SkiaSharp;
using WinPaste.App.Interop;
using WinPaste.Core.Imaging;
using WinPaste.Core.Models;
using WinPaste.Core.Storage;

namespace WinPaste.App.Services;

/// <summary>
/// 滚动长截图控制器（L 键 / 长截图按钮触发）：
/// 0.10s 定时采样拼接 + 0.08s 自动滚轮发送 + 连续 16 次无变化触底自动停滚 + 24000px 上限保护。
/// 所有悬浮边框/预览卡/工具条均启用 WDA_EXCLUDEFROMCAPTURE，绝不污染采集帧。
/// </summary>
public sealed class ScrollCaptureManager : IDisposable
{
    private readonly ClipboardMonitor _clipboardMonitor;
    private readonly HistoryStore _historyStore;

    private ScreenshotRect _targetPhysRect;
    private ScrollImageStitcher? _stitcher;
    private DispatcherTimer? _sampleTimer;
    private DispatcherTimer? _autoScrollTimer;
    private int _noMovementTicks;
    private bool _autoScrolling;

    private Window? _borderWin;
    private Window? _previewWin;
    private Image? _previewImg;
    private TextBlock? _previewDimText;
    private Window? _toolbarWin;
    private Button? _autoBtn;
    private TextBlock? _toolbarDimText;

    public bool IsActive => _stitcher != null;
    public event Action<SKBitmap, ScreenshotRect>? PinBitmapRequested;

    public ScrollCaptureManager(ClipboardMonitor clipboardMonitor, HistoryStore historyStore)
    {
        _clipboardMonitor = clipboardMonitor;
        _historyStore = historyStore;
    }

    public void Start(ScreenshotRect targetPhysRect)
    {
        if (!OperatingSystem.IsWindows())
            return;
        if (IsActive)
            StopAndDiscard();

        _targetPhysRect = targetPhysRect;
        _stitcher = new ScrollImageStitcher(cropInset: 0);
        _noMovementTicks = 0;
        _autoScrolling = false;

        CreateOverlayWindows();

        // 抓取首帧
        SampleOnce();

        _sampleTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        _sampleTimer.Tick += (_, _) => SampleOnce();
        _sampleTimer.Start();

        _autoScrollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _autoScrollTimer.Tick += (_, _) => SendScrollStep(-180);
    }

    public bool FinishAndPin()
    {
        if (!IsActive) return false;
        Finish(pin: true);
        return true;
    }

    private void SampleOnce()
    {
        if (_stitcher == null) return;

        int rx = (int)Math.Round(_targetPhysRect.Left);
        int ry = (int)Math.Round(_targetPhysRect.Top);
        int rw = Math.Max(1, (int)Math.Round(_targetPhysRect.Width));
        int rh = Math.Max(1, (int)Math.Round(_targetPhysRect.Height));

        using var frame = NativeMethods.CapturePhysicalRegion(rx, ry, rw, rh);
        if (frame == null) return;

        var res = _stitcher.Append(frame);
        if (res.NoMovement)
        {
            _noMovementTicks++;
            if (_autoScrolling && _noMovementTicks >= 16)
                ToggleAutoScroll(false);
        }
        else if (res.Appended)
        {
            _noMovementTicks = 0;
            UpdatePreviewBitmap();
            if (_stitcher.TotalPixelHeight >= ScrollImageStitcher.MaxPixelHeight)
                ToggleAutoScroll(false);
        }

        string dim = $"{_stitcher.Width} × {_stitcher.TotalPixelHeight}";
        if (_toolbarDimText != null) _toolbarDimText.Text = dim;
        if (_previewDimText != null) _previewDimText.Text = $"{dim} px";
    }

    private void UpdatePreviewBitmap()
    {
        if (_stitcher == null || _previewImg == null) return;
        using var stitched = _stitcher.AssembleStitchedImage();
        if (stitched == null) return;

        // 预览卡缩放到最大 180px 宽，保持轻盈
        const int previewW = 180;
        float ratio = (float)stitched.Height / Math.Max(1, stitched.Width);
        int previewH = Math.Clamp((int)Math.Round(previewW * ratio), 20, 420);

        using var scaled = stitched.Resize(new SKImageInfo(previewW, previewH), SKSamplingOptions.Default);
        if (scaled == null) return;
        byte[] png = ScreenshotRenderer.EncodePng(scaled);
        using var ms = new MemoryStream(png);
        var decoder = new PngBitmapDecoder(ms, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var src = decoder.Frames[0];
        src.Freeze();
        _previewImg.Source = src;
    }

    private void SendScrollStep(int delta)
    {
        if (_stitcher == null) return;
        int cx = (int)Math.Round(_targetPhysRect.MidX);
        int cy = (int)Math.Round(_targetPhysRect.MidY);
        if (NativeMethods.GetCursorPos(out var cur))
        {
            if (!_targetPhysRect.Contains(cur.X, cur.Y))
                NativeMethods.SetCursorPos(cx, cy);
        }
        else
        {
            NativeMethods.SetCursorPos(cx, cy);
        }
        NativeMethods.SendMouseWheel(delta);
    }

    private void ToggleAutoScroll(bool? force = null)
    {
        _autoScrolling = force ?? !_autoScrolling;
        _noMovementTicks = 0;
        if (_autoScrolling)
            _autoScrollTimer?.Start();
        else
            _autoScrollTimer?.Stop();

        if (_autoBtn != null)
            _autoBtn.Content = _autoScrolling ? "⏹ 停止" : "▶ 自动";
    }

    private void Finish(bool save = false, bool pin = false)
    {
        var stitched = _stitcher?.AssembleStitchedImage();
        CleanupOverlayAndTimers();
        _stitcher = null;

        if (stitched == null) return;

        if (save)
        {
            using (stitched)
            {
                var dlg = new SaveFileDialog
                {
                    Filter = "PNG 图片 (*.png)|*.png",
                    FileName = $"WinPaste_Scroll_{DateTime.Now:yyyyMMdd_HHmmss}.png"
                };
                if (dlg.ShowDialog() == true)
                    File.WriteAllBytes(dlg.FileName, ScreenshotRenderer.EncodePng(stitched));
            }
            return;
        }

        byte[] png = ScreenshotRenderer.EncodePng(stitched);
        _clipboardMonitor.WritePngBytes(png);

        if (pin)
        {
            PinBitmapRequested?.Invoke(stitched, _targetPhysRect);
            return;
        }

        using (stitched)
        {
            var saved = ImageStore.Save(png);
            if (saved != null)
            {
                _historyStore.Upsert(
                    ClipboardKind.Image,
                    $"{saved.PixelWidth}×{saved.PixelHeight}",
                    saved.DataPath,
                    saved.ThumbPath,
                    saved.Hash);
            }
        }
    }

    private void StopAndDiscard()
    {
        CleanupOverlayAndTimers();
        _stitcher = null;
    }

    private void CleanupOverlayAndTimers()
    {
        _sampleTimer?.Stop();
        _sampleTimer = null;
        _autoScrollTimer?.Stop();
        _autoScrollTimer = null;

        _borderWin?.Close();
        _borderWin = null;
        _previewWin?.Close();
        _previewWin = null;
        _toolbarWin?.Close();
        _toolbarWin = null;
    }

    private void CreateOverlayWindows()
    {
        double dpi = NativeMethods.GetDpiScaleAtPhysicalPoint((int)_targetPhysRect.MidX, (int)_targetPhysRect.MidY);
        const int pad = 3;

        // 1. 选区外空心高亮框（透明穿透、禁止被截屏捕获）
        _borderWin = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ShowInTaskbar = false,
            Topmost = true,
            IsHitTestVisible = false,
            Content = new Border
            {
                BorderBrush = new SolidColorBrush(Color.FromRgb(0x00, 0x7A, 0xFF)),
                BorderThickness = new Thickness(2.5),
                CornerRadius = new CornerRadius(2)
            }
        };
        _borderWin.SourceInitialized += (_, _) =>
        {
            nint hwnd = new WindowInteropHelper(_borderWin).Handle;
            NativeMethods.ApplyClickThrough(hwnd, true);
            NativeMethods.SetWindowDisplayAffinity(hwnd, NativeMethods.WDA_EXCLUDEFROMCAPTURE);
            NativeMethods.SetWindowPos(
                hwnd,
                NativeMethods.HWND_TOPMOST,
                (int)Math.Round(_targetPhysRect.Left - pad),
                (int)Math.Round(_targetPhysRect.Top - pad),
                (int)Math.Round(_targetPhysRect.Width + pad * 2),
                (int)Math.Round(_targetPhysRect.Height + pad * 2),
                NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);
        };
        _borderWin.Show();

        // 2. 实时拼接侧边预览卡
        var vRect = NativeMethods.GetVirtualScreenPhysicalRect();
        int cardPhysW = (int)Math.Round(196 * dpi);
        int cardPhysX = (int)_targetPhysRect.Right + 14;
        if (cardPhysX + cardPhysW > vRect.Right)
            cardPhysX = Math.Max(vRect.Left + 8, (int)_targetPhysRect.Left - cardPhysW - 14);
        int cardPhysY = Math.Max(vRect.Top + 8, (int)_targetPhysRect.Top);

        _previewImg = new Image { MaxWidth = 180, MaxHeight = 360, Stretch = Stretch.Uniform };
        _previewDimText = new TextBlock
        {
            Text = "0 × 0 px",
            FontSize = 11,
            Foreground = new SolidColorBrush(Color.FromRgb(0x5E, 0x66, 0x78)),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 6, 0, 0)
        };
        var previewStack = new StackPanel();
        previewStack.Children.Add(_previewImg);
        previewStack.Children.Add(_previewDimText);

        _previewWin = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ShowInTaskbar = false,
            Topmost = true,
            SizeToContent = SizeToContent.WidthAndHeight,
            Content = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(245, 255, 255, 255)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(8),
                Child = previewStack
            }
        };
        _previewWin.SourceInitialized += (_, _) =>
        {
            nint hwnd = new WindowInteropHelper(_previewWin).Handle;
            NativeMethods.ApplyNoActivateStyle(hwnd);
            NativeMethods.SetWindowDisplayAffinity(hwnd, NativeMethods.WDA_EXCLUDEFROMCAPTURE);
            NativeMethods.SetWindowPos(hwnd, NativeMethods.HWND_TOPMOST, cardPhysX, cardPhysY, 0, 0,
                NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);
        };
        _previewWin.Show();

        // 3. 极简长截图悬浮工具栏（276 × 34 DIP）
        var barRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        _toolbarDimText = new TextBlock
        {
            Text = "准备中",
            FontSize = 11,
            Foreground = new SolidColorBrush(Color.FromRgb(0x5E, 0x66, 0x78)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 8, 0)
        };
        _autoBtn = MakeToolBtn("▶ 自动", () => ToggleAutoScroll());
        var pinBtn = MakeToolBtn("贴屏", () => Finish(pin: true));
        var saveBtn = MakeToolBtn("保存", () => Finish(save: true));
        var cancelBtn = MakeToolBtn("取消", StopAndDiscard, danger: true);
        var doneBtn = MakeToolBtn("完成", () => Finish(), accent: true);

        barRow.Children.Add(_toolbarDimText);
        barRow.Children.Add(_autoBtn);
        barRow.Children.Add(pinBtn);
        barRow.Children.Add(saveBtn);
        barRow.Children.Add(cancelBtn);
        barRow.Children.Add(doneBtn);

        _toolbarWin = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ShowInTaskbar = false,
            Topmost = true,
            MinWidth = 276,
            Height = 40,
            SizeToContent = SizeToContent.Width,
            Content = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(245, 249, 250, 252)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(6, 4, 6, 4),
                Child = barRow
            }
        };
        _toolbarWin.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Space) { e.Handled = true; ToggleAutoScroll(); }
            else if (e.Key == Key.Down) { e.Handled = true; SendScrollStep(-180); }
            else if (e.Key == Key.Up) { e.Handled = true; SendScrollStep(180); }
            else if (e.Key == Key.Enter) { e.Handled = true; Finish(); }
            else if (e.Key == Key.F3) { e.Handled = true; Finish(pin: true); }
            else if (e.Key == Key.Escape) { e.Handled = true; StopAndDiscard(); }
        };
        _toolbarWin.SourceInitialized += (_, _) =>
        {
            nint hwnd = new WindowInteropHelper(_toolbarWin).Handle;
            NativeMethods.ApplyNoActivateStyle(hwnd);
            NativeMethods.SetWindowDisplayAffinity(hwnd, NativeMethods.WDA_EXCLUDEFROMCAPTURE);
            int barPhysX = (int)Math.Clamp(_targetPhysRect.MidX - 150 * dpi, vRect.Left + 8, vRect.Right - 320 * dpi);
            int barPhysY = (int)_targetPhysRect.Bottom + 10;
            if (barPhysY + 48 * dpi > vRect.Bottom)
                barPhysY = Math.Max(vRect.Top + 8, (int)_targetPhysRect.Top - (int)(48 * dpi));
            NativeMethods.SetWindowPos(hwnd, NativeMethods.HWND_TOPMOST, barPhysX, barPhysY, 0, 0,
                NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);
        };
        _toolbarWin.Show();
    }

    private static Button MakeToolBtn(string text, Action click, bool accent = false, bool danger = false)
    {
        var btn = new Button
        {
            Content = text,
            FontSize = 11.5,
            Padding = new Thickness(8, 3, 8, 3),
            Margin = new Thickness(2, 0, 2, 0),
            Cursor = Cursors.Hand,
            BorderThickness = new Thickness(0),
            Background = accent ? new SolidColorBrush(Color.FromRgb(0x00, 0x7A, 0xFF)) : Brushes.Transparent,
            Foreground = accent
                ? Brushes.White
                : danger
                    ? new SolidColorBrush(Color.FromRgb(0xFF, 0x3B, 0x30))
                    : new SolidColorBrush(Color.FromRgb(0x24, 0x24, 0x24))
        };
        btn.Click += (_, _) => click();
        return btn;
    }

    public void Dispose() => StopAndDiscard();
}
