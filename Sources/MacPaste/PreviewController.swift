import AppKit
import SwiftUI
import ImageIO

/// 可成为 key window 的无边框面板（预览窗文本选中、搜索框聚焦需要）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 悬停预览：独立的非激活小窗，悬停条目 0.4s 后弹出。
/// 鼠标可以从条目移入预览窗内继续操作（文本可选中复制），同时离开条目与预览窗才消失；
/// 预览窗大小可自由拖拽（右上角锚定），尺寸持久化。
final class PreviewController {
    static let shared = PreviewController()
    static let hoverDelay: TimeInterval = 0.4
    static let itemGrace: TimeInterval = 0.35
    static let previewGrace: TimeInterval = 0.25

    private var panel: KeyablePanel?
    private var workItem: DispatchWorkItem?
    private var graceWork: DispatchWorkItem?
    private var currentItem: ClipboardItem?
    private let imageCache = NSCache<NSString, NSImage>()
    var sourceProvider: (() -> [NSWindow])?
    var onPasteText: ((String) -> Void)?
    var onPinItem: ((ClipboardItem) -> Void)?
    /// 当前预览窗的屏幕区域（供快速面板外点关闭逻辑豁免预览窗内的点击）
    private(set) var previewFrame: CGRect?

    func registerSources(_ provider: @escaping () -> [NSWindow]) {
        sourceProvider = provider
    }

    func cachedImage(at path: String) -> NSImage? {
        if let hit = imageCache.object(forKey: path as NSString) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        imageCache.setObject(img, forKey: path as NSString)
        return img
    }

    /// 预览用解码图：ImageIO 直接解码到 ~1024px 缩放版，避免整图解码卡主线程
    func cachedDetailImage(at path: String, maxPixel: CGFloat = 1024) -> NSImage? {
        let key = "\(path)#\(Int(maxPixel))" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let img: NSImage?
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            img = NSImage(contentsOfFile: path)
        }
        if let img { imageCache.setObject(img, forKey: key) }
        return img
    }

    // MARK: - 调度

    func schedulePreview(for item: ClipboardItem) {
        guard item.kind != .image else { return } // 图片悬停预览已移除（右键「预览」用 QuickLook 查看）
        cancelWork()
        cancelGrace()
        if currentItem?.id == item.id, panel?.isVisible == true { return } // 同一条目已显示
        let work = DispatchWorkItem { [weak self] in self?.show(for: item) }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    /// 鼠标离开条目：给一点时间移入预览窗，超时未进入则隐藏
    func itemMouseExited() {
        cancelWork()
        scheduleGrace(Self.itemGrace)
    }

    func previewMouseEntered() {
        cancelGrace()
        cancelWork()
        panel?.makeKeyAndOrderFront(nil) // 可成为 key，文本可选中复制（nonactivating 不抢应用焦点）
    }

    func previewMouseExited() {
        scheduleGrace(Self.previewGrace)
    }

    func cancelPreview() {
        cancelWork()
        cancelGrace()
        dismiss()
    }

    private func scheduleGrace(_ interval: TimeInterval) {
        cancelGrace()
        let g = DispatchWorkItem { [weak self] in self?.dismiss() }
        graceWork = g
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: g)
    }

    private func cancelGrace() {
        graceWork?.cancel()
        graceWork = nil
    }

    private func cancelWork() {
        workItem?.cancel()
        workItem = nil
    }

    private func dismiss() {
        currentItem = nil
        previewFrame = nil
        panel?.orderOut(nil)
    }

    // MARK: - 显示

    private func show(for item: ClipboardItem) {
        let p = ensurePanel()
        currentItem = item
        let hosting = PreviewHostingView(rootView: PreviewView(
            item: item,
            onResizeStart: { [weak p] in p?.frame.size ?? .zero },
            onResize: { [weak self] base, delta in self?.resize(from: base, delta: delta) },
            onCopyFeedback: nil
        ))
        hosting.onMouseEnter = { [weak self] in self?.previewMouseEntered() }
        hosting.onMouseExit = { [weak self] in self?.previewMouseExited() }
        p.contentView = hosting
        position(panel: p)
        p.orderFrontRegardless()
        previewFrame = p.frame
    }

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let d = UserDefaults.standard
        let w = min(max(d.object(forKey: "previewWidth") as? CGFloat ?? 400, 280), 700)
        let h = min(max(d.object(forKey: "previewHeight") as? CGFloat ?? 300, 120), 700)
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hasShadow = true
        panel = p
        return p
    }

    /// 拖拽调整预览窗大小：右上角锚定（向左/向下扩展），尺寸落盘
    func resize(from base: CGSize, delta: CGSize) {
        guard let panel else { return }
        let w = min(max(base.width + delta.width, 280), 700)
        let h = min(max(base.height + delta.height, 120), 700)
        var f = panel.frame
        let maxX = f.maxX, maxY = f.maxY
        f.size = CGSize(width: w, height: h)
        f.origin = NSPoint(x: maxX - w, y: maxY - h)
        panel.setFrame(f, display: true)
        previewFrame = f
        let d = UserDefaults.standard
        d.set(w, forKey: "previewWidth")
        d.set(h, forKey: "previewHeight")
    }

    private func position(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let sources = (sourceProvider?() ?? []).filter { $0.isVisible }
        guard let source = sources.first(where: { $0.frame.contains(mouse) }) ?? sources.first,
              let screen = source.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        // 优先放源窗口左侧；屏幕贴边则放右侧
        var x = source.frame.minX - size.width - 10
        if x < vf.minX + 4 { x = source.frame.maxX + 10 }
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        let y = min(max(mouse.y - size.height / 2, vf.minY + 4), vf.maxY - size.height - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// 带鼠标进出回调的 Hosting 视图
final class PreviewHostingView: NSHostingView<PreviewView> {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas where ta.owner === self {
            removeTrackingArea(ta)
        }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEnter?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }
}

/// 预览内容（填满可拖拽的预览窗；多段文本自动分段并提供独立复制/粘贴按钮；右上角一键复制全文）
struct PreviewView: View {
    let item: ClipboardItem
    var onResizeStart: () -> CGSize
    var onResize: (CGSize, CGSize) -> Void
    var onCopyFeedback: (() -> Void)?
    @State private var copied = false
    @State private var copiedSegmentIndex: Int?
    @State private var pastedSegmentIndex: Int?
    @State private var showRawText = false

    private var hasMultiParagraphs: Bool { item.paragraphs.count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if hasMultiParagraphs {
                    Button {
                        showRawText.toggle()
                    } label: {
                        Text(showRawText ? "分段视图" : "原文")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showRawText ? "切换为按段落拆分视图" : "切换为完整原文视图")
                }
                Button {
                    PreviewController.shared.onPinItem?(item)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 10))
                        Text("贴图")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("将此内容作为置顶活贴图贴到屏幕上 (F3)")

                Button {
                    copyAll()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        if hasMultiParagraphs {
                            Text(copied ? "已复制全文" : "复制全文")
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(copied ? "已复制" : "复制全部内容")
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .overlay(alignment: .bottom) {
            ResizeHandleView(edge: .bottom, onResizeStart: onResizeStart, onResize: onResize)
        }
        .overlay(alignment: .trailing) {
            ResizeHandleView(edge: .right, onResizeStart: onResizeStart, onResize: onResize)
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeHandleView(edge: .corner, onResizeStart: onResizeStart, onResize: onResize)
        }
        .clipped()
    }

    private var icon: String {
        switch item.kind {
        case .shortText, .longText: return "doc.text"
        case .image: return "photo"
        case .table: return "tablecells"
        }
    }

    private var title: String {
        var parts = [item.kind.tabTitle]
        if hasMultiParagraphs {
            parts.append("共 \(item.paragraphs.count) 段")
        }
        parts.append(relativeTimeShort(item.createdAt))
        if item.kind == .image {
            parts.append(item.content) // 尺寸 · 大小
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .shortText, .longText:
            if hasMultiParagraphs && !showRawText {
                paragraphsListView
            } else {
                rawTextView
            }
        case .image:
            ScrollView([.horizontal, .vertical]) {
                if let p = item.dataPath, let img = PreviewController.shared.cachedDetailImage(at: p, maxPixel: 2048) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
        case .table:
            ScrollView([.horizontal, .vertical]) {
                tableContent
                    .padding(10)
            }
        }
    }

    private var rawTextView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTruncate(item.content, 4000))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.content.count > 4000 {
                    Text("… 内容较长，点击条目复制全部")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
    }

    /// 多段内容自动解析展示：每段带独立「复制」与「粘贴」按钮（需求 3）
    private var paragraphsListView: some View {
        let segments = item.paragraphs
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    let isCopied = copiedSegmentIndex == idx
                    let isPasted = pastedSegmentIndex == idx
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                            .padding(.top, 1)

                        Text(displayTruncate(segment, 1500))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 4) {
                            Button {
                                copySegment(segment)
                                copiedSegmentIndex = idx
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                                    if copiedSegmentIndex == idx { copiedSegmentIndex = nil }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10))
                                    Text(isCopied ? "已复制" : "复制")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isCopied ? Color.green.opacity(0.18) : Color.primary.opacity(0.08))
                                )
                                .foregroundStyle(isCopied ? Color.green : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .help("复制第 \(idx + 1) 段")

                            Button {
                                PreviewController.shared.onPasteText?(segment)
                                pastedSegmentIndex = idx
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                                    if pastedSegmentIndex == idx { pastedSegmentIndex = nil }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: isPasted ? "checkmark" : "arrow.turn.down.left")
                                        .font(.system(size: 9))
                                    Text(isPasted ? "已粘贴" : "粘贴")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isPasted ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.14))
                                )
                                .foregroundStyle(isPasted ? Color.green : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("直接粘贴第 \(idx + 1) 段到目标应用")
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isCopied || isPasted
                                  ? Color.green.opacity(0.08)
                                  : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                    )
                }
            }
            .padding(10)
        }
    }

    private func copySegment(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            ClipboardMonitor.markInternalWrite(text)
        }
    }

    /// 一键复制全部（文本=全文 / 表格=TSV+HTML 结构化 / 图片=原图）
    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        var ok = false
        switch item.kind {
        case .image:
            if let p = item.dataPath, let data = try? Data(contentsOf: URL(fileURLWithPath: p)) {
                ok = pb.setData(data, forType: .png)
            }
        case .table:
            let rows = gridRows()
            ok = pb.setString(TableParser.canonicalTSV(rows), forType: .string)
            if let html = TableParser.htmlTable(rows).data(using: .utf8) {
                pb.setData(html, forType: .html)
            }
        default:
            ok = pb.setString(item.content, forType: .string)
        }
        if ok {
            ClipboardMonitor.markInternalWrite(item.content)
        }
    }

    private func gridRows() -> [[String]] {
        if let json = item.tableJson, let data = json.data(using: .utf8),
           let rows = try? JSONDecoder().decode([[String]].self, from: data), !rows.isEmpty {
            return rows
        }
        return TableParser.parseTSV(item.content) ?? []
    }

    private var tableContent: some View {
        let rows = gridRows()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<rows[r].count, id: \.self) { c in
                        Text(rows[r][c])
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(width: 76, height: 20, alignment: .leading)
                            .padding(.horizontal, 2)
                            .background(Color.primary.opacity(r % 2 == 0 ? 0.04 : 0.015))
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                    }
                }
            }
        }
    }
}
