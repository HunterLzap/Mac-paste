using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using WinPaste.App.Interop;

namespace WinPaste.App.Windows;

public partial class PinToolbarWindow : Window
{
    public bool IsPointerInside { get; private set; }

    public event Action? HoverEntered;
    public event Action? HoverExited;
    public event Action? CollapseToggled;
    public event Action? OcrRequested;
    public event Action? BilingualRequested;
    public event Action? OpacityCycled;
    public event Action? CopyRequested;
    public event Action? SaveRequested;
    public event Action? CloseRequested;

    public PinToolbarWindow(bool isImage)
    {
        InitializeComponent();
        ImageOnlyButtons.Visibility = isImage ? Visibility.Visible : Visibility.Collapsed;
        BtnSave.Visibility = isImage ? Visibility.Visible : Visibility.Collapsed;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (OperatingSystem.IsWindows())
            NativeMethods.ApplyNoActivateStyle(new WindowInteropHelper(this).Handle);
    }

    public void UpdateState(bool collapsed, double opacity, string modeLabel)
    {
        BtnCollapse.Content = collapsed ? "展开" : "收起";
        BtnOpacity.Content = $"{Math.Round(opacity * 100)}%";
        TxtBilingual.Text = modeLabel == "Bilingual" ? "返回原图" : "双语对照";
        BtnOcr.Content = modeLabel == "Ocr" ? "返回原图" : "OCR取字";
    }

    public void PositionBeside(Window ownerPin)
    {
        UpdateLayout();
        double w = Math.Max(ActualWidth, 240);
        double h = Math.Max(ActualHeight, 38);
        var wa = SystemParameters.WorkArea;

        double left = Math.Clamp(
            ownerPin.Left + (ownerPin.Width - w) * 0.5,
            wa.Left + 4,
            Math.Max(wa.Left + 4, wa.Right - w - 4));

        // 优先上方悬浮；空间不足自动折到下方
        double top = ownerPin.Top - h - 4;
        if (top < wa.Top + 4)
            top = ownerPin.Top + ownerPin.Height + 4;

        Left = left;
        Top = Math.Clamp(top, wa.Top + 4, Math.Max(wa.Top + 4, wa.Bottom - h - 4));
    }

    private void Window_MouseEnter(object sender, MouseEventArgs e) { IsPointerInside = true; HoverEntered?.Invoke(); }
    private void Window_MouseLeave(object sender, MouseEventArgs e) { IsPointerInside = false; HoverExited?.Invoke(); }

    private void BtnCollapse_Click(object sender, RoutedEventArgs e) => CollapseToggled?.Invoke();
    private void BtnOcr_Click(object sender, RoutedEventArgs e) => OcrRequested?.Invoke();
    private void BtnBilingual_Click(object sender, RoutedEventArgs e) => BilingualRequested?.Invoke();
    private void BtnOpacityCycle_Click(object sender, RoutedEventArgs e) => OpacityCycled?.Invoke();
    private void BtnCopy_Click(object sender, RoutedEventArgs e) => CopyRequested?.Invoke();
    private void BtnSave_Click(object sender, RoutedEventArgs e) => SaveRequested?.Invoke();
    private void BtnClose_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();
}
