using WinPaste.App.Interop;

namespace WinPaste.App.Services;

/// <summary>
/// 无焦点自动粘贴注入器：等待物理修饰键抬起 →（若需）恢复外部目标窗口前台焦点 → SendInput 发送 Ctrl+V
/// </summary>
public sealed class PasteInjector
{
    public DateTime LastSyntheticTime { get; private set; } = DateTime.MinValue;

    public async Task PasteToTargetAsync(
        ExternalAppTracker appTracker,
        bool waitModifierRelease = true,
        bool ensureTargetForeground = true)
    {
        if (!OperatingSystem.IsWindows())
            return;

        if (waitModifierRelease)
        {
            var deadline = DateTime.UtcNow.AddMilliseconds(400);
            while (DateTime.UtcNow < deadline && NativeMethods.IsAnyModifierDown())
                await Task.Delay(15);
        }

        if (ensureTargetForeground)
        {
            nint targetHwnd = appTracker.LastExternalHwnd;
            if (targetHwnd != nint.Zero && NativeMethods.IsWindow(targetHwnd) && appTracker.IsSelfForeground())
            {
                NativeMethods.SetForegroundWindow(targetHwnd);
                await Task.Delay(60);
            }
            else
            {
                await Task.Delay(40);
            }
        }
        else
        {
            await Task.Delay(40);
        }

        LastSyntheticTime = DateTime.UtcNow;
        NativeMethods.SendCtrlV();
    }
}
