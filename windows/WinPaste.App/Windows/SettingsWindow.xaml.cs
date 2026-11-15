using System.Windows;
using System.Windows.Input;
using WinPaste.App.Services;
using WinPaste.Core.Storage;

namespace WinPaste.App.Windows;

public partial class SettingsWindow : Window
{
    private readonly ClipboardViewModel _vm;
    private bool _initializing = true;

    public event Action? QuitRequested;

    public SettingsWindow(ClipboardViewModel vm)
    {
        InitializeComponent();
        _vm = vm;
        SyncFromViewModel();
        _initializing = false;
    }

    private void SyncFromViewModel()
    {
        ChkLaunchAtLogin.IsChecked = _vm.LaunchAtLoginEnabled;
        RadClickCopy.IsChecked = _vm.ClickAction == ClickAction.Copy;
        RadClickPaste.IsChecked = _vm.ClickAction == ClickAction.Paste;
        ChkClearPinned.IsChecked = _vm.ClearIncludesPinned;
        TxtHistoryLimit.Text = _vm.HistoryLimit.ToString();
    }

    private void ChkLaunchAtLogin_Changed(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        _vm.LaunchAtLoginEnabled = ChkLaunchAtLogin.IsChecked == true;
        ChkLaunchAtLogin.IsChecked = _vm.LaunchAtLoginEnabled;
    }

    private void ClickAction_Checked(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        _vm.ClickAction = RadClickPaste.IsChecked == true ? ClickAction.Paste : ClickAction.Copy;
    }

    private void ChkClearPinned_Changed(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        _vm.ClearIncludesPinned = ChkClearPinned.IsChecked == true;
    }

    private void BtnLimitDec_Click(object sender, RoutedEventArgs e)
    {
        _vm.HistoryLimit = Math.Max(100, _vm.HistoryLimit - 100);
        TxtHistoryLimit.Text = _vm.HistoryLimit.ToString();
    }

    private void BtnLimitInc_Click(object sender, RoutedEventArgs e)
    {
        _vm.HistoryLimit = Math.Min(5000, _vm.HistoryLimit + 100);
        TxtHistoryLimit.Text = _vm.HistoryLimit.ToString();
    }

    private void BtnClose_Click(object sender, RoutedEventArgs e) => Close();

    private void BtnQuitApp_Click(object sender, RoutedEventArgs e)
    {
        Close();
        QuitRequested?.Invoke();
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
            Close();
    }
}
