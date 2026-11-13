import AppKit
import SwiftUI

/// 支持首次点击直接响应（无需先激活窗口再点第二次）；拖窗交给显式的 WindowDragArea 处理，避免误拦截顶部按钮点击
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

/// 标题栏空隙专用原生拖拽区
struct WindowDragArea: NSViewRepresentable {
    final class DragNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragNSView {
        DragNSView()
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {}
}

/// 非激活式主面板：保留标准窗口红绿灯与缩放体验，但点击列表条目时不抢夺外部目标应用的输入焦点
final class MainPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 独立主窗口：标准标题栏窗口（可关闭/最小化/原生缩放），与快速面板共享同一 ViewModel。
/// 打开时 app 切为 .regular（Dock 图标 + Cmd-Tab 可见），关闭后回到 .accessory 菜单栏常驻。
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: MainPanel?
    private weak var viewModel: ClipboardViewModel?

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func showWindow() {
        if window == nil {
            let w = MainPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            w.title = "MacPaste 历史剪贴板"
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.minSize = PanelController.minSize
            w.setFrameAutosaveName("MacPasteMainWindow")
            w.delegate = self
            // 标题栏一体化：内容延伸到标题栏区域，隐藏标题，红绿灯保留悬浮在头部行上
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.titlebarSeparatorStyle = .none
            w.isMovableByWindowBackground = true
            if let vm = viewModel {
                let hide: () -> Void = { [weak w] in w?.close() }
                w.contentView = FirstMouseHostingView(rootView: ContentView(viewModel: vm, onHide: hide))
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        let pinned = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        applyAlwaysOnTop(pinned)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        if !pinned {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 让主窗口获取键盘焦点（点击搜索框时调用）
    func focusForKeyboard() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 「始终置顶」对独立窗口生效
    func applyAlwaysOnTop(_ pinned: Bool) {
        window?.isFloatingPanel = pinned
        window?.level = pinned ? .floating : .normal
    }

    /// 预览定位用
    var currentWindow: NSWindow? { window }

    func windowWillClose(_ notification: Notification) {
        PreviewController.shared.cancelPreview()
        NSApp.setActivationPolicy(.accessory)
    }
}
