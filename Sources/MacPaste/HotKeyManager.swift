import Carbon.HIToolbox
import Foundation

/// 全局热键（与 Snipaste 快捷键对齐）：
/// - Option+V (id=1)：唤起/前置主窗口
/// - F1 (id=2)：区域截图到剪贴板
/// - F3 (id=3)：将当前剪贴板内容（图片/文字/表格）贴到屏幕上
/// - Shift+F3 (id=4)：隐藏/显示所有屏幕贴图
final class HotKeyManager {
    static var shared: HotKeyManager?
    var onToggle: (() -> Void)?
    var onSnip: (() -> Void)?
    var onPinClipboard: (() -> Void)?
    var onToggleAllPins: (() -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var retryTimer: Timer?

    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_V), modifiers: UInt32 = UInt32(optionKey)) -> Bool {
        Self.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if err == noErr {
                HotKeyManager.shared?.fire(id: hkID.id)
            } else {
                HotKeyManager.shared?.fire(id: 1)
            }
            return noErr
        }, 1, &spec, nil, nil)

        tryRegisterAll(keyCode: keyCode, modifiers: modifiers)
        // 若启动时 Snipaste 尚未退出导致 F1/F3 暂时被占用，后台自动重试挂载，退出 Snipaste 后无需重启 MacPaste 即可生效
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.tryRegisterAll(keyCode: keyCode, modifiers: modifiers)
            if self.hotKeyRefs.count >= 4 {
                t.invalidate()
                self.retryTimer = nil
            }
        }
        return hotKeyRefs[1] != nil
    }

    private func tryRegisterAll(keyCode: UInt32, modifiers: UInt32) {
        if hotKeyRefs[1] == nil { _ = registerOne(id: 1, keyCode: keyCode, modifiers: modifiers, label: "Option+V") }
        if hotKeyRefs[2] == nil { _ = registerOne(id: 2, keyCode: UInt32(kVK_F1), modifiers: 0, label: "F1(截图)") }
        if hotKeyRefs[3] == nil { _ = registerOne(id: 3, keyCode: UInt32(kVK_F3), modifiers: 0, label: "F3(贴图)") }
        if hotKeyRefs[4] == nil { _ = registerOne(id: 4, keyCode: UInt32(kVK_F3), modifiers: UInt32(shiftKey), label: "Shift+F3(显隐贴图)") }
    }

    @discardableResult
    private func registerOne(id: UInt32, keyCode: UInt32, modifiers: UInt32, label: String) -> Bool {
        let hkID = EventHotKeyID(signature: OSType(0x4D507374), id: id) // 'MPst'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            return true
        } else {
            return false
        }
    }

    private func fire(id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            switch id {
            case 2: self?.onSnip?()
            case 3: self?.onPinClipboard?()
            case 4: self?.onToggleAllPins?()
            default: self?.onToggle?()
            }
        }
    }
}
