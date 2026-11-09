import AppKit
import Foundation

/// 点击条目的默认行为：复制 / 粘贴（默认复制）
enum ClickAction: String {
    case copy, paste
}

/// UI 层状态：分类/搜索/列表/操作，全部主线程
@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var totalCount: Int = 0
    @Published var tab: ClipboardKind = .shortText { didSet { if oldValue != tab { reload() } } }
    @Published var searchText: String = "" { didSet { if oldValue != searchText { scheduleSearchReload() } } }
    @Published var showClearConfirm = false
    @Published var accessibilityDenied = false
    /// 面板始终置顶：开启后点击面板外不自动收起（对独立窗口同步生效：level = .floating）
    @Published var alwaysOnTop: Bool = UserDefaults.standard.bool(forKey: "alwaysOnTop") {
        didSet {
            guard oldValue != alwaysOnTop else { return }
            UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
            onAlwaysOnTopChanged?(alwaysOnTop)
        }
    }
    var onOpenMainWindow: (() -> Void)?
    var onFocusWindowForKeyboard: (() -> Void)?
    /// 置顶状态变化 → 独立窗口调整 level
    var onAlwaysOnTopChanged: ((Bool) -> Void)?
    /// 请求打开设置弹层（菜单栏右键「设置…」触发）
    @Published var settingsOpenRequest = false

    // MARK: - 按序粘贴状态（需求 2）
    /// 当前开启「按序模式」的条目 ID
    @Published private(set) var activeSequentialItemId: Int64?
    /// 各多段条目的当前待粘段落索引（0-based）
    @Published private(set) var sequentialIndices: [Int64: Int] = [:]
    /// 按序触发时的短暂高亮反馈条目 ID
    @Published private(set) var sequentialFlashItemId: Int64?
    private var activeSequentialItemCache: ClipboardItem?

    /// 面板收起后到合成 ⌘V 的延迟
    static let pasteDelay: TimeInterval = 0.06

    private let store: HistoryStore
    private var pendingPasteWork: DispatchWorkItem?
    private var lastPasteTime: Date = .distantPast

    init(store: HistoryStore) {
        self.store = store
    }

    /// 点击条目的行为设置（UserDefaults 持久化，默认复制）
    var clickAction: ClickAction {
        get { ClickAction(rawValue: UserDefaults.standard.string(forKey: "clickAction") ?? "") ?? .copy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "clickAction") }
    }

    /// reload 合并：同一轮主线程循环内的多次触发只查一次库
    private var reloadPending = false
    private var searchWork: DispatchWorkItem?

    func reload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.performReload()
        }
    }

    /// 搜索输入 120ms 防抖
    private func scheduleSearchReload() {
        searchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func performReload() {
        let kw = searchText.isEmpty ? nil : searchText
        items = store.fetch(kind: tab, search: kw, limit: 1000)
        totalCount = store.count(kind: tab, search: kw)
        if let activeId = activeSequentialItemId,
           let updated = items.first(where: { $0.id == activeId }) {
            activeSequentialItemCache = updated
        }
    }

    /// 点击卡片 → 若该卡片处于「按序模式」，则按序复制/粘贴下一段；否则按设置整条复制/粘贴
    func activate(_ item: ClipboardItem) {
        if isSequential(item), item.paragraphs.count >= 2 {
            activateSequential(item, forcePaste: false)
            return
        }
        switch clickAction {
        case .copy: copy(item)
        case .paste: paste(item)
        }
    }

    // MARK: - 按序粘贴（需求 2）

    func isSequential(_ item: ClipboardItem) -> Bool {
        activeSequentialItemId == item.id
    }

    func sequentialIndex(for item: ClipboardItem) -> Int {
        let count = max(item.paragraphs.count, 1)
        let raw = sequentialIndices[item.id] ?? 0
        return min(max(raw, 0), count - 1)
    }

    func toggleSequential(_ item: ClipboardItem) {
        guard item.paragraphs.count >= 2 else { return }
        if activeSequentialItemId == item.id {
            activeSequentialItemId = nil
            activeSequentialItemCache = nil
            _ = writeBack(item)
        } else {
            activeSequentialItemId = item.id
            activeSequentialItemCache = item
            if sequentialIndices[item.id] == nil {
                sequentialIndices[item.id] = 0
            }
            syncCurrentSequentialSegmentToPasteboard(item)
            // 自动将输入焦点归还给外部目标应用，方便用户直接按 Command+V 粘贴
            NSApp.keyWindow?.resignKey()
            ExternalAppTracker.shared.lastExternal?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func stepSequential(_ item: ClipboardItem, delta: Int) {
        let count = item.paragraphs.count
        guard count >= 2 else { return }
        let cur = sequentialIndex(for: item)
        let next = (cur + (delta % count) + count) % count
        sequentialIndices[item.id] = next
        if activeSequentialItemId == item.id {
            syncCurrentSequentialSegmentToPasteboard(item)
        }
    }

    func resetSequential(_ item: ClipboardItem) {
        sequentialIndices[item.id] = 0
        if activeSequentialItemId == item.id {
            syncCurrentSequentialSegmentToPasteboard(item)
        }
    }

    /// 将当前按序待粘段落预先写入系统剪贴板，使外部应用直接按 ⌘V 即可原生粘贴该段
    private func syncCurrentSequentialSegmentToPasteboard(_ item: ClipboardItem) {
        let segments = item.paragraphs
        guard segments.count >= 2 else { return }
        let idx = sequentialIndex(for: item)
        let text = segments[idx]
        copyText(text)
    }

    /// 监听到用户按下 Command+V 时的处理（需求 2：开启「按序粘贴」后直接按 ⌘V 依次生效）
    func handleUserCmdV(isInSelfApp: Bool) {
        guard let activeId = activeSequentialItemId,
              let item = items.first(where: { $0.id == activeId }) ?? activeSequentialItemCache else { return }
        let segments = item.paragraphs
        guard segments.count >= 2 else { return }

        if isInSelfApp {
            // 若焦点意外留在 MacPaste 窗口，则自动切回外部应用并粘贴当前段、推进下一段
            activateSequential(item, forcePaste: true)
            return
        }

        // 焦点在外部应用：此时系统已将预装好的当前段（idx）通过原生 ⌘V 粘贴进目标应用
        let idx = sequentialIndex(for: item)
        let nextIdx = (idx + 1) % segments.count
        sequentialFlashItemId = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            if self?.sequentialFlashItemId == item.id {
                self?.sequentialFlashItemId = nil
            }
        }
        // 延迟 100ms 等外部应用读完当前剪贴板后，自动推进索引并将下一段预装入系统剪贴板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self, self.activeSequentialItemId == item.id else { return }
            self.sequentialIndices[item.id] = nextIdx
            self.syncCurrentSequentialSegmentToPasteboard(item)
        }
    }

    /// 执行一次按序操作（点击卡片或按 ⌥⇧V 时：粘贴/复制当前段，并自动推进预装下一段）
    func activateSequential(_ item: ClipboardItem, forcePaste: Bool) {
        let segments = item.paragraphs
        guard segments.count >= 2 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPasteTime) >= 0.25 else { return }
        lastPasteTime = now

        let idx = sequentialIndex(for: item)
        let text = segments[idx]
        let nextIdx = (idx + 1) % segments.count
        sequentialIndices[item.id] = nextIdx
        activeSequentialItemId = item.id
        activeSequentialItemCache = item

        sequentialFlashItemId = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            if self?.sequentialFlashItemId == item.id {
                self?.sequentialFlashItemId = nil
            }
        }

        if forcePaste || clickAction == .paste {
            pasteText(text, bypassDebounce: true)
            // 粘贴完成后，将下一段预装进剪贴板，保证后续直接按 ⌘V 也能无缝衔接
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self, self.activeSequentialItemId == item.id else { return }
                self.syncCurrentSequentialSegmentToPasteboard(item)
            }
        } else {
            copyText(text)
        }
    }

    /// 全局快捷键 Option+Shift+V 触发：粘贴当前按序条目的下一段（若未指定则自动选用最新多段文本条目）
    func pasteNextSequentialFromHotKey() {
        if let activeId = activeSequentialItemId {
            if let item = items.first(where: { $0.id == activeId }) ?? activeSequentialItemCache {
                activateSequential(item, forcePaste: true)
                return
            }
        }
        // 未手动开启时，自动查找当前列表或最近的多段文本条目
        if let candidate = items.first(where: { $0.paragraphs.count >= 2 })
            ?? store.fetch(kind: .shortText, search: nil, limit: 30).first(where: { $0.paragraphs.count >= 2 })
            ?? store.fetch(kind: .longText, search: nil, limit: 30).first(where: { $0.paragraphs.count >= 2 }) {
            if sequentialIndices[candidate.id] == nil {
                sequentialIndices[candidate.id] = 0
            }
            activateSequential(candidate, forcePaste: true)
        }
    }

    // MARK: - 剪贴板写入与粘贴

    @discardableResult
    private func writeBack(_ item: ClipboardItem) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok: Bool
        switch item.kind {
        case .image:
            guard let p = item.dataPath, let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return false }
            ok = pb.setData(data, forType: .png)
        case .table:
            let rows = grid(for: item)
            guard !rows.isEmpty else { return false }
            // 双表示：TSV（Excel/Sheets/飞书表格按行列粘贴）+ HTML（富文本应用保持表格结构）
            let okStr = pb.setString(TableParser.canonicalTSV(rows), forType: .string)
            if let html = TableParser.htmlTable(rows).data(using: .utf8) {
                pb.setData(html, forType: .html)
            }
            ok = okStr
        default:
            ok = pb.setString(item.content, forType: .string)
        }
        if ok {
            ClipboardMonitor.markInternalWrite(item.content)
        }
        return ok
    }

    /// 复制：写回剪贴板
    func copy(_ item: ClipboardItem) {
        _ = writeBack(item)
    }

    /// 粘贴整条：写回剪贴板 → 确保外部目标应用处于激活状态 → 合成 ⌘V（带防连击保护）
    func paste(_ item: ClipboardItem) {
        performPaste(bypassDebounce: false) {
            writeBack(item)
        }
    }

    /// 直接粘贴指定文本（用于按序粘贴、预览分段粘贴）
    func pasteText(_ text: String, bypassDebounce: Bool = false) {
        performPaste(bypassDebounce: bypassDebounce) {
            let pb = NSPasteboard.general
            pb.clearContents()
            let ok = pb.setString(text, forType: .string)
            if ok { ClipboardMonitor.markInternalWrite(text) }
            return ok
        }
    }

    private func performPaste(bypassDebounce: Bool, writeBlock: () -> Bool) {
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.promptIfNeeded()
            accessibilityDenied = true
            return
        }
        accessibilityDenied = false
        let now = Date()
        if !bypassDebounce {
            guard now.timeIntervalSince(lastPasteTime) >= 0.25 else { return }
            lastPasteTime = now
        }
        pendingPasteWork?.cancel()
        guard writeBlock() else { return }

        NSApp.keyWindow?.resignKey()

        let target = ExternalAppTracker.shared.lastExternal
        let front = NSWorkspace.shared.frontmostApplication
        let isSelfFront = (front?.bundleIdentifier == Bundle.main.bundleIdentifier) || NSApp.isActive

        if isSelfFront {
            if let target {
                target.activate(options: [.activateIgnoringOtherApps])
                waitAndPostCmdV(target: target, attemptsLeft: 16)
            } else {
                NSApp.hide(nil)
                schedulePostCmdV(after: 0.25)
            }
        } else if let target, !target.isActive {
            target.activate(options: [.activateIgnoringOtherApps])
            waitAndPostCmdV(target: target, attemptsLeft: 16)
        } else {
            schedulePostCmdV(after: Self.pasteDelay)
        }
    }

    private func waitAndPostCmdV(target: NSRunningApplication, attemptsLeft: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if (target.isActive && frontPid == target.processIdentifier && !NSApp.isActive) || attemptsLeft <= 0 {
                self.schedulePostCmdV(after: 0.05)
            } else {
                self.waitAndPostCmdV(target: target, attemptsLeft: attemptsLeft - 1)
            }
        }
        pendingPasteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }

    private func schedulePostCmdV(after delay: TimeInterval) {
        let work = DispatchWorkItem {
            PasteInjector.postCmdV()
        }
        pendingPasteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func togglePin(_ item: ClipboardItem) {
        store.setPinned(id: item.id, pinned: !item.pinned)
        reload()
    }

    func delete(_ item: ClipboardItem) {
        if activeSequentialItemId == item.id {
            activeSequentialItemId = nil
            activeSequentialItemCache = nil
        }
        sequentialIndices.removeValue(forKey: item.id)
        store.delete(id: item.id)
        reload()
    }

    func clearAll() {
        // 默认保留置顶内容；设置里开启「同时清除置顶内容」后才会全部清空
        let includePinned = UserDefaults.standard.bool(forKey: "clearIncludesPinned")
        store.clearAll(keepPinned: !includePinned)
        activeSequentialItemId = nil
        activeSequentialItemCache = nil
        sequentialIndices.removeAll()
        reload()
    }

    // MARK: - 表格操作

    func grid(for item: ClipboardItem) -> [[String]] {
        if let json = item.tableJson, let data = json.data(using: .utf8),
           let rows = try? JSONDecoder().decode([[String]].self, from: data), !rows.isEmpty {
            return rows
        }
        return TableParser.parseTSV(item.content) ?? [[item.content]]
    }

    /// 复制单元格/行/列/区域/分段：仅写剪贴板，不收面板，且标记为内部写入不生成新历史条目
    func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            ClipboardMonitor.markInternalWrite(text)
        }
    }

    func copyCell(_ item: ClipboardItem, row: Int, col: Int) {
        let g = grid(for: item)
        guard row < g.count, col < g[row].count else { return }
        copyText(g[row][col])
    }

    func copyRow(_ item: ClipboardItem, row: Int) {
        let g = grid(for: item)
        guard row < g.count else { return }
        copyText(g[row].joined(separator: "\t"))
    }

    func copyColumn(_ item: ClipboardItem, col: Int) {
        let g = grid(for: item)
        let values = g.compactMap { col < $0.count ? $0[col] : nil }
        copyText(values.joined(separator: "\n"))
    }

    func copyRegion(_ item: ClipboardItem, rows: ClosedRange<Int>, cols: ClosedRange<Int>) {
        let g = grid(for: item)
        guard rows.lowerBound >= 0, cols.lowerBound >= 0 else { return }
        let sub = g.enumerated()
            .filter { rows.contains($0.offset) }
            .map { row -> [String] in
                row.element.enumerated()
                    .filter { cols.contains($0.offset) }
                    .map { $0.element }
            }
        guard !sub.isEmpty else { return }
        copyText(TableParser.canonicalTSV(sub))
    }

    var historyLimit: Int {
        get { UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 500 }
        set { UserDefaults.standard.set(newValue, forKey: "historyLimit") }
    }

    // MARK: - 截图与贴图（F1 / F3 / Shift+F3）

    var onStartSnip: (() -> Void)?

    /// 将指定条目作为可交互贴图贴到屏幕上
    func pin(_ item: ClipboardItem) {
        PreviewController.shared.cancelPreview()
        PinWindowManager.shared.pin(item: item)
    }

    /// F3 触发：把当前剪贴板内容（或列表第一条）贴到屏幕上
    func pinCurrentOrLatest() {
        PreviewController.shared.cancelPreview()
        PinWindowManager.shared.pinCurrentPasteboard(fallbackItem: items.first)
    }
}
