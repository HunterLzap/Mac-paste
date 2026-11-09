import AppKit

final class StatusItemTarget: NSObject {
    var onClick: (() -> Void)?
    @objc func clicked() { onClick?() }
}

/// 菜单栏图标：左键/双击 = 打开独立主窗口；右键 = 设置菜单
final class PanelController: NSObject {
    /// 主窗口/预览窗共用的最小尺寸
    static let minSize = CGSize(width: 320, height: 360)

    private var statusItem: NSStatusItem?
    private let statusTarget = StatusItemTarget()
    private weak var viewModel: ClipboardViewModel?
    var onOpenMainWindow: (() -> Void)?

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "MacPaste")
            btn.image?.isTemplate = true
            statusTarget.onClick = { [weak self] in self?.handleStatusClick() }
            btn.target = statusTarget
            btn.action = #selector(StatusItemTarget.clicked)
        }
        statusItem = item
    }

    private func handleStatusClick() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.command) {
            showStatusMenu()
        } else {
            onOpenMainWindow?() // 单击/双击 → 独立主窗口
        }
    }

    private func showStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let snipItem = NSMenuItem(title: "区域截图 (F1)", action: #selector(menuSnip), keyEquivalent: "")
        snipItem.target = self
        menu.addItem(snipItem)

        let pinItem = NSMenuItem(title: "贴图当前剪贴板 (F3)", action: #selector(menuPinClipboard), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        let togglePinsItem = NSMenuItem(title: "隐藏 / 显示全部贴图 (⇧F3)", action: #selector(menuTogglePins), keyEquivalent: "")
        togglePinsItem.target = self
        menu.addItem(togglePinsItem)

        let closePinsItem = NSMenuItem(title: "关闭全部贴图", action: #selector(menuCloseAllPins), keyEquivalent: "")
        closePinsItem.target = self
        menu.addItem(closePinsItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MacPaste", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuSnip() {
        Task { @MainActor [weak self] in
            self?.viewModel?.onStartSnip?()
        }
    }

    @objc private func menuPinClipboard() {
        Task { @MainActor [weak self] in
            self?.viewModel?.pinCurrentOrLatest()
        }
    }

    @objc private func menuTogglePins() {
        Task { @MainActor in
            PinWindowManager.shared.toggleAllPins()
        }
    }

    @objc private func menuCloseAllPins() {
        Task { @MainActor in
            PinWindowManager.shared.closeAllPins()
        }
    }

    @objc private func menuOpenSettings() {
        onOpenMainWindow?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.viewModel?.settingsOpenRequest = true
        }
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }
}
