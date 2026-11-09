import AppKit
import ApplicationServices
import CoreGraphics

/// 辅助功能权限检测（「粘贴」功能需要）
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 未授权时弹系统授权引导，返回当前是否已授权
    @discardableResult
    static func promptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }
}

/// 合成 ⌘V 发给前台应用
enum PasteInjector {
    /// 记录最近一次由 MacPaste 内部合成 ⌘V 的时间，避免被全局 ⌘V 监听器误判为用户手动按键
    private(set) static var lastSyntheticTime: Date = .distantPast

    static func postCmdV() {
        lastSyntheticTime = Date()
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true), // kVK_ANSI_V
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
    }
}

/// 监听用户按下 Command+V（用于「按序粘贴」模式下每次按 ⌘V 后自动推进到下一段）
final class CmdVMonitor {
    static let shared = CmdVMonitor()
    /// 参数 isInSelfApp：true 表示按键发生时焦点在 MacPaste 窗口内，false 表示在外部目标应用中
    var onUserCmdV: ((_ isInSelfApp: Bool) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastTriggerTime: Date = .distantPast

    func start() {
        // 1. 外部应用按键监听（NSEvent 全局监听）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleNSEvent(event, isLocal: false)
        }

        // 2. 本应用窗口内按键监听（若用户点完「按序粘贴」未切窗口直接按 ⌘V，只要不在搜索框输入中即代为触发按序粘贴）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isPlainCmdV(event) {
                // 若当前正在搜索框（NSTextView）里输入，则保留系统默认粘贴行为
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return event
                }
                self.fire(isInSelfApp: true)
                return nil
            }
            return event
        }

        // 3. CGEventTap 兜底监听（需辅助功能权限；若首次未授权则定时尝试挂载）
        setupEventTapIfNeeded()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.setupEventTapIfNeeded()
        }
    }

    private func setupEventTapIfNeeded() {
        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard AccessibilityPermission.isTrusted else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                if type == .keyDown {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags
                    let isCmd = flags.contains(.maskCommand)
                    let hasOtherMods = flags.contains(.maskShift) || flags.contains(.maskAlternate) || flags.contains(.maskControl)
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if keyCode == 0x09 && isCmd && !hasOtherMods && !isRepeat {
                        DispatchQueue.main.async {
                            let front = NSWorkspace.shared.frontmostApplication
                            let isSelf = front?.bundleIdentifier == Bundle.main.bundleIdentifier
                            CmdVMonitor.shared.fire(isInSelfApp: isSelf)
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else { return }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func isPlainCmdV(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 0x09 && flags == .command && !event.isARepeat
    }

    private func handleNSEvent(_ event: NSEvent, isLocal: Bool) {
        guard isPlainCmdV(event) else { return }
        fire(isInSelfApp: isLocal)
    }

    fileprivate func fire(isInSelfApp: Bool) {
        let now = Date()
        // 忽略由 PasteInjector.postCmdV() 合成的 ⌘V
        guard now.timeIntervalSince(PasteInjector.lastSyntheticTime) > 0.30 else { return }
        // 同一物理按键可能同时触发 NSEvent 与 CGEventTap，做 160ms 去重
        guard now.timeIntervalSince(lastTriggerTime) > 0.16 else { return }
        lastTriggerTime = now
        onUserCmdV?(isInSelfApp)
    }
}
