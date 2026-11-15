using System.Windows.Interop;
using System.Windows.Threading;
using WinPaste.App.Interop;

namespace WinPaste.App.Services;

/// <summary>
/// 全局快捷键注册器（RegisterHotKey + 每 3 秒自动重连未成功项）：
/// id=1 Alt+V 呼出/隐藏主面板
/// id=2 F1 区域截图
/// id=3 F3 贴图当前剪贴板 / 结束截图并贴图
/// id=4 Shift+F3 隐藏/显示全部贴图
/// id=5 Alt+Shift+V 按序粘贴下一段
/// </summary>
public sealed class HotKeyManager : IDisposable
{
    public const int IdToggle = 1;
    public const int IdSnip = 2;
    public const int IdPin = 3;
    public const int IdToggleAllPins = 4;
    public const int IdSequentialNext = 5;

    private readonly HashSet<int> _registered = [];
    private readonly DispatcherTimer _retryTimer;
    private HwndSource? _hwndSource;
    private bool _disposed;

    public event Action? OnToggleMain;
    public event Action? OnSnip;
    public event Action? OnPin;
    public event Action? OnToggleAllPins;
    public event Action? OnSequentialNext;

    public HotKeyManager()
    {
        _retryTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(3)
        };
        _retryTimer.Tick += (_, _) => RegisterMissing();
    }

    public void Start()
    {
        if (!OperatingSystem.IsWindows() || _hwndSource != null)
            return;

        var parameters = new HwndSourceParameters("WinPasteHotKeySink")
        {
            Width = 0,
            Height = 0,
            ParentWindow = new nint(-3)
        };
        _hwndSource = new HwndSource(parameters);
        _hwndSource.AddHook(WndProc);

        RegisterMissing();
        if (_registered.Count < 5)
            _retryTimer.Start();
    }

    private void RegisterMissing()
    {
        if (_hwndSource == null || _disposed) return;
        nint hwnd = _hwndSource.Handle;

        TryRegister(hwnd, IdToggle, NativeMethods.MOD_ALT | NativeMethods.MOD_NOREPEAT, NativeMethods.VK_V);
        TryRegister(hwnd, IdSnip, NativeMethods.MOD_NOREPEAT, NativeMethods.VK_F1);
        TryRegister(hwnd, IdPin, NativeMethods.MOD_NOREPEAT, NativeMethods.VK_F3);
        TryRegister(hwnd, IdToggleAllPins, NativeMethods.MOD_SHIFT | NativeMethods.MOD_NOREPEAT, NativeMethods.VK_F3);
        TryRegister(hwnd, IdSequentialNext, NativeMethods.MOD_ALT | NativeMethods.MOD_SHIFT | NativeMethods.MOD_NOREPEAT, NativeMethods.VK_V);

        if (_registered.Count >= 5)
            _retryTimer.Stop();
    }

    private void TryRegister(nint hwnd, int id, uint mods, uint vk)
    {
        if (_registered.Contains(id)) return;
        if (NativeMethods.RegisterHotKey(hwnd, id, mods, vk))
            _registered.Add(id);
    }

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_HOTKEY)
        {
            int id = wParam.ToInt32();
            switch (id)
            {
                case IdToggle: OnToggleMain?.Invoke(); break;
                case IdSnip: OnSnip?.Invoke(); break;
                case IdPin: OnPin?.Invoke(); break;
                case IdToggleAllPins: OnToggleAllPins?.Invoke(); break;
                case IdSequentialNext: OnSequentialNext?.Invoke(); break;
            }
            handled = true;
        }
        return nint.Zero;
    }

    public void Dispose()
    {
        _disposed = true;
        _retryTimer.Stop();
        if (_hwndSource != null)
        {
            if (OperatingSystem.IsWindows())
            {
                foreach (int id in _registered)
                    NativeMethods.UnregisterHotKey(_hwndSource.Handle, id);
            }
            _registered.Clear();
            _hwndSource.Dispose();
            _hwndSource = null;
        }
    }
}
