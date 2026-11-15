using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using WinPaste.App.Services;
using WinPaste.Core.Models;

namespace WinPaste.App.Views;

public partial class ImageCellView : UserControl
{
    private ClipboardViewModel? _vm;
    private ClipboardItem? _item;

    public ImageCellView()
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

        MetaText.Text = string.IsNullOrWhiteSpace(item.Content)
            ? TimeFormatter.RelativeTimeShort(item.CreatedAt)
            : $"{item.Content} · {TimeFormatter.RelativeTimeShort(item.CreatedAt)}";

        PinBadge.Visibility = item.Pinned ? Visibility.Visible : Visibility.Collapsed;
        MenuPinItem.Header = item.Pinned ? "取消置顶" : "置顶";

        LoadThumbnail(item.ThumbPath ?? item.DataPath);
        UpdateFlashAppearance();
    }

    private void LoadThumbnail(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            ThumbImage.Source = null;
            return;
        }

        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.UriSource = new Uri(path, UriKind.Absolute);
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.DecodePixelWidth = 256;
            bmp.EndInit();
            bmp.Freeze();
            ThumbImage.Source = bmp;
        }
        catch
        {
            ThumbImage.Source = null;
        }
    }

    private void Vm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ClipboardViewModel.FlashItemId))
            UpdateFlashAppearance();
    }

    private void UpdateFlashAppearance()
    {
        if (_vm == null || _item == null) return;
        bool flashed = _vm.FlashItemId == _item.Id;
        CardBorder.Background = flashed
            ? new SolidColorBrush(Color.FromArgb(0x20, 0x28, 0xCD, 0x41))
            : (IsMouseOver ? (Brush)FindResource("CardHoverBrush") : (Brush)FindResource("CardBackgroundBrush"));
        CardBorder.BorderBrush = flashed
            ? (Brush)FindResource("SuccessGreenBrush")
            : (Brush)FindResource("BorderHairlineBrush");
    }

    private void Root_MouseEnter(object sender, MouseEventArgs e)
    {
        BtnHoverPinToScreen.Visibility = Visibility.Visible;
        UpdateFlashAppearance();
    }

    private void Root_MouseLeave(object sender, MouseEventArgs e)
    {
        BtnHoverPinToScreen.Visibility = Visibility.Collapsed;
        UpdateFlashAppearance();
    }

    private void Root_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_vm == null || _item == null) return;
        if (e.ClickCount == 2 && !string.IsNullOrEmpty(_item.DataPath))
        {
            _vm.OpenQuickLook(_item.DataPath);
            return;
        }
        _vm.ActivateItem(_item);
    }

    private void Root_MouseRightButtonUp(object sender, MouseButtonEventArgs e) { }
    private void BtnPinToScreen_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.PinItem(_item); }
    private void MenuCopy_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.CopyItem(_item); }
    private void MenuPinToScreen_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.PinItem(_item); }
    private void MenuPreview_Click(object sender, RoutedEventArgs e) { if (!string.IsNullOrEmpty(_item?.DataPath)) _vm?.OpenQuickLook(_item.DataPath); }
    private void MenuTogglePin_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.SetPinned(_item, !_item.Pinned); }
    private void MenuDelete_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.DeleteItem(_item); }
}
