using System.Windows;
using System.Windows.Threading;
using WinPaste.App.Services;
using WinPaste.Core.Models;
using WinPaste.Core.Storage;

namespace WinPaste.App.Windows;

/// <summary>
/// 悬浮长文/表格预览控制器（1:1 对齐 PreviewController.swift 时序参数）：
/// hoverDelay = 0.4s，itemGrace = 0.35s，previewGrace = 0.25s；图片跳过悬浮预览（双击打开 QuickLook）。
/// </summary>
public sealed class PreviewController : IDisposable
{
    private readonly PreviewWindow _window;
    private readonly DispatcherTimer _showTimer;
    private readonly DispatcherTimer _hideTimer;
    private Window? _anchorWindow;
    private ClipboardItem? _pendingItem;

    public PreviewController(ClipboardViewModel vm, AppSettingsStore settings)
    {
        _window = new PreviewWindow(vm, settings);
        _showTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.4) };
        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.35) };

        _window.PointerEntered += () => _hideTimer.Stop();
        _window.PointerExited += () => ScheduleHide(TimeSpan.FromSeconds(0.25));

        _showTimer.Tick += (_, _) =>
        {
            _showTimer.Stop();
            if (_pendingItem != null && _anchorWindow is { IsVisible: true } anchor)
                _window.ShowForItem(_pendingItem, anchor);
        };

        _hideTimer.Tick += (_, _) =>
        {
            _hideTimer.Stop();
            if (!_window.IsPointerInside)
                _window.Hide();
        };
    }

    public void AttachAnchor(Window anchorWindow) => _anchorWindow = anchorWindow;

    public void OnItemHoverEnter(ClipboardItem item)
    {
        if (item.Kind == ClipboardKind.Image)
            return;

        _hideTimer.Stop();
        _pendingItem = item;
        if (_window.IsVisible)
        {
            if (_anchorWindow != null)
                _window.ShowForItem(item, _anchorWindow);
        }
        else
        {
            _showTimer.Stop();
            _showTimer.Start();
        }
    }

    public void OnItemHoverLeave(ClipboardItem item)
    {
        if (_pendingItem?.Id == item.Id)
            _pendingItem = null;
        _showTimer.Stop();
        ScheduleHide(TimeSpan.FromSeconds(0.35));
    }

    public void DismissImmediately()
    {
        _pendingItem = null;
        _showTimer.Stop();
        _hideTimer.Stop();
        if (_window.IsVisible)
            _window.Hide();
    }

    private void ScheduleHide(TimeSpan grace)
    {
        _hideTimer.Stop();
        _hideTimer.Interval = grace;
        _hideTimer.Start();
    }

    public void Dispose()
    {
        _showTimer.Stop();
        _hideTimer.Stop();
        _window.Close();
    }
}
