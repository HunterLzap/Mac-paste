using System.Windows.Threading;
using WinPaste.App.Interop;

namespace WinPaste.App.Services;

/// <summary>
/// 持续追踪除 WinPaste 自身之外最近一次处于前台的外部窗口 HWND，用于无焦点自动粘贴回填。
/// </summary>
public sealed class ExternalAppTracker : IDisposable
{
    private readonly DispatcherTimer _timer;
    private readonly uint _selfPid = (uint)Environment.ProcessId;

    public nint LastExternalHwnd { get; private set; }

    public ExternalAppTracker()
    {
        _timer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(200)
        };
        _timer.Tick += (_, _) => CaptureForeground();
        _timer.Start();
        CaptureForeground();
    }

    public void CaptureForeground()
    {
        nint hwnd = NativeMethods.GetForegroundWindow();
        if (hwnd == nint.Zero || !NativeMethods.IsWindow(hwnd))
            return;

        NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid != _selfPid && pid != 0)
            LastExternalHwnd = hwnd;
    }

    public bool IsSelfForeground()
    {
        nint hwnd = NativeMethods.GetForegroundWindow();
        if (hwnd == nint.Zero) return false;
        NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        return pid == _selfPid;
    }

    public void Dispose()
    {
        _timer.Stop();
    }
}
