import AppKit
import Combine
import SwiftUI
import VisionKit

// MARK: - 实况文本图片视图（支持在贴图图片上直接用鼠标划词选中复制）

@MainActor
final class LiveTextContainerView: NSView {
    let imageView = NSImageView()
    let overlayView = ImageAnalysisOverlayView()
    private static let analyzer = ImageAnalyzer()
    private var analyzedImage: NSImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        overlayView.trackingImageView = imageView
        overlayView.preferredInteractionTypes = .automatic
        addSubview(overlayView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(with image: NSImage) {
        guard analyzedImage !== image else { return }
        analyzedImage = image
        imageView.image = image
        guard ImageAnalyzer.isSupported else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let config = ImageAnalyzer.Configuration([.text])
            if let analysis = try? await Self.analyzer.analyze(image, orientation: .up, configuration: config) {
                self.overlayView.analysis = analysis
            }
        }
    }
}

struct LiveTextImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> LiveTextContainerView {
        let v = LiveTextContainerView(frame: .zero)
        v.configure(with: image)
        return v
    }

    func updateNSView(_ nsView: LiveTextContainerView, context: Context) {
        nsView.configure(with: image)
    }
}

// MARK: - 单个贴图的状态模型

@MainActor
final class PinItemState: ObservableObject {
    let id = UUID()
    let kind: ClipboardKind
    @Published var textContent: String {
        didSet {
            if kind == .shortText || kind == .longText {
                paragraphs = parseParagraphs(textContent)
            }
        }
    }
    @Published var paragraphs: [String]
    @Published var checkedIndices: Set<Int> = []
    let image: NSImage?
    let imageSizeText: String
    let tableRows: [[String]]

    /// 图片 OCR 提取出的分段文本
    @Published var ocrLines: [String] = []
    @Published var isPerformingOCR: Bool = false
    @Published var showOCRList: Bool = false

    /// 翻译状态与结果
    @Published var sourceTextForTranslation: String = ""
    @Published var translatedText: String = ""
    @Published var detectedSourceName: String = "自动检测"
    @Published var selectedTargetLanguage: TranslationService.TargetLanguage = TranslationService.commonTargetLanguages[0]
    @Published var isTranslating: Bool = false
    @Published var showTranslation: Bool = false
    @Published var translationErrorMessage: String? = nil

    /// 文本贴图模式切换：分段清单 / 原始文本 / 便签编辑
    @Published var showSegments: Bool = false
    @Published var isEditingText: Bool = false

    /// 窗口透明度（0.15 ~ 1.0）、缩放比例（0.65 ~ 2.5）、折叠状态与外部悬停工具栏状态
    @Published var opacity: Double = 1.0
    @Published var contentScale: CGFloat = 1.0
    @Published var isCollapsed: Bool = false
    @Published var isHovered: Bool = false
    @Published var toolbarPlacedBelow: Bool = false

    init(kind: ClipboardKind, textContent: String, image: NSImage? = nil, imageSizeText: String = "", tableRows: [[String]] = []) {
        self.kind = kind
        self.textContent = textContent
        self.paragraphs = (kind == .shortText || kind == .longText) ? parseParagraphs(textContent) : []
        self.image = image
        self.imageSizeText = imageSizeText
        self.tableRows = tableRows
    }

    func copyAllToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if showTranslation && !translatedText.isEmpty {
            if pb.setString(translatedText, forType: .string) {
                ClipboardMonitor.markInternalWrite(translatedText)
            }
            return
        }
        switch kind {
        case .image:
            if showOCRList, !ocrLines.isEmpty {
                let joined = ocrLines.joined(separator: "\n")
                if pb.setString(joined, forType: .string) {
                    ClipboardMonitor.markInternalWrite(joined)
                }
            } else if let img = image,
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                if pb.setData(png, forType: .png) {
                    ClipboardMonitor.markInternalWrite()
                }
            }
        case .table:
            let tsv = TableParser.canonicalTSV(tableRows)
            if pb.setString(tsv, forType: .string) {
                if let html = TableParser.htmlTable(tableRows).data(using: .utf8) {
                    pb.setData(html, forType: .html)
                }
                ClipboardMonitor.markInternalWrite(tsv)
            }
        default:
            if pb.setString(textContent, forType: .string) {
                ClipboardMonitor.markInternalWrite(textContent)
            }
        }
    }
}

// MARK: - 贴图浮动面板（支持任意位置拖拽移动、⌘+滚轮调透明度、⌥/普通滚轮缩放、Esc 关闭）

@MainActor
final class PinPanel: NSPanel {
    weak var pinState: PinItemState?
    var onScrollOpacity: ((CGFloat) -> Void)?
    var onScrollScale: ((CGFloat) -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onWindowMoved: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    var isImagePin: Bool = false
    var isShowingScrollableContent: Bool = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            let dy = event.scrollingDeltaY
            if abs(dy) > 0.01 {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // Command + 滚轮：无级调节贴图透明度（优先拦截，避免被大段文本的 NSScrollView 吞掉）
                if flags.contains(.command) {
                    let step = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.03)
                    onScrollOpacity?(step)
                    return
                }
                // Option + 滚轮：等比缩放贴图窗口与文字字号（适用于图片与大段文字）
                if flags.contains(.option) {
                    let factor = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.04)
                    onScrollScale?(factor)
                    return
                }
                // 无修饰键直接滚轮：纯图片贴图直接缩放；文本/列表仅在无纵向滚动溢出时直接缩放
                if isPureImageMode || !activeScrollViewHasOverflow(at: event.locationInWindow) {
                    let factor = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.04)
                    onScrollScale?(factor)
                    return
                }
            }
            super.sendEvent(event)
            return
        }

        if event.type == .magnify {
            if abs(event.magnification) > 0.001 {
                onScrollScale?(event.magnification)
                return
            }
        }

        if event.type == .leftMouseDown {
            let loc = event.locationInWindow
            let collapsed = pinState?.isCollapsed ?? false
            let inResizeZone = !collapsed && ((loc.x >= frame.width - 8) || (loc.y <= 8) || (loc.x >= frame.width - 14 && loc.y <= 14))
            let isOptionDown = event.modifierFlags.contains(.option)

            // 折叠态胶囊：双击标题区展开（避开右侧折叠/关闭按钮）
            if collapsed && event.clickCount == 2 && loc.x < frame.width - 56 {
                onToggleCollapse?()
                return
            }

            let isEditingOrScrollingControl: Bool = {
                if (pinState?.isEditingText ?? false) && !event.modifierFlags.contains(.command) {
                    return true
                }
                var v = contentView?.hitTest(loc)
                while let cur = v {
                    if cur is NSScroller { return true }
                    if let tv = cur as? NSTextView, tv.isEditable { return true }
                    v = cur.superview
                }
                return false
            }()

            // 默认任意内容位置拖拽即可移动贴图；按住 ⌥ 拖拽可临时划词选择
            let allowDragWindow = !inResizeZone && !isOptionDown && !isEditingOrScrollingControl

            if allowDragWindow {
                let startMouse = NSEvent.mouseLocation
                let startOrigin = frame.origin
                var didStartDrag = false

                // 区分「轻点/双击（透传给子视图按钮与菜单）」与「拖拽（移动整个贴图窗口）」
                while let next = nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                ) {
                    if next.type == .leftMouseDragged {
                        let cur = NSEvent.mouseLocation
                        let dx = cur.x - startMouse.x
                        let dy = cur.y - startMouse.y
                        if !didStartDrag && hypot(dx, dy) >= 4.0 {
                            didStartDrag = true
                            NSCursor.closedHand.push()
                        }
                        if didStartDrag {
                            setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
                            onWindowMoved?()
                        }
                    } else if next.type == .leftMouseUp {
                        if didStartDrag {
                            NSCursor.pop()
                            onWindowMoved?()
                        } else {
                            // 未触发拖拽：按正常点击顺序转发给内部视图 / 按钮 / 菜单
                            super.sendEvent(event)
                            super.sendEvent(next)
                        }
                        break
                    }
                }
                return
            }
        }
        super.sendEvent(event)
    }

    private var isPureImageMode: Bool {
        guard let s = pinState else { return isImagePin && !isShowingScrollableContent }
        return s.kind == .image && !s.showOCRList && !s.showTranslation
    }

    private func activeScrollViewHasOverflow(at windowPoint: NSPoint) -> Bool {
        var view = contentView?.hitTest(windowPoint)
        while let v = view {
            if let sv = v as? NSScrollView, let doc = sv.documentView {
                return doc.bounds.height > sv.contentView.bounds.height + 2
            }
            view = v.superview
        }
        return false
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            let step = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.03)
            onScrollOpacity?(step)
            return
        }
        if flags.contains(.option) || isPureImageMode {
            let factor = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.04)
            onScrollScale?(factor)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Esc (53) 或 Command+W (13) 关闭当前贴图
        if event.keyCode == 53 || (event.keyCode == 13 && flags == .command) {
            onCloseRequest?()
            return
        }
        // Command + '+'(24) / '-'(27) / '0'(29) 缩放或重置贴图
        if flags.contains(.command) {
            if event.keyCode == 24 { onScrollScale?(0.1); return }
            if event.keyCode == 27 { onScrollScale?(-0.1); return }
            if event.keyCode == 29 { onScrollScale?(0); return }
        }
        super.keyDown(with: event)
    }
}

// MARK: - 贴图外置悬浮工具栏面板（置于贴图外上方或下方，自动避让屏幕边缘）

@MainActor
final class PinToolbarPanel: NSPanel {
    var onScrollOpacity: ((CGFloat) -> Void)?
    var onScrollScale: ((CGFloat) -> Void)?
    var onCloseRequest: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            let step = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.03)
            onScrollOpacity?(step)
            return
        }
        if flags.contains(.option) {
            let factor = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.04)
            onScrollScale?(factor)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 || (event.keyCode == 13 && flags == .command) {
            onCloseRequest?()
            return
        }
        super.keyDown(with: event)
    }
}

/// 即使主应用未激活，也能实时感知鼠标移入/移出的 HostingView
@MainActor
final class PinHoverHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

// MARK: - 单个贴图窗口控制器

@MainActor
final class PinWindowController: NSObject {
    let state: PinItemState
    private(set) var panel: PinPanel?
    private var toolbarPanel: PinToolbarPanel?
    private var toolbarHostingView: PinHoverHostingView<PinToolbarView>?
    private var expandedSize: CGSize
    private var isHoveringPin = false
    private var isHoveringToolbar = false
    private var isToolbarShown = false
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    var onClose: ((UUID) -> Void)?

    init(state: PinItemState, initialSize: CGSize) {
        self.state = state
        self.expandedSize = initialSize
        super.init()
        setupPanel(initialSize: initialSize)
        setupToolbarPanel()
        observeStateForToolbar()
    }

    private func observeStateForToolbar() {
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateToolbarVisibility()
                    if self.isToolbarShown {
                        self.layoutToolbar()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func setupPanel(initialSize: CGSize) {
        let p = PinPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.pinState = state
        p.isImagePin = (state.kind == .image)

        p.onScrollOpacity = { [weak self] delta in
            guard let self else { return }
            self.setOpacity(self.state.opacity + Double(delta))
        }
        p.onScrollScale = { [weak self] factor in
            guard let self, !self.state.isCollapsed else { return }
            if factor == 0 {
                self.resetScale()
            } else {
                self.scaleBy(1.0 + factor)
            }
        }
        p.onToggleCollapse = { [weak self] in
            self?.toggleCollapse()
        }
        p.onWindowMoved = { [weak self] in
            guard let self, self.isToolbarShown else { return }
            self.layoutToolbar()
        }
        p.onCloseRequest = { [weak self] in
            self?.close()
        }

        let rootView = PinContentView(
            state: state,
            onToggleCollapse: { [weak self] in self?.toggleCollapse() },
            onScaleAdjust: { [weak self] factor in
                guard let self else { return }
                if factor == 0 { self.resetScale() } else { self.scaleBy(1.0 + factor) }
            },
            onTriggerTranslate: { [weak self] in self?.triggerTranslate() },
            onChangeTargetLanguage: { [weak self] lang in self?.triggerTranslate(targetCode: lang.code) },
            onResizeStart: { [weak p] in p?.frame.size ?? initialSize },
            onResize: { [weak self] base, delta in self?.resize(from: base, delta: delta) },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = PinHoverHostingView(rootView: rootView)
        hosting.onHoverChange = { [weak self] inside in
            guard let self else { return }
            self.isHoveringPin = inside
            self.handleHoverStateChanged(entered: inside)
        }
        p.contentView = hosting
        self.panel = p
    }

    private func setupToolbarPanel() {
        let toolbarView = PinToolbarView(
            state: state,
            onToggleCollapse: { [weak self] in self?.toggleCollapse() },
            onTriggerOCR: { [weak self] in self?.triggerOCR() },
            onTriggerTranslate: { [weak self] in self?.triggerTranslate() },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = PinHoverHostingView(rootView: toolbarView)
        hosting.onHoverChange = { [weak self] inside in
            guard let self else { return }
            self.isHoveringToolbar = inside
            self.handleHoverStateChanged(entered: inside)
        }
        let fit = hosting.fittingSize
        let tp = PinToolbarPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: max(fit.width, 180), height: max(fit.height, 40))),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tp.isOpaque = false
        tp.backgroundColor = .clear
        tp.hasShadow = false // 阴影由 SwiftUI 胶囊自身绘制，避免矩形窗口阴影边角
        tp.hidesOnDeactivate = false
        tp.isFloatingPanel = true
        tp.level = .floating
        tp.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tp.isMovableByWindowBackground = false
        tp.onScrollOpacity = { [weak self] delta in
            guard let self else { return }
            self.setOpacity(self.state.opacity + Double(delta))
        }
        tp.onScrollScale = { [weak self] factor in
            guard let self, !self.state.isCollapsed else { return }
            if factor == 0 { self.resetScale() } else { self.scaleBy(1.0 + factor) }
        }
        tp.onCloseRequest = { [weak self] in
            self?.close()
        }
        tp.contentView = hosting
        self.toolbarHostingView = hosting
        self.toolbarPanel = tp
    }

    private var shouldKeepToolbarVisible: Bool {
        guard !state.isCollapsed else { return false }
        return isHoveringPin
            || isHoveringToolbar
            || state.isEditingText
            || state.isPerformingOCR
            || state.isTranslating
    }

    private func handleHoverStateChanged(entered: Bool) {
        if entered {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            updateToolbarVisibility()
        } else {
            scheduleHideCheck()
        }
    }

    private func scheduleHideCheck() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if let p = self.panel, p.frame.insetBy(dx: -2, dy: -2).contains(mouse) {
                self.isHoveringPin = true
            } else {
                self.isHoveringPin = false
            }
            if let tp = self.toolbarPanel, self.isToolbarShown, tp.frame.insetBy(dx: -2, dy: -2).contains(mouse) {
                self.isHoveringToolbar = true
            } else {
                self.isHoveringToolbar = false
            }
            self.updateToolbarVisibility()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: item)
    }

    private func updateToolbarVisibility() {
        if shouldKeepToolbarVisible {
            showToolbar()
        } else {
            hideToolbar()
        }
    }

    private func showToolbar() {
        guard let panel, let toolbarPanel, !state.isCollapsed else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        state.isHovered = true
        layoutToolbar()

        if !isToolbarShown {
            isToolbarShown = true
            if toolbarPanel.parent !== panel {
                panel.addChildWindow(toolbarPanel, ordered: .above)
            }
            toolbarPanel.ignoresMouseEvents = false
            toolbarPanel.alphaValue = 0
            toolbarPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                toolbarPanel.animator().alphaValue = 1.0
            }
        }
    }

    private func hideToolbar() {
        state.isHovered = false
        guard isToolbarShown, let toolbarPanel else { return }
        isToolbarShown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            toolbarPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isToolbarShown else { return }
                self.detachToolbarWindow()
            }
        })
    }

    func hideToolbarImmediate() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isHoveringPin = false
        isHoveringToolbar = false
        isToolbarShown = false
        state.isHovered = false
        detachToolbarWindow()
    }

    private func detachToolbarWindow() {
        guard let toolbarPanel else { return }
        toolbarPanel.ignoresMouseEvents = true
        if let panel, toolbarPanel.parent === panel {
            panel.removeChildWindow(toolbarPanel)
        }
        toolbarPanel.orderOut(nil)
    }

    private func layoutToolbar() {
        guard let panel, let toolbarPanel, let toolbarHostingView else { return }
        let pinFrame = panel.frame
        toolbarHostingView.layoutSubtreeIfNeeded()
        let fit = toolbarHostingView.fittingSize
        let totalW = max(ceil(fit.width), 160)
        let totalH = max(ceil(fit.height), 40)

        // PinToolbarView 四周带有透明阴影留白（上下 6pt、左右 8pt）
        let padH: CGFloat = 8
        let padV: CGFloat = 6
        let gap: CGFloat = 6
        let visibleCapsuleH = max(totalH - padV * 2, 26)
        let visibleCapsuleW = max(totalW - padH * 2, 120)

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(pinFrame) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let neededSpace = gap + visibleCapsuleH + 4
        let spaceAbove = vf.maxY - pinFrame.maxY
        let spaceBelow = pinFrame.minY - vf.minY

        // 上方空间充足则显示在贴图上方；靠近屏幕顶部（菜单栏附近）时自动改到贴图下方
        let placeBelow: Bool
        if spaceAbove >= neededSpace {
            placeBelow = false
        } else if spaceBelow >= neededSpace {
            placeBelow = true
        } else {
            placeBelow = spaceBelow > spaceAbove
        }

        if state.toolbarPlacedBelow != placeBelow {
            state.toolbarPlacedBelow = placeBelow
        }

        var y: CGFloat
        if placeBelow {
            // 工具栏顶部与贴图底边保持 6pt 视觉间距（透明边距刚好衔接，无鼠标断层）
            y = pinFrame.minY - totalH
            let minAllowedY = vf.minY + 2 - padV
            if y < minAllowedY { y = minAllowedY }
        } else {
            // 工具栏底部与贴图顶边保持 6pt 视觉间距
            y = pinFrame.maxY
            let maxAllowedY = vf.maxY - 2 - (totalH - padV)
            if y > maxAllowedY { y = maxAllowedY }
        }

        // 水平优先右对齐贴图右侧，超出屏幕左/右边缘时自动钳制在可见区内
        var x = pinFrame.maxX - (visibleCapsuleW + padH)
        let minAllowedX = vf.minX + 6 - padH
        let maxAllowedX = vf.maxX - 6 - (visibleCapsuleW + padH)
        if maxAllowedX >= minAllowedX {
            x = min(max(x, minAllowedX), maxAllowedX)
        }

        toolbarPanel.setFrame(NSRect(x: round(x), y: round(y), width: totalW, height: totalH), display: true)
    }

    func show(near point: NSPoint, exactOrigin: NSPoint? = nil) {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var x: CGFloat
        var y: CGFloat
        if let exactOrigin {
            x = exactOrigin.x
            y = exactOrigin.y
        } else {
            x = point.x - size.width / 2
            y = point.y - size.height / 2
        }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            panel.animator().alphaValue = CGFloat(state.opacity)
        }
    }

    func setOpacity(_ value: Double) {
        let clamped = min(max(value, 0.15), 1.0)
        state.opacity = clamped
        panel?.alphaValue = CGFloat(clamped)
    }

    func toggleCollapse() {
        guard let panel else { return }
        let f = panel.frame
        if state.isCollapsed {
            state.isCollapsed = false
            let newOrigin = NSPoint(x: f.minX, y: f.maxY - expandedSize.height)
            panel.setFrame(NSRect(origin: newOrigin, size: expandedSize), display: true, animate: true)
        } else {
            hideToolbarImmediate()
            expandedSize = f.size
            state.isCollapsed = true
            let collapsedSize = CGSize(width: min(max(f.width, 220), 320), height: 34)
            let newOrigin = NSPoint(x: f.minX, y: f.maxY - collapsedSize.height)
            panel.setFrame(NSRect(origin: newOrigin, size: collapsedSize), display: true, animate: true)
        }
    }

    func resize(from base: CGSize, delta: CGSize) {
        guard let panel, !state.isCollapsed else { return }
        let w = min(max(base.width + delta.width, 220), 1200)
        let h = min(max(base.height + delta.height, 110), 1000)
        var f = panel.frame
        let topY = f.maxY
        f.size = CGSize(width: w, height: h)
        f.origin.y = topY - h
        panel.setFrame(f, display: true)
        expandedSize = f.size
        if isToolbarShown { layoutToolbar() }
    }

    func scaleBy(_ ratio: CGFloat) {
        guard let panel, !state.isCollapsed else { return }
        let clampedRatio = min(max(ratio, 0.85), 1.18)
        let f = panel.frame
        let w = min(max(f.width * clampedRatio, 180), 1200)
        let h = min(max(f.height * clampedRatio, 100), 1000)
        let newOrigin = NSPoint(x: f.midX - w / 2, y: f.midY - h / 2)
        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: w, height: h))
        panel.setFrame(newFrame, display: true)
        expandedSize = newFrame.size
        if isToolbarShown { layoutToolbar() }

        // 非纯图片模式同步缩放文字/排版字号
        if state.kind != .image || state.showOCRList || state.showTranslation {
            state.contentScale = min(max(state.contentScale * clampedRatio, 0.65), 2.5)
        }
    }

    func resetScale() {
        guard let panel, !state.isCollapsed else { return }
        let oldScale = max(state.contentScale, 0.01)
        let ratio = 1.0 / oldScale
        state.contentScale = 1.0
        let f = panel.frame
        let w = min(max(f.width * ratio, 200), 1200)
        let h = min(max(f.height * ratio, 110), 1000)
        let newOrigin = NSPoint(x: f.midX - w / 2, y: f.midY - h / 2)
        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: w, height: h))
        panel.setFrame(newFrame, display: true)
        expandedSize = newFrame.size
        if isToolbarShown { layoutToolbar() }
    }

    func triggerOCR() {
        guard state.kind == .image, let img = state.image else { return }
        if !state.ocrLines.isEmpty {
            state.showOCRList.toggle()
            panel?.isShowingScrollableContent = state.showOCRList
            return
        }
        state.isPerformingOCR = true
        ScreenshotManager.recognizeLines(from: img) { [weak self] lines in
            guard let self else { return }
            self.state.isPerformingOCR = false
            self.state.ocrLines = lines.isEmpty ? ["（未识别到文本）"] : lines
            self.state.showOCRList = true
            self.panel?.isShowingScrollableContent = true
        }
    }

    func triggerTranslate(targetCode: String? = nil) {
        if state.showTranslation && targetCode == nil {
            state.showTranslation = false
            panel?.isShowingScrollableContent = state.showOCRList
            return
        }

        state.showTranslation = true
        state.showOCRList = false
        panel?.isShowingScrollableContent = true

        // 适当扩展窗口尺寸以舒适显示双语对照卡片
        if let panel {
            let f = panel.frame
            var w = f.width
            var h = f.height
            var changed = false
            if w < 380 {
                w = 380
                changed = true
            }
            if h < 240 {
                h = 240
                changed = true
            }
            if changed {
                let newOrigin = NSPoint(x: f.minX, y: f.maxY - h)
                panel.setFrame(NSRect(origin: newOrigin, size: CGSize(width: w, height: h)), display: true, animate: true)
                expandedSize = CGSize(width: w, height: h)
                if isToolbarShown { layoutToolbar() }
            }
        }

        let executeWithText: (String) -> Void = { [weak self] rawText in
            guard let self else { return }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.state.translationErrorMessage = "未识别到可翻译文本"
                self.state.isTranslating = false
                return
            }

            self.state.sourceTextForTranslation = text
            let (code, name) = TranslationService.shared.detectLanguage(for: text)
            self.state.detectedSourceName = name

            let target: TranslationService.TargetLanguage
            if let targetCode {
                target = TranslationService.commonTargetLanguages.first(where: { $0.code == targetCode })
                    ?? TranslationService.shared.suggestedTargetLanguage(for: text)
            } else {
                target = TranslationService.shared.suggestedTargetLanguage(for: text)
            }
            self.state.selectedTargetLanguage = target

            self.state.isTranslating = true
            self.state.translationErrorMessage = nil

            Task {
                do {
                    let result = try await TranslationService.shared.translate(
                        text: text,
                        sourceLang: code,
                        targetCode: target.code
                    )
                    await MainActor.run {
                        self.state.translatedText = result
                        self.state.isTranslating = false
                    }
                } catch {
                    await MainActor.run {
                        self.state.translationErrorMessage = error.localizedDescription
                        self.state.isTranslating = false
                    }
                }
            }
        }

        if state.kind == .image, let img = state.image {
            if !state.sourceTextForTranslation.isEmpty {
                executeWithText(state.sourceTextForTranslation)
            } else if !state.ocrLines.isEmpty {
                executeWithText(state.ocrLines.joined(separator: "\n"))
            } else {
                state.isTranslating = true
                ScreenshotManager.recognizeLines(from: img) { [weak self] lines in
                    let joined = lines.joined(separator: "\n")
                    self?.state.ocrLines = lines
                    executeWithText(joined)
                }
            }
        } else {
            executeWithText(state.textContent)
        }
    }

    func close() {
        cancellables.removeAll()
        hideToolbarImmediate()
        toolbarPanel = nil
        toolbarHostingView = nil
        panel?.orderOut(nil)
        panel = nil
        onClose?(state.id)
    }
}

// MARK: - 全局贴图管理器（F3 贴图 / Shift+F3 显隐全部）

@MainActor
final class PinWindowManager: ObservableObject {
    static let shared = PinWindowManager()
    @Published private(set) var pinCount: Int = 0
    @Published private(set) var allHidden: Bool = false

    private var controllers: [UUID: PinWindowController] = [:]
    private var cascadeOffset: CGFloat = 0
    var onPasteText: ((String) -> Void)?

    /// 将指定历史条目贴到屏幕上
    func pin(item: ClipboardItem) {
        let state: PinItemState
        let size: CGSize

        switch item.kind {
        case .image:
            guard let p = item.dataPath, let img = NSImage(contentsOfFile: p) else { return }
            state = PinItemState(kind: .image, textContent: item.content, image: img, imageSizeText: item.content)
            size = Self.idealImagePinSize(for: img)
        case .table:
            let rows: [[String]]
            if let json = item.tableJson, let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([[String]].self, from: data), !decoded.isEmpty {
                rows = decoded
            } else {
                rows = TableParser.parseTSV(item.content) ?? [[item.content]]
            }
            state = PinItemState(kind: .table, textContent: item.content, tableRows: rows)
            size = CGSize(width: 440, height: 280)
        case .shortText, .longText:
            state = PinItemState(kind: item.kind, textContent: item.content)
            size = Self.idealTextPinSize(for: item.content, paragraphs: state.paragraphs)
        }

        presentPin(state: state, size: size)
    }

    /// 按 F3 触发：将当前系统剪贴板中的最新内容（刚截完的图、复制的文字/表格）直接贴到屏幕上
    func pinCurrentPasteboard(fallbackItem: ClipboardItem?) {
        let pb = NSPasteboard.general

        // 1. 若剪贴板当前是图片（例如刚按 F1 框选完截图）
        if let imgData = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let img = NSImage(data: imgData) {
            let w = Int(img.size.width)
            let h = Int(img.size.height)
            let state = PinItemState(kind: .image, textContent: "\(w)×\(h)", image: img, imageSizeText: "\(w)×\(h)")
            presentPin(state: state, size: Self.idealImagePinSize(for: img))
            return
        }

        // 2. 若剪贴板是文本
        if let str = pb.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if str.count <= 60_000, str.contains("\t"),
               TableParser.looksLikeTSV(str), let rows = TableParser.parseTSV(str) {
                let state = PinItemState(kind: .table, textContent: str, tableRows: rows)
                presentPin(state: state, size: CGSize(width: 440, height: 280))
                return
            }
            let kind: ClipboardKind = str.count > 100 ? .longText : .shortText
            let state = PinItemState(kind: kind, textContent: str)
            presentPin(state: state, size: Self.idealTextPinSize(for: str, paragraphs: state.paragraphs))
            return
        }

        // 3. 兜底：使用历史列表中第一条记录
        if let fallbackItem {
            pin(item: fallbackItem)
        }
    }

    /// 截图工具栏直接调用：将带标注的截图贴到原先框选的屏幕位置，可选立即执行 OCR 或翻译
    func pinImage(_ image: NSImage, atScreenRect screenRect: NSRect? = nil, triggerOCR: Bool = false, triggerTranslate: Bool = false) {
        let rep = image.representations.first
        let pw = rep?.pixelsWide ?? Int(image.size.width)
        let ph = rep?.pixelsHigh ?? Int(image.size.height)
        let state = PinItemState(
            kind: .image,
            textContent: "\(pw)×\(ph)",
            image: image,
            imageSizeText: "\(pw)×\(ph)"
        )
        let size: CGSize
        let exactOrigin: NSPoint?
        if let r = screenRect, r.width >= 60, r.height >= 40 {
            let w = min(max(r.width, 160), 960)
            let h = min(max(r.height, 100), 860)
            size = CGSize(width: w, height: h)
            exactOrigin = NSPoint(x: r.minX, y: r.maxY - h)
        } else {
            size = Self.idealImagePinSize(for: image)
            exactOrigin = nil
        }
        let controller = presentPin(state: state, size: size, exactOrigin: exactOrigin)
        if triggerTranslate {
            controller.triggerTranslate()
        } else if triggerOCR {
            controller.triggerOCR()
        }
    }

    /// Shift+F3：隐藏或显示全部贴图
    func toggleAllPins() {
        guard !controllers.isEmpty else { return }
        allHidden.toggle()
        for c in controllers.values {
            if allHidden {
                c.hideToolbarImmediate()
                c.panel?.orderOut(nil)
            } else {
                c.panel?.orderFrontRegardless()
            }
        }
    }

    func closeAllPins() {
        let all = Array(controllers.values)
        controllers.removeAll()
        for c in all { c.close() }
        pinCount = 0
        allHidden = false
    }

    @discardableResult
    private func presentPin(state: PinItemState, size: CGSize, exactOrigin: NSPoint? = nil) -> PinWindowController {
        if allHidden {
            allHidden = false
            for c in controllers.values { c.panel?.orderFrontRegardless() }
        }
        let controller = PinWindowController(state: state, initialSize: size)
        controller.onClose = { [weak self] id in
            self?.controllers.removeValue(forKey: id)
            self?.pinCount = self?.controllers.count ?? 0
        }
        controllers[state.id] = controller
        pinCount = controllers.count

        let mouse = NSEvent.mouseLocation
        let pt = NSPoint(x: mouse.x + cascadeOffset, y: mouse.y - cascadeOffset)
        if exactOrigin == nil {
            cascadeOffset = (cascadeOffset + 20).truncatingRemainder(dividingBy: 100)
        }
        controller.show(near: pt, exactOrigin: exactOrigin)
        return controller
    }

    private static func idealTextPinSize(for text: String, paragraphs: [String]) -> CGSize {
        if paragraphs.count >= 2 {
            let h = min(max(CGFloat(paragraphs.count) * 44 + 40, 180), 460)
            return CGSize(width: 380, height: h)
        }
        let lineCount = max(text.components(separatedBy: .newlines).count, Int(ceil(Double(text.count) / 34.0)))
        let w: CGFloat = text.count > 260 ? 440 : 360
        let h = min(max(CGFloat(lineCount) * 20 + 36, 150), 440)
        return CGSize(width: w, height: h)
    }

    private static func idealImagePinSize(for img: NSImage) -> CGSize {
        let rep = img.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(img.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(img.size.height))
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        var w = pw / scale
        var h = ph / scale
        if w <= 0 || h <= 0 { w = 360; h = 260 }
        let maxW: CGFloat = 640
        let maxH: CGFloat = 520
        let ratio = min(maxW / w, maxH / h, 1.0)
        w = max(w * ratio, 160)
        h = max(h * ratio, 100)
        return CGSize(width: w, height: h)
    }
}
