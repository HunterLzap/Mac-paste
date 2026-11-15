using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using WinPaste.App.Services;

namespace WinPaste.App.Windows;

public partial class QuickLookWindow : Window
{
    private readonly string _imagePath;
    private readonly ClipboardMonitor _monitor;
    private readonly Action<string>? _pinFile;
    private double _zoom = 1.0;

    public QuickLookWindow(string imagePath, ClipboardMonitor monitor, Action<string>? pinFile = null)
    {
        InitializeComponent();
        _imagePath = imagePath;
        _monitor = monitor;
        _pinFile = pinFile;
        LoadImage();
    }

    private void LoadImage()
    {
        if (!File.Exists(_imagePath)) return;
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.UriSource = new Uri(_imagePath, UriKind.Absolute);
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.EndInit();
        bmp.Freeze();

        PreviewImg.Source = bmp;
        InfoLabel.Text = $"{bmp.PixelWidth} × {bmp.PixelHeight} px · {Path.GetFileName(_imagePath)}";
    }

    private void ImageScroller_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        e.Handled = true;
        double factor = e.Delta > 0 ? 1.12 : 0.89;
        _zoom = Math.Clamp(_zoom * factor, 0.2, 6.0);
        ImgScale.ScaleX = _zoom;
        ImgScale.ScaleY = _zoom;
        ZoomLabel.Text = $"{Math.Round(_zoom * 100)}%";
    }

    private void BtnCopy_Click(object sender, RoutedEventArgs e)
    {
        if (File.Exists(_imagePath))
            _monitor.WritePngBytes(File.ReadAllBytes(_imagePath));
    }

    private void BtnPin_Click(object sender, RoutedEventArgs e) => _pinFile?.Invoke(_imagePath);

    private void BtnSave_Click(object sender, RoutedEventArgs e)
    {
        if (!File.Exists(_imagePath)) return;
        var dlg = new SaveFileDialog
        {
            Filter = "PNG 图片 (*.png)|*.png",
            FileName = $"WinPaste_{DateTime.Now:yyyyMMdd_HHmmss}.png"
        };
        if (dlg.ShowDialog() == true)
            File.Copy(_imagePath, dlg.FileName, overwrite: true);
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape || e.Key == Key.Space)
            Close();
        else if (e.Key == Key.F3)
            _pinFile?.Invoke(_imagePath);
    }
}
