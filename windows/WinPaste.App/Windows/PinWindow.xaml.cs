using System.IO;
using System.Speech.Synthesis;
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
using WinPaste.App.Services;
using WinPaste.Core.Imaging;
using WinPaste.Core.Models;
using WinPaste.Core.OCR;
using WinPaste.Core.Parsing;
using WinPaste.Core.Storage;
using WinPaste.Core.Translation;

namespace WinPaste.App.Windows;

public partial class PinWindow : Window
{
    public enum PinKind { Image, Text, Table }
    private enum ViewMode { Normal, Ocr, Bilingual }

    private sealed record BilingualCardItem(int Index, string Original, string Translated);

    private readonly PinKind _kind;
    private readonly ClipboardMonitor _clipboardMonitor;
    private readonly IOcrEngine _ocrEngine;
    private readonly IEnglishSpellChecker _spellChecker;
    private readonly TranslationService _translator;
    private readonly AppSettingsStore _settings;

    private SKBitmap? _bitmap;
    private byte[]? _pngBytes;
    private string _textContent = string.Empty;
    private string[][] _tableRows = [];

    private readonly double _baseWidth;
    private readonly double _baseHeight;
    private double _zoom = 1.0;
    private double _opacityLevel = 1.0;
    private bool _collapsed;
    private ViewMode _mode = ViewMode.Normal;

    private List<(CheckBox Box, string Text)> _ocrLines = [];
    private List<BilingualCardItem> _bilingualCards = [];
    private SpeechSynthesizer? _tts;

    private PinToolbarWindow? _toolbar;
    private readonly DispatcherTimer _toolbarHideTimer;

    private bool _pointerDown;
    private bool _draggingWindow;
    private Point _dragStartScreen;
    private double _dragWinLeftStart;
    private double _dragWinTopStart;

    public bool IsHiddenByGlobalToggle { get; set; }
    public event Action<PinWindow>? PinClosed;

    public PinWindow(
        PinKind kind,
        ClipboardMonitor clipboardMonitor,
        IOcrEngine ocrEngine,
        IEnglishSpellChecker spellChecker,
        TranslationService translator,
        AppSettingsStore settings,
        SKBitmap? bitmap = null,
        string? text = null,
        string[][]? tableRows = null,
        ScreenshotRect? initialPhysRect = null)
    {
        InitializeComponent();
        _kind = kind;
        _clipboardMonitor = clipboardMonitor;
        _ocrEngine = ocrEngine;
        _spellChecker = spellChecker;
        _translator = translator;
        _settings = settings;

        _toolbarHideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(140) };
        _toolbarHideTimer.Tick += (_, _) =>
        {
            _toolbarHideTimer.Stop();
            if (_toolbar != null && !_toolbar.IsPointerInside && !IsMouseOver)
                _toolbar.Hide();
        };

        if (kind == PinKind.Image && bitmap != null)
        {
            _bitmap = bitmap;
            _pngBytes = ScreenshotRenderer.EncodePng(bitmap);
            using var ms = new MemoryStream(_pngBytes);
            var decoder = new PngBitmapDecoder(ms, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            var imgSrc = decoder.Frames[0];
            imgSrc.Freeze();
            PinnedImageView.Source = imgSrc;

            double dpi = initialPhysRect is { Width: > 0 } pr
                ? NativeMethods.GetDpiScaleAtPhysicalPoint((int)pr.MidX, (int)pr.MidY)
                : 1.0;
            double logicalW = Math.Clamp(bitmap.Width / dpi, 90, 960);
            double logicalH = Math.Clamp(bitmap.Height / dpi, 48, 760);
            _baseWidth = logicalW;
            _baseHeight = logicalH;

            Width = _baseWidth + 12;
            Height = _baseHeight + 12;

            if (initialPhysRect is { Width: > 10 } pRect)
            {
                WindowStartupLocation = WindowStartupLocation.Manual;
                Left = pRect.Left / dpi - 6;
                Top = pRect.Top / dpi - 6;
            }
            else
            {
                CenterWithCascade();
            }
        }
        else if (kind == PinKind.Table && tableRows != null)
        {
            _tableRows = tableRows;
            _baseWidth = Math.Clamp(tableRows.Max(r => r.Length) * 86 + 32, 240, 560);
            _baseHeight = Math.Clamp(tableRows.Length * 24 + 28, 110, 400);
            Width = _baseWidth + 12;
            Height = _baseHeight + 12;
            BuildTableGrid();
            CenterWithCascade();
        }
        else
        {
            _textContent = text ?? string.Empty;
            _baseWidth = 340;
            _baseHeight = Math.Clamp(60 + _textContent.Split('\n').Length * 22, 100, 380);
            Width = _baseWidth + 12;
            Height = _baseHeight + 12;
            PinnedTextReadonly.Text = _textContent;
            CenterWithCascade();
        }

        InitBilingualLanguageCombo();
        SyncVisiblePane();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (OperatingSystem.IsWindows())
            NativeMethods.ApplyNoActivateStyle(new WindowInteropHelper(this).Handle);
    }

    private void CenterWithCascade()
    {
        var wa = SystemParameters.WorkArea;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = wa.Left + (wa.Width - Width) * 0.5;
        Top = wa.Top + (wa.Height - Height) * 0.45;
    }

    private void InitBilingualLanguageCombo()
    {
        PinLangCombo.ItemsSource = TranslationService.CommonTargetLanguages;
        PinLangCombo.SelectedItem = TranslationService.CommonTargetLanguages
            .FirstOrDefault(l => l.Id == _settings.TargetLanguageId)
            ?? TranslationService.CommonTargetLanguages[0];
    }

    private void SyncVisiblePane()
    {
        CollapsedCapsule.Visibility = _collapsed ? Visibility.Visible : Visibility.Collapsed;
        PinnedImageView.Visibility = !_collapsed && _kind == PinKind.Image && _mode == ViewMode.Normal ? Visibility.Visible : Visibility.Collapsed;
        TextPinView.Visibility = !_collapsed && _kind == PinKind.Text ? Visibility.Visible : Visibility.Collapsed;
        TablePinScroller.Visibility = !_collapsed && _kind == PinKind.Table ? Visibility.Visible : Visibility.Collapsed;
        OcrListView.Visibility = !_collapsed && _kind == PinKind.Image && _mode == ViewMode.Ocr ? Visibility.Visible : Visibility.Collapsed;
        BilingualCardsView.Visibility = !_collapsed && _kind == PinKind.Image && _mode == ViewMode.Bilingual ? Visibility.Visible : Visibility.Collapsed;

        CtxSaveItem.Visibility = _kind == PinKind.Image ? Visibility.Visible : Visibility.Collapsed;
        CtxOcrItem.Visibility = _kind == PinKind.Image ? Visibility.Visible : Visibility.Collapsed;
        CtxBilingualItem.Visibility = _kind == PinKind.Image ? Visibility.Visible : Visibility.Collapsed;

        if (_collapsed)
        {
            CollapsedSummaryText.Text = _kind switch
            {
                PinKind.Image when _bitmap != null => $"图片 · {_bitmap.Width}×{_bitmap.Height}",
                PinKind.Table => $"表格 · {_tableRows.Length}×{(_tableRows.Length > 0 ? _tableRows[0].Length : 0)}",
                _ => $"文字 · {TextUtils.DisplayTruncate(_textContent.Replace('\n', ' '), 24)}"
            };
            Width = 240;
            Height = 46;
        }
        else if (_mode == ViewMode.Normal)
        {
            ApplyZoomDimensions(centerKeep: false);
        }
        else
        {
            Width = Math.Max(420, _baseWidth * _zoom) + 12;
            Height = Math.Max(340, _baseHeight * _zoom) + 12;
        }

        _toolbar?.UpdateState(_collapsed, _opacityLevel, _mode.ToString());
        _toolbar?.PositionBeside(this);
    }

    private void ApplyZoomDimensions(bool centerKeep)
    {
        if (_collapsed) return;
        double oldW = Width, oldH = Height;
        double targetW = (_mode == ViewMode.Normal ? _baseWidth : Math.Max(420, _baseWidth)) * _zoom + 12;
        double targetH = (_mode == ViewMode.Normal ? _baseHeight : Math.Max(340, _baseHeight)) * _zoom + 12;

        if (centerKeep)
        {
            Left -= (targetW - oldW) * 0.5;
            Top -= (targetH - oldH) * 0.5;
        }
        Width = targetW;
        Height = targetH;
    }

    private void BuildTableGrid()
    {
        PinnedTableGrid.Children.Clear();
        PinnedTableGrid.RowDefinitions.Clear();
        PinnedTableGrid.ColumnDefinitions.Clear();

        int maxR = Math.Min(TableParser.MaxRenderRows, _tableRows.Length);
        int maxC = Math.Min(TableParser.MaxRenderCols, _tableRows.Length > 0 ? _tableRows.Max(r => r.Length) : 0);

        for (int r = 0; r < maxR; r++)
            PinnedTableGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(23) });
        for (int c = 0; c < maxC; c++)
            PinnedTableGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(82) });

        var borderBrush = (Brush)FindResource("BorderHairlineBrush");
        var headerBg = (Brush)FindResource("SubtleSurfaceBrush");
        var primary = (Brush)FindResource("TextPrimaryBrush");
        var secondary = (Brush)FindResource("TextSecondaryBrush");

        for (int r = 0; r < maxR; r++)
        {
            for (int c = 0; c < maxC; c++)
            {
                string val = c < _tableRows[r].Length ? _tableRows[r][c] : string.Empty;
                var cell = new Border
                {
                    BorderBrush = borderBrush,
                    BorderThickness = new Thickness(c == 0 ? 1 : 0, r == 0 ? 1 : 0, 1, 1),
                    Background = r == 0 ? headerBg : Brushes.White,
                    Padding = new Thickness(5, 2, 5, 2),
                    Child = new TextBlock
                    {
                        Text = val,
                        FontSize = 11.5,
                        FontWeight = r == 0 ? FontWeights.SemiBold : FontWeights.Normal,
                        Foreground = r == 0 ? primary : secondary,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        VerticalAlignment = VerticalAlignment.Center
                    }
                };
                cell.MouseLeftButtonUp += (_, e) =>
                {
                    if (e.ClickCount == 2)
                        _clipboardMonitor.WriteText(val);
                };
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                PinnedTableGrid.Children.Add(cell);
            }
        }
    }

    private void EnsureToolbar()
    {
        if (_toolbar != null) return;
        _toolbar = new PinToolbarWindow(_kind == PinKind.Image);
        _toolbar.HoverEntered += () => _toolbarHideTimer.Stop();
        _toolbar.HoverExited += () =>
        {
            _toolbarHideTimer.Stop();
            _toolbarHideTimer.Start();
        };
        _toolbar.CollapseToggled += ToggleCollapse;
        _toolbar.OcrRequested += ToggleOcrMode;
        _toolbar.BilingualRequested += ToggleBilingualMode;
        _toolbar.OpacityCycled += CycleOpacity;
        _toolbar.CopyRequested += CopyCurrentContent;
        _toolbar.SaveRequested += SaveImageAs;
        _toolbar.CloseRequested += Close;
        _toolbar.UpdateState(_collapsed, _opacityLevel, _mode.ToString());
    }

    private void Window_MouseEnter(object sender, MouseEventArgs e)
    {
        if (IsHiddenByGlobalToggle) return;
        _toolbarHideTimer.Stop();
        EnsureToolbar();
        _toolbar!.PositionBeside(this);
        if (!_toolbar.IsVisible)
            _toolbar.Show();
    }

    private void Window_MouseLeave(object sender, MouseEventArgs e)
    {
        _toolbarHideTimer.Stop();
        _toolbarHideTimer.Start();
    }

    private void Window_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        // Alt 键按住或正在文本编辑时允许自由选字而不拖拽窗口
        if ((Keyboard.Modifiers & ModifierKeys.Alt) != 0 || TextEditPanel.Visibility == Visibility.Visible)
            return;

        if (_kind == PinKind.Text && e.ClickCount == 2)
        {
            PinnedTextEditor.Text = _textContent;
            PinnedTextReadonly.Visibility = Visibility.Collapsed;
            TextEditPanel.Visibility = Visibility.Visible;
            PinnedTextEditor.Focus();
            e.Handled = true;
            return;
        }

        // 在按钮、输入框、ComboBox 上点击时不劫持鼠标
        if (IsInteractiveChild(e.OriginalSource as DependencyObject))
            return;

        _pointerDown = true;
        _draggingWindow = false;
        _dragStartScreen = PointToScreen(e.GetPosition(this));
        _dragWinLeftStart = Left;
        _dragWinTopStart = Top;
    }

    private void Window_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (!_pointerDown || e.LeftButton != MouseButtonState.Pressed)
            return;

        var curScreen = PointToScreen(e.GetPosition(this));
        double dx = curScreen.X - _dragStartScreen.X;
        double dy = curScreen.Y - _dragStartScreen.Y;
        if (!_draggingWindow && Math.Sqrt(dx * dx + dy * dy) >= 4.0)
        {
            _draggingWindow = true;
            Mouse.Capture(this);
        }

        if (_draggingWindow)
        {
            var scale = VisualTreeHelper.GetDpi(this);
            Left = _dragWinLeftStart + dx / scale.DpiScaleX;
            Top = _dragWinTopStart + dy / scale.DpiScaleY;
        }
    }

    private void Window_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        _pointerDown = false;
        if (_draggingWindow)
        {
            _draggingWindow = false;
            if (IsMouseCaptured) ReleaseMouseCapture();
            e.Handled = true;
        }
    }

    private void Window_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        bool ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        bool alt = (Keyboard.Modifiers & ModifierKeys.Alt) != 0;

        if (ctrl)
        {
            e.Handled = true;
            _opacityLevel = Math.Clamp(_opacityLevel + (e.Delta > 0 ? 0.08 : -0.08), 0.15, 1.0);
            CardShell.Opacity = _opacityLevel;
            _toolbar?.UpdateState(_collapsed, _opacityLevel, _mode.ToString());
            return;
        }

        // 若正停留在可垂直滚动的 OCR / 双语卡片 / 表格区域且有溢出内容，且未按 Alt，则让 ScrollViewer 正常滚动
        if (!alt && IsInsideOverflowScrollViewer(e.OriginalSource as DependencyObject))
            return;

        if (_collapsed) return;

        e.Handled = true;
        double factor = e.Delta > 0 ? 1.08 : 0.92;
        _zoom = Math.Clamp(_zoom * factor, 0.65, 2.50);
        ApplyZoomDimensions(centerKeep: true);
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        bool ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        if (e.Key == Key.Escape || (ctrl && e.Key == Key.W))
        {
            e.Handled = true;
            Close();
        }
        else if (ctrl && (e.Key == Key.OemPlus || e.Key == Key.Add))
        {
            e.Handled = true;
            _zoom = Math.Clamp(_zoom * 1.12, 0.65, 2.50);
            ApplyZoomDimensions(centerKeep: true);
        }
        else if (ctrl && (e.Key == Key.OemMinus || e.Key == Key.Subtract))
        {
            e.Handled = true;
            _zoom = Math.Clamp(_zoom * 0.89, 0.65, 2.50);
            ApplyZoomDimensions(centerKeep: true);
        }
        else if (ctrl && (e.Key == Key.D0 || e.Key == Key.NumPad0))
        {
            e.Handled = true;
            _zoom = 1.0;
            ApplyZoomDimensions(centerKeep: true);
        }
    }

    private static bool IsInteractiveChild(DependencyObject? d)
    {
        while (d != null)
        {
            if (d is Button or ComboBox or CheckBox or TextBox)
                return d is not TextBox tb || !tb.IsReadOnly;
            d = VisualTreeHelper.GetParent(d);
        }
        return false;
    }

    private static bool IsInsideOverflowScrollViewer(DependencyObject? d)
    {
        while (d != null)
        {
            if (d is ScrollViewer sv && (sv.ScrollableHeight > 1.0 || sv.ScrollableWidth > 1.0))
                return true;
            d = VisualTreeHelper.GetParent(d);
        }
        return false;
    }

    private void ToggleCollapse()
    {
        _collapsed = !_collapsed;
        SyncVisiblePane();
    }

    private void CycleOpacity()
    {
        _opacityLevel = _opacityLevel > 0.9 ? 0.65 : _opacityLevel > 0.55 ? 0.35 : 1.0;
        CardShell.Opacity = _opacityLevel;
        _toolbar?.UpdateState(_collapsed, _opacityLevel, _mode.ToString());
    }

    private void ToggleOcrMode()
    {
        if (_kind != PinKind.Image || _bitmap == null) return;
        if (_mode == ViewMode.Ocr)
        {
            _mode = ViewMode.Normal;
            SyncVisiblePane();
            return;
        }
        _collapsed = false;
        _mode = ViewMode.Ocr;
        SyncVisiblePane();
        _ = RunOcrExtractAsync();
    }

    private void ToggleBilingualMode()
    {
        if (_kind != PinKind.Image || _bitmap == null) return;
        if (_mode == ViewMode.Bilingual)
        {
            _mode = ViewMode.Normal;
            SyncVisiblePane();
            return;
        }
        _collapsed = false;
        _mode = ViewMode.Bilingual;
        SyncVisiblePane();
        _ = RunBilingualCardsAsync();
    }

    private async Task RunOcrExtractAsync()
    {
        if (_bitmap == null) return;
        OcrStatusText.Text = "正在识别文字…";
        OcrLinesHost.Children.Clear();
        _ocrLines.Clear();

        try
        {
            var lines = await _ocrEngine.RecognizeLinesAsync(_bitmap);
            if (lines.Count == 0)
            {
                OcrStatusText.Text = "未识别到文字";
                return;
            }

            OcrStatusText.Text = $"OCR 取字（{lines.Count} 行）";
            var primary = (Brush)FindResource("TextPrimaryBrush");
            var subtle = (Brush)FindResource("SubtleSurfaceBrush");

            foreach (var line in lines)
            {
                var cb = new CheckBox
                {
                    Margin = new Thickness(0, 2, 8, 0),
                    VerticalAlignment = VerticalAlignment.Top
                };
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 5) };
                DockPanel.SetDock(cb, Dock.Left);
                row.Children.Add(cb);
                row.Children.Add(new TextBox
                {
                    Text = line,
                    IsReadOnly = true,
                    BorderThickness = new Thickness(0),
                    Background = subtle,
                    Padding = new Thickness(6, 4, 6, 4),
                    FontSize = 12,
                    Foreground = primary,
                    TextWrapping = TextWrapping.Wrap
                });
                _ocrLines.Add((cb, line));
                OcrLinesHost.Children.Add(row);
            }
        }
        catch
        {
            OcrStatusText.Text = "OCR 识别失败";
        }
    }

    private async Task RunBilingualCardsAsync()
    {
        if (_bitmap == null) return;
        string targetCode = (PinLangCombo.SelectedItem as TranslationService.TargetLanguage)?.Code ?? "zh-CN";
        BilingualStatusText.Text = "正在生成双语对照…";
        BilingualCardsHost.Children.Clear();
        _bilingualCards.Clear();

        try
        {
            var blocks = await _ocrEngine.RecognizeTextBlocksAsync(_bitmap, _spellChecker);
            if (blocks.Count == 0)
            {
                BilingualStatusText.Text = "未检测到文字段落";
                return;
            }

            var originals = blocks.Select(b => b.Text).ToList();
            var translated = await _translator.TranslateBatchAsync(originals, targetCode: targetCode);

            BilingualStatusText.Text = $"1-to-1 双语对照（共 {blocks.Count} 段）";
            var subtle = (Brush)FindResource("SubtleSurfaceBrush");
            var border = (Brush)FindResource("BorderHairlineBrush");
            var accent = (Brush)FindResource("AccentBrush");
            var primary = (Brush)FindResource("TextPrimaryBrush");
            var secondary = (Brush)FindResource("TextSecondaryBrush");
            var btnStyle = (Style)FindResource("TactileButtonStyle");

            for (int i = 0; i < blocks.Count; i++)
            {
                int idx = i + 1;
                string orig = blocks[i].Text;
                string tr = i < translated.Length ? translated[i] : orig;
                _bilingualCards.Add(new BilingualCardItem(idx, orig, tr));

                var card = new Border
                {
                    Background = subtle,
                    BorderBrush = border,
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(10, 8, 10, 8),
                    Margin = new Thickness(0, 0, 0, 7)
                };

                var stack = new StackPanel();

                var topBar = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
                var numBadge = new Border
                {
                    Background = accent,
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(6, 1, 6, 1),
                    Child = new TextBlock { Text = idx.ToString(), FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White }
                };
                DockPanel.SetDock(numBadge, Dock.Left);
                topBar.Children.Add(numBadge);

                var cardBtns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                var btnSpeak = new Button { Content = "朗读", Style = btnStyle, FontSize = 10.5, Padding = new Thickness(5, 1, 5, 1) };
                btnSpeak.Click += (_, _) => SpeakText(orig);
                var btnCopy = new Button { Content = "复制译文", Style = btnStyle, FontSize = 10.5, Padding = new Thickness(5, 1, 5, 1) };
                btnCopy.Click += (_, _) => _clipboardMonitor.WriteText(tr);
                cardBtns.Children.Add(btnSpeak);
                cardBtns.Children.Add(btnCopy);
                DockPanel.SetDock(cardBtns, Dock.Right);
                topBar.Children.Add(cardBtns);
                stack.Children.Add(topBar);

                stack.Children.Add(new TextBox
                {
                    Text = orig,
                    IsReadOnly = true,
                    BorderThickness = new Thickness(0),
                    Background = Brushes.Transparent,
                    FontSize = 11.5,
                    Foreground = secondary,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 0, 0, 4)
                });
                stack.Children.Add(new TextBox
                {
                    Text = tr,
                    IsReadOnly = true,
                    BorderThickness = new Thickness(0),
                    Background = Brushes.Transparent,
                    FontSize = 12.5,
                    FontWeight = FontWeights.Medium,
                    Foreground = primary,
                    TextWrapping = TextWrapping.Wrap
                });

                card.Child = stack;
                BilingualCardsHost.Children.Add(card);
            }
        }
        catch
        {
            BilingualStatusText.Text = "翻译失败，请检查网络连接";
        }
    }

    private void SpeakText(string text)
    {
        try
        {
            _tts ??= new SpeechSynthesizer();
            _tts.SpeakAsyncCancelAll();
            _tts.SpeakAsync(text);
        }
        catch { }
    }

    private void CopyCurrentContent()
    {
        if (_kind == PinKind.Image && _pngBytes != null)
            _clipboardMonitor.WritePngBytes(_pngBytes);
        else if (_kind == PinKind.Table)
            _clipboardMonitor.WriteTable(TableParser.CanonicalTsv(_tableRows), TableParser.HtmlTable(_tableRows));
        else
            _clipboardMonitor.WriteText(_textContent);
    }

    private void SaveImageAs()
    {
        if (_kind != PinKind.Image || _pngBytes == null) return;
        var dlg = new SaveFileDialog
        {
            Filter = "PNG 图片 (*.png)|*.png",
            FileName = $"WinPaste_Pin_{DateTime.Now:yyyyMMdd_HHmmss}.png"
        };
        if (dlg.ShowDialog() == true)
            File.WriteAllBytes(dlg.FileName, _pngBytes);
    }

    private void PinLangCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PinLangCombo.SelectedItem is TranslationService.TargetLanguage lang)
        {
            _settings.TargetLanguageId = lang.Id;
            if (_mode == ViewMode.Bilingual)
                _ = RunBilingualCardsAsync();
        }
    }

    private void BtnCopySelectedOcr_Click(object sender, RoutedEventArgs e)
    {
        var sel = _ocrLines.Where(x => x.Box.IsChecked == true).Select(x => x.Text).ToList();
        if (sel.Count > 0)
            _clipboardMonitor.WriteText(string.Join("\n", sel));
    }

    private void BtnCopyAllOcr_Click(object sender, RoutedEventArgs e)
    {
        if (_ocrLines.Count > 0)
            _clipboardMonitor.WriteText(string.Join("\n", _ocrLines.Select(x => x.Text)));
    }

    private void BtnCopyAllTranslations_Click(object sender, RoutedEventArgs e)
    {
        if (_bilingualCards.Count > 0)
            _clipboardMonitor.WriteText(string.Join("\n", _bilingualCards.Select(c => c.Translated)));
    }

    private void BtnBackToImage_Click(object sender, RoutedEventArgs e)
    {
        _mode = ViewMode.Normal;
        SyncVisiblePane();
    }

    private void BtnExpand_Click(object sender, RoutedEventArgs e) => ToggleCollapse();
    private void CollapsedCapsule_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            e.Handled = true;
            ToggleCollapse();
        }
    }

    private void BtnSaveTextEdit_Click(object sender, RoutedEventArgs e)
    {
        _textContent = PinnedTextEditor.Text;
        PinnedTextReadonly.Text = _textContent;
        TextEditPanel.Visibility = Visibility.Collapsed;
        PinnedTextReadonly.Visibility = Visibility.Visible;
        _clipboardMonitor.WriteText(_textContent);
    }

    private void BtnCancelTextEdit_Click(object sender, RoutedEventArgs e)
    {
        TextEditPanel.Visibility = Visibility.Collapsed;
        PinnedTextReadonly.Visibility = Visibility.Visible;
    }

    private void Window_LocationChanged(object? sender, EventArgs e)
    {
        if (_toolbar != null && _toolbar.IsVisible)
            _toolbar.PositionBeside(this);
    }

    public void HideWithToolbar()
    {
        _toolbar?.Hide();
        Hide();
    }

    private void Window_Closed(object? sender, EventArgs e)
    {
        _toolbarHideTimer.Stop();
        _toolbar?.Close();
        _toolbar = null;
        _tts?.Dispose();
        _bitmap?.Dispose();
        PinClosed?.Invoke(this);
    }

    private void CtxCopy_Click(object sender, RoutedEventArgs e) => CopyCurrentContent();
    private void CtxSave_Click(object sender, RoutedEventArgs e) => SaveImageAs();
    private void CtxOcr_Click(object sender, RoutedEventArgs e) => ToggleOcrMode();
    private void CtxBilingual_Click(object sender, RoutedEventArgs e) => ToggleBilingualMode();
    private void CtxCollapse_Click(object sender, RoutedEventArgs e) => ToggleCollapse();
    private void CtxResetZoom_Click(object sender, RoutedEventArgs e) { _zoom = 1.0; ApplyZoomDimensions(centerKeep: true); }
    private void CtxClose_Click(object sender, RoutedEventArgs e) => Close();
}
