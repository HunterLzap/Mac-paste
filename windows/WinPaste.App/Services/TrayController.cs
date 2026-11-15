using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows;
using WinForms = System.Windows.Forms;

namespace WinPaste.App.Services;

/// <summary>
/// 系统托盘图标与右键菜单控制器（1:1 对齐 Mac 版 PanelController.swift 状态栏菜单）：
/// 左键切换主面板；右键打开 区域截图(F1) / 贴图(F3) / 隐藏显示全部贴图(Shift+F3) / 关闭全部贴图 / 设置 / 退出。
/// </summary>
public sealed class TrayController : IDisposable
{
    private readonly WinForms.NotifyIcon _notifyIcon;
    private readonly Icon _trayIcon;

    public event Action? ToggleMainRequested;
    public event Action? SnipRequested;
    public event Action? PinCurrentRequested;
    public event Action? ToggleAllPinsRequested;
    public event Action? CloseAllPinsRequested;
    public event Action? SettingsRequested;
    public event Action? QuitRequested;

    public TrayController()
    {
        _trayIcon = CreateClipboardIcon();
        var menu = new WinForms.ContextMenuStrip();

        menu.Items.Add("显示 / 隐藏主面板 (Alt+V)", null, (_, _) => RunUi(() => ToggleMainRequested?.Invoke()));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("区域截图 (F1)", null, (_, _) => RunUi(() => SnipRequested?.Invoke()));
        menu.Items.Add("贴图当前剪贴板 (F3)", null, (_, _) => RunUi(() => PinCurrentRequested?.Invoke()));
        menu.Items.Add("隐藏 / 显示全部贴图 (⇧F3)", null, (_, _) => RunUi(() => ToggleAllPinsRequested?.Invoke()));
        menu.Items.Add("关闭全部贴图", null, (_, _) => RunUi(() => CloseAllPinsRequested?.Invoke()));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("设置…", null, (_, _) => RunUi(() => SettingsRequested?.Invoke()));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("退出 WinPaste", null, (_, _) => RunUi(() => QuitRequested?.Invoke()));

        _notifyIcon = new WinForms.NotifyIcon
        {
            Text = "WinPaste - 剪贴板 · 截图 · 原位翻译 · 贴图",
            Icon = _trayIcon,
            ContextMenuStrip = menu,
            Visible = true
        };
        _notifyIcon.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Left)
                RunUi(() => ToggleMainRequested?.Invoke());
        };
    }

    private static void RunUi(Action action) => Application.Current?.Dispatcher.BeginInvoke(action);

    private static Icon CreateClipboardIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        using var accentBrush = new SolidBrush(Color.FromArgb(0x00, 0x7A, 0xFF));
        using var whitePen = new Pen(Color.White, 2.2f);
        using var whiteBrush = new SolidBrush(Color.White);

        // Rounded blue tile background
        using (var path = RoundedRect(2, 2, 28, 28, 7))
            g.FillPath(accentBrush, path);

        // Clipboard outline
        using (var clipBody = RoundedRect(8, 8, 16, 18, 2.5f))
            g.DrawPath(whitePen, clipBody);

        // Top clip tab
        g.FillRectangle(whiteBrush, 12, 5, 8, 4);
        // Lines inside clipboard
        g.FillRectangle(whiteBrush, 11, 13, 10, 2);
        g.FillRectangle(whiteBrush, 11, 18, 7, 2);

        nint hIcon = bmp.GetHicon();
        return Icon.FromHandle(hIcon);
    }

    private static GraphicsPath RoundedRect(float x, float y, float w, float h, float r)
    {
        float d = r * 2;
        var path = new GraphicsPath();
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + w - d, y, d, d, 270, 90);
        path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        path.AddArc(x, y + h - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _trayIcon.Dispose();
    }
}
