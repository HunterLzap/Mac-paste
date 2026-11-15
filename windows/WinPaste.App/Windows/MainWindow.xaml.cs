using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using WinPaste.App.Interop;
using WinPaste.App.Services;
using WinPaste.App.Views;
using WinPaste.Core.Models;
using WinPaste.Core.Storage;

namespace WinPaste.App.Windows;

public partial class MainWindow : Window
{
    private readonly ClipboardViewModel _vm;
    private readonly AppSettingsStore _settings;
    private readonly PreviewController _preview;
    private bool _searchExpanded;
    private bool _allowRealClose;

    public bool IsSearchBoxFocused => SearchTextBox.IsKeyboardFocusWithin;

    public event Action? SnipRequested;
    public event Action? SettingsRequested;

    public MainWindow(ClipboardViewModel vm, AppSettingsStore settings, PreviewController preview)
    {
        InitializeComponent();
        _vm = vm;
        _settings = settings;
        _preview = preview;
        _preview.AttachAnchor(this);

        Width = Math.Clamp(_settings.Snapshot.MainWindowWidth, 320, 1200);
        Height = Math.Clamp(_settings.Snapshot.MainWindowHeight, 360, 1400);
        if (_settings.Snapshot.MainWindowLeft is double l && _settings.Snapshot.MainWindowTop is double t)
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = l;
            Top = t;
        }
        else
        {
            var wa = SystemParameters.WorkArea;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = wa.Right - Width - 24;
            Top = wa.Top + (wa.Height - Height) * 0.4;
        }

        Topmost = _vm.AlwaysOnTop;
        UpdateAlwaysOnTopVisual();

        _vm.PropertyChanged += Vm_PropertyChanged;
        _vm.Items.CollectionChanged += (_, _) => RebuildItems();
        _vm.AlwaysOnTopChanged += v =>
        {
            Topmost = v;
            UpdateAlwaysOnTopVisual();
        };
        _vm.RequestHideMainWindow += () => HideMainPanel();

        UpdateTabButtons();
        RebuildItems();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (OperatingSystem.IsWindows())
            ApplyNoActivate(noActivate: true);
    }

    private void ApplyNoActivate(bool noActivate)
    {
        if (!OperatingSystem.IsWindows()) return;
        nint hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == nint.Zero) return;
        nint ex = NativeMethods.GetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE);
        ex |= NativeMethods.WS_EX_TOOLWINDOW;
        if (noActivate)
            ex |= NativeMethods.WS_EX_NOACTIVATE;
        else
            ex &= ~NativeMethods.WS_EX_NOACTIVATE;
        NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE, ex);
    }

    public void FocusForKeyboard()
    {
        ApplyNoActivate(noActivate: false);
        Activate();
    }

    public void ToggleMainPanel()
    {
        if (IsVisible)
            HideMainPanel();
        else
            ShowMainPanel();
    }

    public void ShowMainPanel()
    {
        ClampIntoWorkArea();
        ApplyNoActivate(noActivate: true);
        Topmost = true; // 显示时置于前层，若未固定顶置则保持自然顶部而不抢焦点
        if (!IsVisible)
            Show();
        Topmost = _vm.AlwaysOnTop;
        if (_vm.AlwaysOnTop)
            Topmost = true;
    }

    public void HideMainPanel()
    {
        _preview.DismissImmediately();
        if (IsVisible)
            Hide();
    }

    public void ForceClose()
    {
        _allowRealClose = true;
        Close();
    }

    private void ClampIntoWorkArea()
    {
        var wa = SystemParameters.WorkArea;
        Left = Math.Clamp(Left, wa.Left, Math.Max(wa.Left, wa.Right - Width));
        Top = Math.Clamp(Top, wa.Top, Math.Max(wa.Top, wa.Bottom - Height));
    }

    private void Vm_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ClipboardViewModel.Tab))
            UpdateTabButtons();
        else if (e.PropertyName == nameof(ClipboardViewModel.TotalCount))
            FooterCountText.Text = $"共 {_vm.TotalCount} 条";
    }

    private void UpdateTabButtons()
    {
        Button[] btns = [TabShortBtn, TabLongBtn, TabImageBtn, TabTableBtn];
        var cardBg = (Brush)FindResource("CardBackgroundBrush");
        var accentFg = (Brush)FindResource("AccentBrush");
        var secFg = (Brush)FindResource("TextSecondaryBrush");

        for (int i = 0; i < btns.Length; i++)
        {
            bool active = (int)_vm.Tab == i;
            btns[i].Background = active ? cardBg : Brushes.Transparent;
            btns[i].Foreground = active ? accentFg : secFg;
            btns[i].FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
        }
    }

    private void UpdateAlwaysOnTopVisual()
    {
        IconAlwaysOnTop.Fill = _vm.AlwaysOnTop
            ? (Brush)FindResource("AccentBrush")
            : (Brush)FindResource("TextSecondaryBrush");
        BtnAlwaysOnTop.Background = _vm.AlwaysOnTop
            ? (Brush)FindResource("AccentSoftBrush")
            : Brushes.Transparent;
    }

    private void RebuildItems()
    {
        LinearItemsHost.Children.Clear();
        ImageGridHost.Children.Clear();

        FooterCountText.Text = $"共 {_vm.TotalCount} 条";

        if (_vm.Items.Count == 0)
        {
            LinearItemsHost.Visibility = Visibility.Collapsed;
            ImageGridHost.Visibility = Visibility.Collapsed;
            EmptyStatePanel.Visibility = Visibility.Visible;
            EmptyStateLabel.Text = string.IsNullOrWhiteSpace(_vm.SearchText)
                ? "暂无剪贴板历史"
                : "无匹配结果";
            return;
        }

        EmptyStatePanel.Visibility = Visibility.Collapsed;

        if (_vm.Tab == ClipboardKind.Image)
        {
            LinearItemsHost.Visibility = Visibility.Collapsed;
            ImageGridHost.Visibility = Visibility.Visible;
            int cols = Math.Max(2, (int)Math.Floor((Math.Max(ActualWidth, Width) - 32) / 114.0));
            ImageGridHost.Columns = cols;

            foreach (var item in _vm.Items)
            {
                var cell = new ImageCellView { Margin = new Thickness(0, 0, 8, 8) };
                cell.Bind(_vm, item);
                ImageGridHost.Children.Add(cell);
            }
        }
        else if (_vm.Tab == ClipboardKind.Table)
        {
            ImageGridHost.Visibility = Visibility.Collapsed;
            LinearItemsHost.Visibility = Visibility.Visible;

            foreach (var item in _vm.Items)
            {
                var tableView = new TableCardView { Margin = new Thickness(0, 0, 0, 8) };
                tableView.Bind(_vm, item);
                tableView.MouseEnter += (_, _) => _preview.OnItemHoverEnter(item);
                tableView.MouseLeave += (_, _) => _preview.OnItemHoverLeave(item);
                LinearItemsHost.Children.Add(tableView);
            }
        }
        else
        {
            ImageGridHost.Visibility = Visibility.Collapsed;
            LinearItemsHost.Visibility = Visibility.Visible;

            foreach (var item in _vm.Items)
            {
                var card = new TextItemCardView { Margin = new Thickness(0, 0, 0, 6) };
                card.Bind(_vm, item);
                card.HoverPreviewEnter += (hovered, _) => _preview.OnItemHoverEnter(hovered);
                card.HoverPreviewLeave += hovered => _preview.OnItemHoverLeave(hovered);
                LinearItemsHost.Children.Add(card);
            }
        }
    }

    private void ToggleSearch(bool? forceState = null)
    {
        bool next = forceState ?? !_searchExpanded;
        _searchExpanded = next;
        if (next)
        {
            SearchCapsule.Visibility = Visibility.Visible;
            SearchCapsule.Width = Math.Max(110, Math.Min(165, ActualWidth - 230));
            SearchCapsule.Opacity = 1;
            AppTitleText.Visibility = ActualWidth < 380 ? Visibility.Collapsed : Visibility.Visible;
            FocusForKeyboard();
            SearchTextBox.Focus();
        }
        else
        {
            SearchTextBox.Text = string.Empty;
            _vm.SearchText = string.Empty;
            SearchCapsule.Width = 0;
            SearchCapsule.Opacity = 0;
            SearchCapsule.Visibility = Visibility.Collapsed;
            AppTitleText.Visibility = Visibility.Visible;
            ApplyNoActivate(noActivate: true);
        }
    }

    private void Tab_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag } && int.TryParse(tag, out int idx))
            _vm.Tab = (ClipboardKind)idx;
    }

    private void BtnToggleSearch_Click(object sender, RoutedEventArgs e) => ToggleSearch();
    private void BtnClearSearch_Click(object sender, RoutedEventArgs e)
    {
        SearchTextBox.Text = string.Empty;
        _vm.SearchText = string.Empty;
        SearchTextBox.Focus();
    }

    private void SearchTextBox_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e) =>
        FocusForKeyboard();

    private void SearchTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _vm.SearchText = SearchTextBox.Text;
        BtnClearSearch.Visibility = string.IsNullOrEmpty(SearchTextBox.Text) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SearchTextBox_LostFocus(object sender, RoutedEventArgs e) =>
        ApplyNoActivate(noActivate: true);

    private void BtnSnip_Click(object sender, RoutedEventArgs e) => SnipRequested?.Invoke();
    private void BtnPinCurrent_Click(object sender, RoutedEventArgs e) => _vm.PinCurrentOrLatest();
    private void BtnAlwaysOnTop_Click(object sender, RoutedEventArgs e) => _vm.AlwaysOnTop = !_vm.AlwaysOnTop;
    private void BtnSettings_Click(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();
    private void BtnHide_Click(object sender, RoutedEventArgs e) => HideMainPanel();

    private void BtnClearHistory_Click(object sender, RoutedEventArgs e)
    {
        var result = MessageBox.Show(
            _vm.ClearIncludesPinned
                ? "确定要清空全部剪贴板历史记录吗（含置顶）？"
                : "确定要清空非置顶的剪贴板历史记录吗？",
            "清空历史",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (result == MessageBoxResult.Yes)
            _vm.ClearHistory();
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.F && (Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            e.Handled = true;
            ToggleSearch(true);
            return;
        }

        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            if (_searchExpanded)
                ToggleSearch(false);
            else
                HideMainPanel();
        }
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (!_allowRealClose)
        {
            e.Cancel = true;
            HideMainPanel();
        }
    }

    private void Window_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (!IsVisible)
            _preview.DismissImmediately();
    }

    private void Window_BoundsChanged(object? sender, EventArgs e)
    {
        if (!IsLoaded) return;
        _settings.SaveMainWindowBounds(Left, Top, Width, Height);
        if (_vm.Tab == ClipboardKind.Image)
        {
            int cols = Math.Max(2, (int)Math.Floor((Math.Max(ActualWidth, Width) - 32) / 114.0));
            if (ImageGridHost.Columns != cols)
                ImageGridHost.Columns = cols;
        }
    }
}
