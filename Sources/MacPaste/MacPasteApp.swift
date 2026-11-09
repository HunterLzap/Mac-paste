import AppKit

/// 追踪最近一次激活的外部前台应用（粘贴时用于从 MacPaste 切回目标应用）
final class ExternalAppTracker {
    static let shared = ExternalAppTracker()
    private(set) var lastExternal: NSRunningApplication?

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.lastExternal = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.lastExternal = app
            }
        }
    }

    func start() {}
}

/// 应用装配：菜单栏 app（accessory），创建面板/监听/热键
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?
    private var monitor: ClipboardMonitor?
    private var hotkeyManager: HotKeyManager?
    private var viewModel: ClipboardViewModel?
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ExternalAppTracker.shared.start()
        let store = HistoryStore()
        let vm = ClipboardViewModel(store: store)
        viewModel = vm

        let mwc = MainWindowController(viewModel: vm)
        mainWindowController = mwc
        vm.onOpenMainWindow = { [weak mwc] in mwc?.showWindow() }
        vm.onFocusWindowForKeyboard = { [weak mwc] in mwc?.focusForKeyboard() }
        vm.onAlwaysOnTopChanged = { [weak mwc] pinned in mwc?.applyAlwaysOnTop(pinned) }

        let controller = PanelController(viewModel: vm)
        panelController = controller
        controller.onOpenMainWindow = { [weak mwc] in mwc?.showWindow() }

        PreviewController.shared.registerSources { [weak mwc] in
            [mwc?.currentWindow].compactMap { $0 }
        }
        PreviewController.shared.onPasteText = { [weak vm] text in
            vm?.pasteText(text)
        }
        PreviewController.shared.onPinItem = { [weak vm] item in
            vm?.pin(item)
        }
        PinWindowManager.shared.onPasteText = { [weak vm] text in
            vm?.pasteText(text)
        }

        let mon = ClipboardMonitor(store: store)
        mon.onChange = { [weak vm] newKind in
            guard let vm else { return }
            if vm.tab != newKind {
                vm.tab = newKind
            } else {
                vm.reload()
            }
        }
        monitor = mon
        mon.start()

        vm.onStartSnip = { [weak mon] in
            ScreenshotManager.shared.captureToClipboard {
                mon?.check()
            }
        }

        let hk = HotKeyManager()
        hotkeyManager = hk
        hk.onToggle = { [weak mwc] in mwc?.showWindow() } // Option+V → 打开/前置独立窗口
        hk.onSnip = { [weak mon] in
            ScreenshotManager.shared.captureToClipboard {
                mon?.check()
            }
        }
        hk.onPinClipboard = { [weak vm] in
            Task { @MainActor in
                if ScrollCaptureController.shared.isActive {
                    ScrollCaptureController.shared.finishPin()
                } else if ScreenshotManager.shared.isCapturing {
                    ScreenshotManager.shared.finishAndPinIfCapturing()
                } else {
                    vm?.pinCurrentOrLatest()
                }
            }
        }
        hk.onToggleAllPins = {
            Task { @MainActor in
                PinWindowManager.shared.toggleAllPins()
            }
        }
        if !hk.register() {
            NSLog("MacPaste: Option+V 被占用，仍可通过菜单栏图标使用")
        }

        CmdVMonitor.shared.onUserCmdV = { [weak vm] isInSelfApp in
            Task { @MainActor in
                vm?.handleUserCmdV(isInSelfApp: isInSelfApp)
            }
        }
        CmdVMonitor.shared.start()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.macpaste.command"),
            object: nil,
            queue: .main
        ) { [weak mwc, weak vm, weak mon] note in
            let cmd = note.object as? String ?? "showWindow"
            Task { @MainActor in
                switch cmd {
                case "showWindow": mwc?.showWindow()
                case "snip":
                    ScreenshotManager.shared.captureToClipboard {
                        mon?.check()
                    }
                case "cancelSnip":
                    if ScrollCaptureController.shared.isActive {
                        ScrollCaptureController.shared.stopCleanup()
                    } else {
                        ScreenshotManager.shared.dismissOverlay()
                    }
                case "pin":
                    if ScrollCaptureController.shared.isActive {
                        ScrollCaptureController.shared.finishPin()
                    } else if ScreenshotManager.shared.isCapturing {
                        ScreenshotManager.shared.finishAndPinIfCapturing()
                    } else {
                        vm?.pinCurrentOrLatest()
                    }
                case "togglePins": PinWindowManager.shared.toggleAllPins()
                case "closePins": PinWindowManager.shared.closeAllPins()
                default: mwc?.showWindow()
                }
            }
        }
        NSLog("MacPaste started")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController?.showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}
