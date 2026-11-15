using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using WinPaste.App.Services;
using WinPaste.Core.Models;

namespace WinPaste.App.Views;

public partial class TextItemCardView : UserControl
{
    private ClipboardViewModel? _vm;
    private ClipboardItem? _item;

    public event Action<ClipboardItem, FrameworkElement>? HoverPreviewEnter;
    public event Action<ClipboardItem>? HoverPreviewLeave;

    public TextItemCardView()
    {
        InitializeComponent();
    }

    public void Bind(ClipboardViewModel vm, ClipboardItem item)
    {
        if (_vm != null)
            _vm.PropertyChanged -= Vm_PropertyChanged;

        _vm = vm;
        _item = item;
        _vm.PropertyChanged += Vm_PropertyChanged;

        bool isLong = item.Kind == ClipboardKind.LongText;
        ContentPreviewText.Text = TextUtils.DisplayTruncate(item.Content, 300);
        ContentPreviewText.MaxHeight = isLong ? 56 : 20;

        string time = TimeFormatter.RelativeTimeShort(item.CreatedAt);
        if (item.Paragraphs.Count >= 2)
        {
            MetaText.Text = $"{time} · 共 {item.Paragraphs.Count} 段";
            SegmentPillButton.Visibility = Visibility.Visible;
            SegmentPillText.Text = "按序粘贴";
            BtnSeqToggle.Visibility = Visibility.Visible;
            MenuSeqItem.Visibility = Visibility.Visible;
        }
        else
        {
            MetaText.Text = time;
            SegmentPillButton.Visibility = Visibility.Collapsed;
            BtnSeqToggle.Visibility = Visibility.Collapsed;
            MenuSeqItem.Visibility = Visibility.Collapsed;
        }

        PinBadge.Visibility = item.Pinned ? Visibility.Visible : Visibility.Collapsed;
        BtnPinText.Text = item.Pinned ? "取消置顶" : "置顶";
        MenuPinItem.Header = item.Pinned ? "取消置顶" : "置顶";

        UpdateModeAndFlash();
    }

    private void Vm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ClipboardViewModel.SequentialItemId)
            or nameof(ClipboardViewModel.SequentialIndex)
            or nameof(ClipboardViewModel.FlashItemId))
        {
            UpdateModeAndFlash();
        }
    }

    private void UpdateModeAndFlash()
    {
        if (_vm == null || _item == null) return;

        bool isSeq = _vm.SequentialItemId == _item.Id && _item.Paragraphs.Count >= 2;
        NormalPanel.Visibility = isSeq ? Visibility.Collapsed : Visibility.Visible;
        SequentialPanel.Visibility = isSeq ? Visibility.Visible : Visibility.Collapsed;

        if (isSeq)
        {
            var segs = _item.Paragraphs;
            int idx = Math.Clamp(_vm.SequentialIndex, 0, segs.Count - 1);
            SeqBadgeText.Text = $"按序 {idx + 1}/{segs.Count}";
            SeqCurrentText.Text = segs[idx];
            if (idx + 1 < segs.Count)
            {
                SeqNextText.Text = $"下一段（{idx + 2}/{segs.Count}）：{segs[idx + 1]}";
                SeqNextText.Visibility = Visibility.Visible;
            }
            else
            {
                SeqNextText.Visibility = Visibility.Collapsed;
            }
        }

        bool flashed = _vm.FlashItemId == _item.Id;
        CardBorder.Background = flashed
            ? new SolidColorBrush(Color.FromArgb(0x20, 0x28, 0xCD, 0x41))
            : isSeq
                ? (Brush)FindResource("SelectedTintBrush")
                : (IsMouseOver ? (Brush)FindResource("CardHoverBrush") : (Brush)FindResource("CardBackgroundBrush"));
        CardBorder.BorderBrush = flashed
            ? (Brush)FindResource("SuccessGreenBrush")
            : isSeq
                ? (Brush)FindResource("AccentBrush")
                : (Brush)FindResource("BorderHairlineBrush");
    }

    private void Root_MouseEnter(object sender, MouseEventArgs e)
    {
        HoverActions.Visibility = Visibility.Visible;
        UpdateModeAndFlash();
        if (_item != null)
            HoverPreviewEnter?.Invoke(_item, this);
    }

    private void Root_MouseLeave(object sender, MouseEventArgs e)
    {
        HoverActions.Visibility = Visibility.Collapsed;
        UpdateModeAndFlash();
        if (_item != null)
            HoverPreviewLeave?.Invoke(_item);
    }

    private void Root_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_vm != null && _item != null)
            _vm.ActivateItem(_item);
    }

    private void BtnToggleSeq_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.ToggleSequential(_item); }
    private void BtnPinToScreen_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.PinItem(_item); }
    private void BtnTogglePin_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.SetPinned(_item, !_item.Pinned); }
    private void BtnDelete_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.DeleteItem(_item); }

    private void BtnSeqPrev_Click(object sender, RoutedEventArgs e) { e.Handled = true; _vm?.StepSequential(-1); }
    private void BtnSeqNext_Click(object sender, RoutedEventArgs e) { e.Handled = true; _vm?.StepSequential(1); }
    private void BtnSeqReset_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) { _vm?.ResetSequential(); _vm?.ToggleSequential(_item); } }
    private void BtnSeqExit_Click(object sender, RoutedEventArgs e) { e.Handled = true; _vm?.ResetSequential(); }

    private void MenuCopy_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.CopyItem(_item); }
    private void MenuToggleSeq_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.ToggleSequential(_item); }
    private void MenuPinToScreen_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.PinItem(_item); }
    private void MenuTogglePin_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.SetPinned(_item, !_item.Pinned); }
    private void MenuDelete_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.DeleteItem(_item); }
}
