using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using WinPaste.App.Interop;
using WinPaste.App.Services;
using WinPaste.Core.Models;
using WinPaste.Core.Storage;

namespace WinPaste.App.Windows;

public partial class PreviewWindow : Window
{
    private readonly ClipboardViewModel _vm;
    private readonly AppSettingsStore _settings;
    private ClipboardItem? _item;
    private bool _showSegments = true;

    public bool IsPointerInside { get; private set; }
    public event Action? PointerEntered;
    public event Action? PointerExited;

    public PreviewWindow(ClipboardViewModel vm, AppSettingsStore settings)
    {
        InitializeComponent();
        _vm = vm;
        _settings = settings;
        Width = Math.Clamp(_settings.PreviewWidth, 280, 700) + 12;
        Height = Math.Clamp(_settings.PreviewHeight, 120, 700) + 12;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (OperatingSystem.IsWindows())
            NativeMethods.ApplyNoActivateStyle(new WindowInteropHelper(this).Handle);
    }

    public void ShowForItem(ClipboardItem item, Window anchorWindow)
    {
        _item = item;
        _showSegments = item.Paragraphs.Count >= 2;
        RenderItem();

        double w = Math.Clamp(_settings.PreviewWidth, 280, 700) + 12;
        double h = Math.Clamp(_settings.PreviewHeight, 120, 700) + 12;
        Width = w;
        Height = h;

        var workArea = SystemParameters.WorkArea;
        double left = anchorWindow.Left - w - 6;
        if (left < workArea.Left)
            left = anchorWindow.Left + anchorWindow.Width + 6;
        if (left + w > workArea.Right)
            left = Math.Max(workArea.Left, workArea.Right - w);

        double top = Math.Clamp(anchorWindow.Top, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - h));
        Left = left;
        Top = top;

        if (!IsVisible)
            Show();
    }

    private void RenderItem()
    {
        if (_item == null) return;
        var item = _item;

        string time = TimeFormatter.RelativeTimeShort(item.CreatedAt);
        string kindLabel = item.Kind.TabTitle();
        HeaderTitleText.Text = item.Paragraphs.Count >= 2
            ? $"{kindLabel} · 共 {item.Paragraphs.Count} 段 · {time}"
            : $"{kindLabel} · {time}";
        PinBadge.Visibility = item.Pinned ? Visibility.Visible : Visibility.Collapsed;
        CopyAllText.Text = item.Kind == ClipboardKind.Table ? "复制整表" : "复制全文";

        ModeToggleBorder.Visibility = item.Paragraphs.Count >= 2 ? Visibility.Visible : Visibility.Collapsed;
        UpdateModeButtons();

        SegmentsHost.Children.Clear();
        TablePreviewGrid.Children.Clear();

        if (item.Kind == ClipboardKind.Table)
        {
            SegmentsHost.Visibility = Visibility.Collapsed;
            RawContentText.Visibility = Visibility.Collapsed;
            TablePreviewGrid.Visibility = Visibility.Visible;
            BuildTableGrid(item);
            return;
        }

        TablePreviewGrid.Visibility = Visibility.Collapsed;
        if (_showSegments && item.Paragraphs.Count >= 2)
        {
            SegmentsHost.Visibility = Visibility.Visible;
            RawContentText.Visibility = Visibility.Collapsed;
            BuildSegmentCards(item.Paragraphs);
        }
        else
        {
            SegmentsHost.Visibility = Visibility.Collapsed;
            RawContentText.Visibility = Visibility.Visible;
            RawContentText.Text = TextUtils.DisplayTruncate(item.Content, 4000);
        }
    }

    private void UpdateModeButtons()
    {
        var accentBg = (Brush)FindResource("CardBackgroundBrush");
        var accentFg = (Brush)FindResource("AccentBrush");
        var secFg = (Brush)FindResource("TextSecondaryBrush");

        BtnSegView.Background = _showSegments ? accentBg : Brushes.Transparent;
        BtnSegView.Foreground = _showSegments ? accentFg : secFg;
        BtnRawView.Background = !_showSegments ? accentBg : Brushes.Transparent;
        BtnRawView.Foreground = !_showSegments ? accentFg : secFg;
    }

    private void BuildSegmentCards(IReadOnlyList<string> paragraphs)
    {
        var subtleBg = (Brush)FindResource("SubtleSurfaceBrush");
        var border = (Brush)FindResource("BorderHairlineBrush");
        var accent = (Brush)FindResource("AccentBrush");
        var primary = (Brush)FindResource("TextPrimaryBrush");
        var btnStyle = (Style)FindResource("TactileButtonStyle");

        for (int i = 0; i < paragraphs.Count; i++)
        {
            string seg = paragraphs[i];
            int idx = i;

            var card = new Border
            {
                Background = subtleBg,
                BorderBrush = border,
                BorderThickness = new Thickness(1),
                CornerRadius = new Thickness(8).Left == 8 ? new CornerRadius(8) : default,
                Padding = new Thickness(9, 7, 9, 7),
                Margin = new Thickness(0, 0, 0, 6)
            };

            var row = new DockPanel { LastChildFill = true };

            var badge = new Border
            {
                Background = accent,
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(6, 1, 6, 1),
                Margin = new Thickness(0, 1, 8, 0),
                VerticalAlignment = VerticalAlignment.Top,
                Child = new TextBlock
                {
                    Text = (idx + 1).ToString(),
                    FontSize = 10.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = Brushes.White
                }
            };
            DockPanel.SetDock(badge, Dock.Left);
            row.Children.Add(badge);

            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(6, 0, 0, 0)
            };
            var btnCopy = new Button
            {
                Content = new TextBlock { Text = "复制", FontSize = 11, Foreground = accent },
                Style = btnStyle,
                Padding = new Thickness(6, 2, 6, 2)
            };
            btnCopy.Click += (_, _) => _vm.CopyText(seg);
            var btnPaste = new Button
            {
                Content = new TextBlock { Text = "粘贴", FontSize = 11 },
                Style = btnStyle,
                Padding = new Thickness(6, 2, 6, 2)
            };
            btnPaste.Click += (_, _) => _vm.PasteSegment(seg);
            actions.Children.Add(btnCopy);
            actions.Children.Add(btnPaste);
            DockPanel.SetDock(actions, Dock.Right);
            row.Children.Add(actions);

            row.Children.Add(new TextBlock
            {
                Text = seg,
                FontSize = 12,
                LineHeight = 17.5,
                Foreground = primary,
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center
            });

            card.Child = row;
            SegmentsHost.Children.Add(card);
        }
    }

    private void BuildTableGrid(ClipboardItem item)
    {
        var rows = _vm.ParseTableRows(item);
        TablePreviewGrid.RowDefinitions.Clear();
        TablePreviewGrid.ColumnDefinitions.Clear();

        int maxR = Math.Min(30, rows.Length);
        int maxC = Math.Min(12, rows.Length > 0 ? rows.Max(r => r.Length) : 0);

        for (int r = 0; r < maxR; r++)
            TablePreviewGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (int c = 0; c < maxC; c++)
            TablePreviewGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });

        var borderBrush = (Brush)FindResource("BorderHairlineBrush");
        var headerBg = (Brush)FindResource("SubtleSurfaceBrush");
        var primary = (Brush)FindResource("TextPrimaryBrush");
        var secondary = (Brush)FindResource("TextSecondaryBrush");

        for (int r = 0; r < maxR; r++)
        {
            for (int c = 0; c < maxC; c++)
            {
                string val = c < rows[r].Length ? rows[r][c] : string.Empty;
                var cell = new Border
                {
                    Width = 76,
                    Height = 20,
                    BorderBrush = borderBrush,
                    BorderThickness = new Thickness(c == 0 ? 1 : 0, r == 0 ? 1 : 0, 1, 1),
                    Background = r == 0 ? headerBg : Brushes.White,
                    Padding = new Thickness(4, 1, 4, 1),
                    Child = new TextBlock
                    {
                        Text = val,
                        FontSize = 11,
                        FontWeight = r == 0 ? FontWeights.SemiBold : FontWeights.Normal,
                        Foreground = r == 0 ? primary : secondary,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        VerticalAlignment = VerticalAlignment.Center
                    }
                };
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                TablePreviewGrid.Children.Add(cell);
            }
        }
    }

    private void LeftThumb_DragDelta(object sender, DragDeltaEventArgs e) => ResizeTopRightAnchored(-e.HorizontalChange, 0);
    private void BottomThumb_DragDelta(object sender, DragDeltaEventArgs e) => ResizeTopRightAnchored(0, e.VerticalChange);
    private void BottomLeftThumb_DragDelta(object sender, DragDeltaEventArgs e) => ResizeTopRightAnchored(-e.HorizontalChange, e.VerticalChange);

    private void ResizeTopRightAnchored(double dw, double dh)
    {
        double curInnerW = Math.Clamp(Width - 12, 280, 700);
        double curInnerH = Math.Clamp(Height - 12, 120, 700);
        double nextInnerW = Math.Clamp(curInnerW + dw, 280, 700);
        double nextInnerH = Math.Clamp(curInnerH + dh, 120, 700);

        double actualDw = nextInnerW - curInnerW;
        Left -= actualDw;
        Width = nextInnerW + 12;
        Height = nextInnerH + 12;

        _settings.PreviewWidth = nextInnerW;
        _settings.PreviewHeight = nextInnerH;
    }

    private void BtnSegView_Click(object sender, RoutedEventArgs e) { _showSegments = true; RenderItem(); }
    private void BtnRawView_Click(object sender, RoutedEventArgs e) { _showSegments = false; RenderItem(); }
    private void BtnPin_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm.PinItem(_item); }
    private void BtnCopyAll_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm.CopyItem(_item); }

    private void Window_MouseEnter(object sender, MouseEventArgs e) { IsPointerInside = true; PointerEntered?.Invoke(); }
    private void Window_MouseLeave(object sender, MouseEventArgs e) { IsPointerInside = false; PointerExited?.Invoke(); }
}
