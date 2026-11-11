import AppKit
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

    /// 窗口透明度（0.15 ~ 1.0）与折叠状态
    @Published var opacity: Double = 1.0
    @Published var isCollapsed: Bool = false

    init(kind: ClipboardKind, textContent: String, image: NSImage? = nil, imageSizeText: String = "", tableRows: [[String]] = []) {
        self.kind = kind
        self.textContent = textContent
        self.paragraphs = (kind == .shortText || kind == .longText) ? parseParagraphs(textContent) : []
        self.image = image
        self.imageSizeText = imageSizeText
        self.tableRows = tableRows
    }
}

// MARK: - 贴图浮动面板（支持拖拽顶部栏移动、⌘+滚轮调透明度、图片滚轮缩放、Esc 关闭）

@MainActor
final class PinPanel: NSPanel {
    weak var pinState: PinItemState?
    var onScrollOpacity: ((CGFloat) -> Void)?
    var onScrollScale: ((CGFloat) -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    var isImagePin: Bool = false
    var isShowingScrollableContent: Bool = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let loc = event.locationInWindow
            let collapsed = pinState?.isCollapsed ?? false
            let inHeader = collapsed || (loc.y >= frame.height - 36)
            let inResizeZone = !collapsed && (loc.x >= frame.width - 14 || loc.y <= 14)

            // 顶部栏左侧标题区双击：折叠/展开为胶囊
            if inHeader && event.clickCount == 2 && loc.x < frame.width - 125 {
                onToggleCollapse?()
                return
            }

            let isSelectingOrEditing: Bool = {
                guard let s = pinState else { return false }
                if s.isEditingText { return true }
                if s.kind == .shortText || s.kind == .longText { return true } // 文本贴图内容区默认直接划词选择，拖拽顶部栏移动窗口
                if s.kind == .image && !s.showOCRList && !s.showTranslation { return true } // 图片贴图默认直接划词
                return false
            }()

            let isCommandDown = event.modifierFlags.contains(.command)

            let allowDragWindow: Bool
            if inResizeZone {
                allowDragWindow = false
            } else if inHeader || isCommandDown {
                allowDragWindow = true
            } else if isSelectingOrEditing {
                allowDragWindow = false
            } else {
                allowDragWindow = true
            }

            if allowDragWindow {
                let startMouse = NSEvent.mouseLocation
                let startOrigin = frame.origin
                var didStartDrag = false

                // 在交给子视图（SwiftUI / LiveText）之前先判断是「点击」还是「拖拽移动窗口」
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
                        if !didStartDrag && hypot(dx, dy) >= 2.5 {
                            didStartDrag = true
                        }
                        if didStartDrag {
                            setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
                        }
                    } else if next.type == .leftMouseUp {
                        if !didStartDrag {
                            // 未发生移动，属于正常点击：完整转发 down + up 给子视图按钮
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

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Command + 滚轮：无级调节贴图透明度
        if flags.contains(.command) {
            let step = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.03)
            onScrollOpacity?(step)
            return
        }
        // Option + 滚轮，或在纯图片展示态下直接滚轮：等比缩放贴图大小
        if flags.contains(.option) || (isImagePin && !isShowingScrollableContent) {
            let factor = (event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.04)
            onScrollScale?(factor)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Esc (53) 或 Command+W (13) 关闭当前贴图
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 || (event.keyCode == 13 && flags == .command) {
            onCloseRequest?()
            return
        }
        super.keyDown(with: event)
    }
}

final class PinHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - 单个贴图窗口控制器

@MainActor
final class PinWindowController: NSObject {
    let state: PinItemState
    private(set) var panel: PinPanel?
    private var expandedSize: CGSize
    var onClose: ((UUID) -> Void)?

    init(state: PinItemState, initialSize: CGSize) {
        self.state = state
        self.expandedSize = initialSize
        super.init()
        setupPanel(initialSize: initialSize)
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
            self.scaleBy(1.0 + factor)
        }
        p.onToggleCollapse = { [weak self] in
            self?.toggleCollapse()
        }
        p.onCloseRequest = { [weak self] in
            self?.close()
        }

        let rootView = PinContentView(
            state: state,
            onToggleCollapse: { [weak self] in self?.toggleCollapse() },
            onOpacityChange: { [weak self] val in self?.setOpacity(val) },
            onTriggerOCR: { [weak self] in self?.triggerOCR() },
            onTriggerTranslate: { [weak self] in self?.triggerTranslate() },
            onChangeTargetLanguage: { [weak self] lang in self?.triggerTranslate(targetCode: lang.code) },
            onResizeStart: { [weak p] in p?.frame.size ?? initialSize },
            onResize: { [weak self] base, delta in self?.resize(from: base, delta: delta) },
            onClose: { [weak self] in self?.close() }
        )
        p.contentView = PinHostingView(rootView: rootView)
        self.panel = p
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
        panel.orderFrontRegardless()
        panel.makeKey()
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
    }

    func scaleBy(_ ratio: CGFloat) {
        guard let panel, !state.isCollapsed else { return }
        let clampedRatio = min(max(ratio, 0.85), 1.18)
        let f = panel.frame
        let w = min(max(f.width * clampedRatio, 200), 1200)
        let h = min(max(f.height * clampedRatio, 110), 1000)
        let newOrigin = NSPoint(x: f.midX - w / 2, y: f.midY - h / 2)
        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: w, height: h))
        panel.setFrame(newFrame, display: true)
        expandedSize = newFrame.size
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
            let paraCount = state.paragraphs.count
            let h = paraCount >= 2 ? min(max(CGFloat(paraCount) * 44 + 54, 180), 420) : 200
            size = CGSize(width: 360, height: h)
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
            let paraCount = state.paragraphs.count
            let h = paraCount >= 2 ? min(max(CGFloat(paraCount) * 44 + 54, 180), 420) : 200
            presentPin(state: state, size: CGSize(width: 360, height: h))
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
            let w = min(max(r.width, 220), 960)
            let h = min(max(r.height + 34, 140), 860)
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
        w = max(w * ratio, 220)
        h = max(h * ratio + 34, 140) // +34 为顶部控制栏高度
        return CGSize(width: w, height: h)
    }
}
