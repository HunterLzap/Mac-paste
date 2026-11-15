using System.Diagnostics;
using System.Windows;
using WinPaste.App.Interop;

namespace WinPaste.App.Services;

/// <summary>
/// 全局 Ctrl+V 监听（WH_KEYBOARD_LL），用于按序粘贴自动步进下一段；
/// 严格过滤 PasteInjector 300ms 内的合成按键与 160ms 抖动，且搜索框输入时不劫持。
/// </summary>
public sealed class CtrlVMonitor : IDisposable
{
    private readonly PasteInjector _injector;
    private readonly ExternalAppTracker _appTracker;
    private nint _hookId;
    private NativeMethods.LowLevelKeyboardProc? _hookProc;
    private DateTime _lastFired = DateTime.MinValue;

    public Func<bool>? IsSearchBoxFocused { get; set; }
    public event Action<bool>? OnUserCtrlV;

    public CtrlVMonitor(PasteInjector injector, ExternalAppTracker appTracker)
    {
        _injector = injector;
        _appTracker = appTracker;
    }

    public void Start()
    {
        if (!OperatingSystem.IsWindows() || _hookId != nint.Zero)
            return;

        _hookProc = HookCallback;
        using var curProcess = Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        _hookId = NativeMethods.SetWindowsHookEx(
            NativeMethods.WH_KEYBOARD_LL,
            _hookProc,
            NativeMethods.GetModuleHandle(curModule?.ModuleName),
            0);
    }

    private nint HookCallback(int nCode, nint wParam, nint lParam)
    {
        if (nCode >= 0 && (wParam == NativeMethods.WM_KEYDOWN || wParam == NativeMethods.WM_SYSKEYDOWN))
        {
            var info = System.Runtime.InteropServices.Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
            if (info.vkCode == NativeMethods.VK_V)
            {
                bool ctrlDown = NativeMethods.IsKeyDown(NativeMethods.VK_CONTROL);
                bool altDown = NativeMethods.IsKeyDown(NativeMethods.VK_MENU);
                bool shiftDown = NativeMethods.IsKeyDown(NativeMethods.VK_SHIFT);
                bool winDown = NativeMethods.IsKeyDown(NativeMethods.VK_LWIN) || NativeMethods.IsKeyDown(NativeMethods.VK_RWIN);

                if (ctrlDown && !altDown && !shiftDown && !winDown)
                {
                    var now = DateTime.UtcNow;
                    if ((now - _injector.LastSyntheticTime).TotalSeconds >= 0.30
                        && (now - _lastFired).TotalSeconds >= 0.16)
                    {
                        _lastFired = now;
                        bool inSelf = _appTracker.IsSelfForeground();
                        Application.Current?.Dispatcher.BeginInvoke(() =>
                        {
                            if (inSelf && (IsSearchBoxFocused?.Invoke() ?? false))
                                return;
                            OnUserCtrlV?.Invoke(inSelf);
                        });
                    }
                }
            }
        }

        return NativeMethods.CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hookId != nint.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_hookId);
            _hookId = nint.Zero;
        }
        _hookProc = null;
    }
}
