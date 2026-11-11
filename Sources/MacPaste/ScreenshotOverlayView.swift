import AppKit
import CoreGraphics

// MARK: - 全屏截图交互窗口

final class ScreenshotOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.clickCount == 1,
           let canvas = contentView as? ScreenshotCanvasView,
           canvas.isPointInActiveTextField(windowPoint: event.locationInWindow) {
            let startScreen = NSEvent.mouseLocation
            var didDrag = false
            while let next = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) {
                if next.type == .leftMouseDragged {
                    let curScreen = NSEvent.mouseLocation
                    let dx = curScreen.x - startScreen.x
                    let dy = startScreen.y - curScreen.y // flipped view: screen +y is view -y
                    if !didDrag && hypot(dx, dy) >= 3.0 {
                        didDrag = true
                        canvas.beginActiveTextFieldDrag()
                    }
                    if didDrag {
                        canvas.updateActiveTextFieldDrag(dx: dx, dy: dy)
                    }
                } else if next.type == .leftMouseUp {
                    if !didDrag {
                        super.sendEvent(event)
                        super.sendEvent(next)
                    } else {
                        canvas.endActiveTextFieldDrag()
                    }
                    break
                }
            }
            return
        }
        super.sendEvent(event)
    }
}

// MARK: - 全屏截图画布视图（isFlipped = true，左上角为原点）

final class ScreenshotCanvasView: NSView, NSTextFieldDelegate {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    let sampler: ScreenBitmapSampler
    let hasScreenPermission: Bool

    var onFinishCopy: ((NSImage, CGRect) -> Void)?
    var onFinishPin: ((NSImage, CGRect, Bool, Bool) -> Void)?
    var onFinishSave: ((NSImage) -> Void)?
    var onStartScrollCapture: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    // 选区与交互状态
    private(set) var selectionRect: CGRect?
    private var activeTool: ScreenshotTool?
    private var selectedColorIndex: Int = 0
    private var selectedWidthIndex: Int = 1
    private var annotations: [ScreenshotAnnotation] = []
    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []
    private var currentAnnotation: ScreenshotAnnotation?

    // MARK: - 原地截图翻译状态
    struct InPlaceTranslationData {
        let sourceText: String
        let translatedText: String
        let targetLanguage: TranslationService.TargetLanguage
        let dominantBgColor: NSColor
        let textColor: NSColor
    }

    var showTranslationInPlace: Bool = false
    var isTranslatingInPlace: Bool = false
    var inPlaceTranslationData: InPlaceTranslationData?
    var inPlaceTranslationError: String?
    var selectedTargetLanguage: TranslationService.TargetLanguage = TranslationService.commonTargetLanguages.first(where: { $0.id == "en" }) ?? TranslationService.commonTargetLanguages[1]
    var isShowingLanguageMenu: Bool = false
    var currentTransButtonRect: CGRect = .zero
    private var activeTranslationRequestId: UUID?

    // 已放置标注的选中与悬停状态（支持拖拽移动位置、调整端点/四角、双击重编辑文字、修改颜色粗细与删除）
    private var selectedAnnotationId: UUID?
    private var hoveredAnnotationId: UUID?
    private var hoveredAnnotationHandle: AnnotationHandle?

    private enum DragMode {
        case none
        case creatingSelection(start: CGPoint)
        case resizingSelection(handle: ResizeHandle, initialRect: CGRect)
        case movingSelection(startMouse: CGPoint, initialRect: CGRect)
        case drawingAnnotation
        case movingAnnotation(id: UUID, startMouse: CGPoint, initialAnnotation: ScreenshotAnnotation, preMoveSnapshot: [ScreenshotAnnotation])
        case resizingAnnotation(id: UUID, handle: AnnotationHandle, initialAnnotation: ScreenshotAnnotation, preResizeSnapshot: [ScreenshotAnnotation])
    }

    private var dragMode: DragMode = .none
    private var mouseLocationInView: CGPoint = .zero
    private var hoveredHandle: ResizeHandle?
    private var hoveredToolbarId: String?
    private var trackingAreaRef: NSTrackingArea?
    private var toastMessage: String?

    // 工具栏按钮点击热区
    private struct ToolbarHitItem {
        let id: String
        let rect: CGRect
        let tooltip: String
        let action: () -> Void
    }
    private var toolbarHits: [ToolbarHitItem] = []

    // 文字标注内联输入框
    private var textInputField: NSTextField?
    private var textInputOrigin: CGPoint = .zero
    private var textFieldDragStartOrigin: CGPoint = .zero
    private var editingTextAnnotation: ScreenshotAnnotation?
    private var preEditTextSnapshot: [ScreenshotAnnotation]?

    init(frame: NSRect, sampler: ScreenBitmapSampler, hasScreenPermission: Bool) {
        self.sampler = sampler
        self.hasScreenPermission = hasScreenPermission
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingAreaRef { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func syncInitialMouseLocation() {
        guard let win = window else { return }
        let screenPt = NSEvent.mouseLocation
        let winPt = win.convertPoint(fromScreen: screenPt)
        mouseLocationInView = convert(winPt, from: nil)
        needsDisplay = true
    }

    // MARK: - 绘制主入口

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        // 1. 绘制全屏冻结底图（若已授权屏幕录制）
        if hasScreenPermission {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(sampler.cgImage, in: bounds)
            ctx.restoreGState()
        }

        // 2. 绘制截图状态暗色遮罩（选区外半透明深蓝黑遮罩，选区内 100% 清晰）
        let maskColor = NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.14, alpha: 0.48)
        if let sel = selectionRect, sel.width > 1, sel.height > 1 {
            let maskPath = NSBezierPath(rect: bounds)
            maskPath.append(NSBezierPath(rect: sel))
            maskPath.windingRule = .evenOdd
            maskColor.setFill()
            maskPath.fill()
        } else {
            maskColor.setFill()
            bounds.fill()
        }

        // 3. 绘制全屏四周醒目颜色提示框（让用户一眼感知处于截图模式中）
        drawFullScreenModeIndicator()

        // 4. 绘制选区内的标注、选区边框、8个边角控制点与尺寸标签
        if let sel = selectionRect, sel.width > 1, sel.height > 1 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: sel).addClip()

            // 原地翻译生效时：先在选区底层绘制翻译后的背景和排版文本，完全替换原屏幕像素！
            if showTranslationInPlace, let transData = inPlaceTranslationData {
                drawInPlaceTranslation(transData, in: sel)
            }

            for item in annotations {
                ScreenshotRenderer.drawAnnotation(item, sampler: sampler)
            }
            if let current = currentAnnotation {
                ScreenshotRenderer.drawAnnotation(current, sampler: sampler)
            }
            drawAnnotationSelectionFeedback()
            NSGraphicsContext.restoreGraphicsState()

            // 绘制正在翻译加载/错误浮层
            if isTranslatingInPlace {
                drawTranslatingOverlay(in: sel)
            } else if let err = inPlaceTranslationError {
                drawTranslationErrorOverlay(err, in: sel)
            }

            drawSelectionFrameAndHandles(sel)
        } else {
            // 未框选时绘制全屏十字准星辅助线
            drawCrosshairGuides(at: mouseLocationInView)
        }

        // 5. 绘制顶部截图状态提示胶囊
        drawTopStatusBanner()

        // 6. 绘制边角拖动/未框选时的实时像素放大镜预览（Loupe）
        if shouldShowMagnifier {
            drawMagnifierLoupe(around: magnifierFocusPoint)
        }

        // 7. 绘制选区底部浮动标注与操作工具栏
        toolbarHits.removeAll()
        if let sel = selectionRect, sel.width >= 12, sel.height >= 12, !isActivelyDragging {
            drawFloatingToolbar(for: sel)
            if isShowingLanguageMenu {
                drawLanguageMenu(anchorRect: currentTransButtonRect)
            }
        } else {
            isShowingLanguageMenu = false
        }
    }

    private var isActivelyDragging: Bool {
        switch dragMode {
        case .none: return false
        default: return true
        }
    }

    private var shouldShowMagnifier: Bool {
        if textInputField != nil { return false }
        if selectionRect == nil { return true }
        switch dragMode {
        case .creatingSelection, .resizingSelection:
            return true
        case .movingSelection, .drawingAnnotation, .movingAnnotation, .resizingAnnotation:
            return false
        case .none:
            return hoveredHandle != nil
        }
    }

    private var magnifierFocusPoint: CGPoint {
        if case .resizingSelection(let handle, _) = dragMode, let sel = selectionRect {
            return handle.point(in: sel)
        }
        if let handle = hoveredHandle, let sel = selectionRect {
            return handle.point(in: sel)
        }
        return mouseLocationInView
    }
}

// MARK: - 视觉绘制（全屏颜色提示、8控制点、放大镜预览、标注工具栏）

extension ScreenshotCanvasView {
    /// 全屏四周醒目高亮颜色提示框 + 四角 L 型取景框
    func drawFullScreenModeIndicator() {
        let accent = activeTool != nil
            ? ScreenshotPalette.colors[selectedColorIndex].color
            : ScreenshotPalette.themeAccent

        // 内发光柔化层
        accent.withAlphaComponent(0.14).setStroke()
        let innerGlow2 = NSBezierPath(rect: bounds.insetBy(dx: 8, dy: 8))
        innerGlow2.lineWidth = 10
        innerGlow2.stroke()

        accent.withAlphaComponent(0.32).setStroke()
        let innerGlow1 = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
        innerGlow1.lineWidth = 5
        innerGlow1.stroke()

        // 主高亮外框
        accent.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3.0
        border.stroke()

        // 四角醒目 L 型镜头角标
        let cornerLen: CGFloat = 34
        let inset: CGFloat = 5
        let cornersPath = NSBezierPath()
        cornersPath.lineWidth = 5.0
        cornersPath.lineCapStyle = .round

        // 左上
        cornersPath.move(to: CGPoint(x: inset, y: inset + cornerLen))
        cornersPath.line(to: CGPoint(x: inset, y: inset))
        cornersPath.line(to: CGPoint(x: inset + cornerLen, y: inset))
        // 右上
        cornersPath.move(to: CGPoint(x: bounds.width - inset - cornerLen, y: inset))
        cornersPath.line(to: CGPoint(x: bounds.width - inset, y: inset))
        cornersPath.line(to: CGPoint(x: bounds.width - inset, y: inset + cornerLen))
        // 左下
        cornersPath.move(to: CGPoint(x: inset, y: bounds.height - inset - cornerLen))
        cornersPath.line(to: CGPoint(x: inset, y: bounds.height - inset))
        cornersPath.line(to: CGPoint(x: inset + cornerLen, y: bounds.height - inset))
        // 右下
        cornersPath.move(to: CGPoint(x: bounds.width - inset - cornerLen, y: bounds.height - inset))
        cornersPath.line(to: CGPoint(x: bounds.width - inset, y: bounds.height - inset))
        cornersPath.line(to: CGPoint(x: bounds.width - inset, y: bounds.height - inset - cornerLen))

        accent.setStroke()
        cornersPath.stroke()
    }

    /// 未框选时的全屏十字准星引导线
    func drawCrosshairGuides(at pt: CGPoint) {
        let guideColor = ScreenshotPalette.themeAccent.withAlphaComponent(0.55)
        guideColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.0
        let dash: [CGFloat] = [5, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.move(to: CGPoint(x: 0, y: pt.y))
        path.line(to: CGPoint(x: bounds.width, y: pt.y))
        path.move(to: CGPoint(x: pt.x, y: 0))
        path.line(to: CGPoint(x: pt.x, y: bounds.height))
        path.stroke()
    }

    /// 顶部简短轻提示胶囊（仅在复制色值等操作时短暂浮现，平时不显示任何冗余文字）
    func drawTopStatusBanner() {
        guard let toast = toastMessage else { return }
        let fullText = "✓ \(toast)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (fullText as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 14
        let padY: CGFloat = 6
        let pillW = textSize.width + padX * 2
        let pillH = textSize.height + padY * 2
        let pillRect = CGRect(
            x: (bounds.width - pillW) / 2,
            y: 18,
            width: pillW,
            height: pillH
        )

        let bgPath = NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2)
        NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.20, alpha: 0.90).setFill()
        bgPath.fill()

        ScreenshotPalette.themeAccent.withAlphaComponent(0.9).setStroke()
        bgPath.lineWidth = 1.5
        bgPath.stroke()

        (fullText as NSString).draw(
            at: CGPoint(x: pillRect.minX + padX, y: pillRect.minY + padY),
            withAttributes: attrs
        )
    }

    /// 绘制选区高亮边框、8 个边角/边缘拖拽控制点与左上角尺寸气泡
    func drawSelectionFrameAndHandles(_ sel: CGRect) {
        let accent = ScreenshotPalette.themeAccent

        // 外发光与主边框
        accent.withAlphaComponent(0.28).setStroke()
        let glowPath = NSBezierPath(rect: sel.insetBy(dx: -2, dy: -2))
        glowPath.lineWidth = 4.0
        glowPath.stroke()

        accent.setStroke()
        let borderPath = NSBezierPath(rect: sel)
        borderPath.lineWidth = 2.0
        borderPath.stroke()

        // 8 个边角/边缘控制点
        for handle in ResizeHandle.allCases {
            let pt = handle.point(in: sel)
            let isActive: Bool = {
                if case .resizingSelection(let h, _) = dragMode { return h == handle }
                return hoveredHandle == handle
            }()
            let size: CGFloat = isActive ? 11.0 : 8.5
            let hRect = CGRect(x: pt.x - size / 2, y: pt.y - size / 2, width: size, height: size)
            let hPath = NSBezierPath(roundedRect: hRect, xRadius: 2.5, yRadius: 2.5)
            if isActive {
                accent.setFill()
                hPath.fill()
                NSColor.white.setStroke()
            } else {
                NSColor.white.setFill()
                hPath.fill()
                accent.setStroke()
            }
            hPath.lineWidth = 2.0
            hPath.stroke()
        }

        // 左上角极简像素尺寸标签
        let pw = Int((sel.width * sampler.scaleFactor).rounded())
        let ph = Int((sel.height * sampler.scaleFactor).rounded())
        let sizeText = "\(pw) × \(ph)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let tSize = (sizeText as NSString).size(withAttributes: attrs)
        let tagW = tSize.width + 12
        let tagH = tSize.height + 6
        let tagX = min(max(sel.minX, 8), bounds.width - tagW - 8)
        let tagY = sel.minY >= tagH + 10 ? (sel.minY - tagH - 6) : (sel.minY + 6)
        let tagRect = CGRect(x: tagX, y: tagY, width: tagW, height: tagH)

        let tagPath = NSBezierPath(roundedRect: tagRect, xRadius: 5, yRadius: 5)
        NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.19, alpha: 0.90).setFill()
        tagPath.fill()
        accent.withAlphaComponent(0.75).setStroke()
        tagPath.lineWidth = 1.2
        tagPath.stroke()

        (sizeText as NSString).draw(
            at: CGPoint(x: tagRect.minX + 6, y: tagRect.minY + 3),
            withAttributes: attrs
        )
    }

    /// 绘制边角拖动/鼠标移动时的实时像素放大镜预览（极简无冗余提示文字）
    func drawMagnifierLoupe(around targetPt: CGPoint) {
        let loupeW: CGFloat = 132
        let imgH: CGFloat = 92
        let infoH: CGFloat = 42
        let loupeH = imgH + infoH

        // 自动避让屏幕边缘
        var lx = mouseLocationInView.x + 22
        var ly = mouseLocationInView.y + 24
        if lx + loupeW + 12 > bounds.width {
            lx = mouseLocationInView.x - loupeW - 22
        }
        if ly + loupeH + 12 > bounds.height {
            ly = mouseLocationInView.y - loupeH - 24
        }
        lx = min(max(lx, 10), bounds.width - loupeW - 10)
        ly = min(max(ly, 10), bounds.height - loupeH - 10)

        let loupeRect = CGRect(x: lx, y: ly, width: loupeW, height: loupeH)
        let imgRect = CGRect(x: lx, y: ly, width: loupeW, height: imgH)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // 外框背景
        let outerPath = NSBezierPath(roundedRect: loupeRect, xRadius: 9, yRadius: 9)
        NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.16, alpha: 0.96).setFill()
        outerPath.fill()

        // 顶部放大镜像素区
        NSGraphicsContext.saveGraphicsState()
        let imgClip = NSBezierPath(roundedRect: imgRect, xRadius: 9, yRadius: 9)
        imgClip.addClip()

        if let patch = sampler.croppedMagnifierPatch(centerViewPoint: targetPt, radiusInPoints: 9),
           let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: imgRect.minX, y: imgRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(patch, in: CGRect(x: 0, y: 0, width: imgRect.width, height: imgRect.height))
            ctx.restoreGState()
        }

        // 像素细网格线
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let gridPath = NSBezierPath()
        gridPath.lineWidth = 0.5
        let step: CGFloat = 8
        var gx = imgRect.minX
        while gx <= imgRect.maxX {
            gridPath.move(to: CGPoint(x: gx, y: imgRect.minY))
            gridPath.line(to: CGPoint(x: gx, y: imgRect.maxY))
            gx += step
        }
        var gy = imgRect.minY
        while gy <= imgRect.maxY {
            gridPath.move(to: CGPoint(x: imgRect.minX, y: gy))
            gridPath.line(to: CGPoint(x: imgRect.maxX, y: gy))
            gy += step
        }
        gridPath.stroke()

        // 中心十字准星与像素取景格
        let cx = imgRect.midX
        let cy = imgRect.midY
        ScreenshotPalette.themeAccent.withAlphaComponent(0.88).setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.4
        cross.move(to: CGPoint(x: imgRect.minX, y: cy))
        cross.line(to: CGPoint(x: imgRect.maxX, y: cy))
        cross.move(to: CGPoint(x: cx, y: imgRect.minY))
        cross.line(to: CGPoint(x: cx, y: imgRect.maxY))
        cross.stroke()

        let centerBox = CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)
        NSColor.white.setStroke()
        let cbPath = NSBezierPath(rect: centerBox)
        cbPath.lineWidth = 1.5
        cbPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 底部极简坐标与 HEX 色值栏
        let pixelInfo = sampler.colorAt(viewPoint: targetPt)
        let titleLine: String
        if let sel = selectionRect {
            let pw = Int((sel.width * sampler.scaleFactor).rounded())
            let ph = Int((sel.height * sampler.scaleFactor).rounded())
            titleLine = "\(pw) × \(ph)"
        } else {
            titleLine = "(\(Int(targetPt.x)), \(Int(targetPt.y)))"
        }

        let line1Attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: ScreenshotPalette.themeAccent,
        ]
        (titleLine as NSString).draw(at: CGPoint(x: lx + 8, y: ly + imgH + 4), withAttributes: line1Attrs)

        let swatchRect = CGRect(x: lx + 8, y: ly + imgH + 22, width: 12, height: 12)
        pixelInfo.nsColor.setFill()
        NSBezierPath(roundedRect: swatchRect, xRadius: 2.5, yRadius: 2.5).fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        NSBezierPath(roundedRect: swatchRect, xRadius: 2.5, yRadius: 2.5).stroke()

        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        (pixelInfo.hex as NSString).draw(
            at: CGPoint(x: lx + 24, y: ly + imgH + 21),
            withAttributes: hexAttrs
        )

        // 放大镜高亮外边框
        ScreenshotPalette.themeAccent.withAlphaComponent(0.9).setStroke()
        outerPath.lineWidth = 1.8
        outerPath.stroke()
    }

    /// 绘制已放置标注的悬停提示框与选中态控制点（支持直观拖拽移动、调大小与修改样式）
    func drawAnnotationSelectionFeedback() {
        // 1. 若有鼠标悬停标注且未选中它，画一条轻量虚线框提示用户该标注可点选拖拽
        if let hovId = hoveredAnnotationId,
           hovId != selectedAnnotationId,
           let ann = annotations.first(where: { $0.id == hovId }) {
            let rect = ann.boundingRect.insetBy(dx: -3, dy: -3)
            let hoverPath = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.white.withAlphaComponent(0.45).setStroke()
            hoverPath.lineWidth = 1.0
            hoverPath.setLineDash([4, 3], count: 2, phase: 0)
            hoverPath.stroke()
        }

        // 2. 绘制选中标注的边框与端点控制点
        guard let selId = selectedAnnotationId,
              let ann = annotations.first(where: { $0.id == selId }) else { return }

        let accent = ScreenshotPalette.themeAccent
        let boundsRect = ann.boundingRect.insetBy(dx: -4, dy: -4)

        // 选中外框（青蓝高亮虚线框）
        let boxPath = NSBezierPath(roundedRect: boundsRect, xRadius: 5, yRadius: 5)
        accent.withAlphaComponent(0.85).setStroke()
        boxPath.lineWidth = 1.5
        boxPath.setLineDash([5, 3], count: 2, phase: 0)
        boxPath.stroke()

        // 绘制该标注的形状调整控制点（针对箭头端点、矩形/圆框/画笔/荧光笔/文字四角与四边缘）
        for item in ann.resizeHandles {
            let isHov = (hoveredAnnotationHandle == item.handle)
            let size: CGFloat = isHov ? 10.0 : 8.0
            let hRect = CGRect(x: item.point.x - size / 2, y: item.point.y - size / 2, width: size, height: size)
            let hPath = NSBezierPath(roundedRect: hRect, xRadius: 2.0, yRadius: 2.0)
            if isHov {
                accent.setFill()
                hPath.fill()
                NSColor.white.setStroke()
            } else {
                NSColor.white.setFill()
                hPath.fill()
                accent.setStroke()
            }
            hPath.lineWidth = 1.8
            hPath.stroke()
        }
    }

    // MARK: - 实时文字输入框拖拽与尺寸自适应

    func isPointInActiveTextField(windowPoint: NSPoint) -> Bool {
        guard let tf = textInputField else { return false }
        let pt = convert(windowPoint, from: nil)
        return tf.frame.insetBy(dx: -6, dy: -4).contains(pt)
    }

    func beginActiveTextFieldDrag() {
        textFieldDragStartOrigin = textInputOrigin
    }

    func updateActiveTextFieldDrag(dx: CGFloat, dy: CGFloat) {
        guard let tf = textInputField else { return }
        var newX = textFieldDragStartOrigin.x + dx
        var newY = textFieldDragStartOrigin.y + dy
        if let sel = selectionRect {
            newX = min(max(newX, sel.minX), sel.maxX - 40)
            newY = min(max(newY, sel.minY), sel.maxY - 20)
        }
        textInputOrigin = CGPoint(x: newX, y: newY)
        tf.frame.origin = CGPoint(x: newX, y: newY - 4)
        needsDisplay = true
    }

    func endActiveTextFieldDrag() {
        needsDisplay = true
    }

    func resizeActiveTextFieldToFit() {
        guard let tf = textInputField else { return }
        let str = tf.stringValue.isEmpty ? "输入批注文字 (回车确认)..." : tf.stringValue
        let font = tf.font ?? NSFont.systemFont(ofSize: 15, weight: .semibold)
        let textSize = (str as NSString).size(withAttributes: [.font: font])
        let w = max(textSize.width + 28, 160)
        let h = max(textSize.height + 12, 28)
        tf.frame = CGRect(x: textInputOrigin.x, y: textInputOrigin.y - 4, width: w, height: h)
    }

    func controlTextDidChange(_ obj: Notification) {
        resizeActiveTextFieldToFit()
    }

    func recordUndoSnapshot() {
        undoStack.append(annotations)
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func syncPaletteToAnnotation(_ ann: ScreenshotAnnotation) {
        if let cIdx = ScreenshotPalette.colors.firstIndex(where: {
            guard let c1 = $0.color.usingColorSpace(.deviceRGB),
                  let c2 = ann.color.usingColorSpace(.deviceRGB) else { return false }
            return abs(c1.redComponent - c2.redComponent) < 0.05 &&
                   abs(c1.greenComponent - c2.greenComponent) < 0.05 &&
                   abs(c1.blueComponent - c2.blueComponent) < 0.05
        }) {
            selectedColorIndex = cIdx
        }
        if let wIdx = ScreenshotPalette.strokeWidths.firstIndex(where: { abs($0.width - ann.lineWidth) < 0.5 }) {
            selectedWidthIndex = wIdx
        }
    }
}

// MARK: - 选区浮动工具栏与鼠标/键盘事件处理

extension ScreenshotCanvasView {
    func drawFloatingToolbar(for sel: CGRect) {
        let mainBarW: CGFloat = 530
        let mainBarH: CGFloat = 36
        let styleBarH: CGFloat = 32
        let showStyleBar = (activeTool != nil || selectedAnnotationId != nil || textInputField != nil)
        let totalH: CGFloat = showStyleBar ? (mainBarH + styleBarH + 6) : mainBarH

        var barX = sel.maxX - mainBarW
        barX = min(max(barX, 12), bounds.width - mainBarW - 12)

        var barY = sel.maxY + 10
        if barY + totalH + 12 > bounds.height {
            if sel.minY - totalH - 12 >= 12 {
                barY = sel.minY - totalH - 10
            } else {
                barY = sel.maxY - totalH - 12
            }
        }

        let mainRect = CGRect(x: barX, y: barY, width: mainBarW, height: mainBarH)
        let mainBg = NSBezierPath(roundedRect: mainRect, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.17, alpha: 0.95).setFill()
        mainBg.fill()
        ScreenshotPalette.themeAccent.withAlphaComponent(0.55).setStroke()
        mainBg.lineWidth = 1.2
        mainBg.stroke()

        var cursorX = mainRect.minX + 6
        let btnY = mainRect.minY + 4
        let btnW: CGFloat = 26
        let btnH: CGFloat = 28

        // 1. 7个纯图标标注工具按钮（横框、圆框、箭头、标记、荧光、打码、文字）
        for tool in ScreenshotTool.allCases {
            let isSelected = (activeTool == tool)
            let rect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
            let id = "tool_\(tool.rawValue)"
            drawToolbarIconButton(
                id: id,
                rect: rect,
                symbolName: tool.symbolName,
                tooltip: tool.tooltip,
                isSelected: isSelected,
                accentColor: ScreenshotPalette.colors[selectedColorIndex].color,
                isEnabled: true
            ) { [weak self] in
                guard let self else { return }
                self.commitPendingTextIfNeeded()
                if self.activeTool == tool {
                    self.activeTool = nil
                } else {
                    self.activeTool = tool
                }
                self.needsDisplay = true
            }
            cursorX += btnW + 2
        }

        drawToolbarDivider(at: cursorX + 2, minY: mainRect.minY + 6, height: 24)
        cursorX += 8

        // 2. 撤销 / 重做 / 清空
        let undoRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_undo",
            rect: undoRect,
            symbolName: "arrow.uturn.backward",
            tooltip: "撤销",
            isSelected: false,
            accentColor: ScreenshotPalette.themeAccent,
            isEnabled: !undoStack.isEmpty || !annotations.isEmpty
        ) { [weak self] in
            self?.performUndo()
        }
        cursorX += btnW + 2

        let redoRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_redo",
            rect: redoRect,
            symbolName: "arrow.uturn.forward",
            tooltip: "重做",
            isSelected: false,
            accentColor: ScreenshotPalette.themeAccent,
            isEnabled: !redoStack.isEmpty
        ) { [weak self] in
            self?.performRedo()
        }
        cursorX += btnW + 2

        let clearRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_clear",
            rect: clearRect,
            symbolName: "trash",
            tooltip: "清空",
            isSelected: false,
            accentColor: ScreenshotPalette.themeAccent,
            isEnabled: !annotations.isEmpty
        ) { [weak self] in
            guard let self, !self.annotations.isEmpty else { return }
            self.commitPendingTextIfNeeded()
            self.recordUndoSnapshot()
            self.annotations.removeAll()
            self.selectedAnnotationId = nil
            self.hoveredAnnotationId = nil
            self.hoveredAnnotationHandle = nil
            self.needsDisplay = true
        }
        cursorX += btnW + 2

        drawToolbarDivider(at: cursorX + 2, minY: mainRect.minY + 6, height: 24)
        cursorX += 8

        // 3. 输出操作图标（滚动截图 / 提取文字 / 保存 / 贴图 / 取消 / 完成）
        let scrollRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_scroll",
            rect: scrollRect,
            symbolName: "arrow.up.and.down.square",
            tooltip: "滚动截图",
            isSelected: false,
            accentColor: .systemCyan,
            isEnabled: true
        ) { [weak self] in
            self?.startScrollCapture()
        }
        cursorX += btnW + 2

        let ocrRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_ocr",
            rect: ocrRect,
            symbolName: "text.viewfinder",
            tooltip: "提取文字",
            isSelected: false,
            accentColor: ScreenshotPalette.themeAccent,
            isEnabled: true
        ) { [weak self] in
            self?.finishCapture(mode: .pinWithOCR)
        }
        cursorX += btnW + 2

        // 3. 截图原地翻译组合按钮（左侧图标触发/切换翻译，右侧下拉箭头呼出飞书式“将内容翻译为”多语言菜单）
        let transBtnW: CGFloat = 46
        let transRect = CGRect(x: cursorX, y: btnY, width: transBtnW, height: btnH)
        currentTransButtonRect = transRect
        let isTransActive = showTranslationInPlace
        let isTranslating = isTranslatingInPlace

        let transBg = NSBezierPath(roundedRect: transRect, xRadius: 6, yRadius: 6)
        if isTransActive {
            NSColor.systemBlue.withAlphaComponent(0.28).setFill()
            transBg.fill()
            NSColor.systemBlue.withAlphaComponent(0.65).setStroke()
            transBg.lineWidth = 1.0
            transBg.stroke()
        } else if hoveredToolbarId?.hasPrefix("act_translate") == true {
            NSColor.white.withAlphaComponent(0.12).setFill()
            transBg.fill()
        }

        let iconSubRect = CGRect(x: transRect.minX, y: transRect.minY, width: 28, height: transRect.height)
        let chevronSubRect = CGRect(x: transRect.minX + 28, y: transRect.minY, width: 18, height: transRect.height)

        toolbarHits.append(ToolbarHitItem(
            id: "act_translate_main",
            rect: iconSubRect,
            tooltip: isTransActive ? "显示原图" : "翻译",
            action: { [weak self] in
                guard let self else { return }
                if self.isTranslatingInPlace {
                    // 正在翻译时点击可取消
                    self.activeTranslationRequestId = nil
                    self.isTranslatingInPlace = false
                    self.needsDisplay = true
                    return
                }
                if self.inPlaceTranslationError != nil {
                    // 报错时点击重试
                    self.inPlaceTranslationError = nil
                    self.performInPlaceTranslation()
                    return
                }
                if self.inPlaceTranslationData != nil {
                    self.showTranslationInPlace.toggle()
                    self.needsDisplay = true
                } else {
                    self.performInPlaceTranslation()
                }
            }
        ))

        toolbarHits.append(ToolbarHitItem(
            id: "act_translate_menu",
            rect: chevronSubRect,
            tooltip: "选择语言",
            action: { [weak self] in
                guard let self else { return }
                self.isShowingLanguageMenu.toggle()
                self.needsDisplay = true
            }
        ))

        // 绘制主图标 (translate SF symbol)
        let iconColor: NSColor = isTransActive ? NSColor.systemBlue : (isTranslating ? NSColor.systemTeal : NSColor(white: 0.9, alpha: 1.0))
        if let icon = NSImage(systemSymbolName: "translate", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium).applying(.init(hierarchicalColor: iconColor))
            let configured = icon.withSymbolConfiguration(conf) ?? icon
            let center = CGPoint(x: iconSubRect.midX, y: iconSubRect.midY)
            let drawR = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
            configured.draw(in: drawR, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // 绘制中间细分割线
        let divX = transRect.minX + 28
        let divPath = NSBezierPath()
        divPath.move(to: CGPoint(x: divX, y: transRect.minY + 6))
        divPath.line(to: CGPoint(x: divX, y: transRect.maxY - 6))
        NSColor.white.withAlphaComponent(0.2).setStroke()
        divPath.lineWidth = 1.0
        divPath.stroke()

        // 绘制下拉箭头 chevron.down / chevron.up
        let chevSymbol = isShowingLanguageMenu ? "chevron.up" : "chevron.down"
        if let chev = NSImage(systemSymbolName: chevSymbol, accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            let configured = chev.withSymbolConfiguration(conf) ?? chev
            let center = CGPoint(x: chevronSubRect.midX, y: chevronSubRect.midY)
            let drawR = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            configured.draw(in: drawR, from: .zero, operation: .sourceOver, fraction: 0.85)
        }

        cursorX += transBtnW + 2

        let saveRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_save",
            rect: saveRect,
            symbolName: "square.and.arrow.down",
            tooltip: "保存",
            isSelected: false,
            accentColor: ScreenshotPalette.themeAccent,
            isEnabled: true
        ) { [weak self] in
            self?.finishCapture(mode: .saveFile)
        }
        cursorX += btnW + 2

        let pinRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_pin",
            rect: pinRect,
            symbolName: "pin.fill",
            tooltip: "贴图",
            isSelected: true,
            accentColor: NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.98, alpha: 1.0),
            isEnabled: true
        ) { [weak self] in
            self?.finishCapture(mode: .pinToScreen)
        }
        cursorX += btnW + 2

        let cancelRect = CGRect(x: cursorX, y: btnY, width: btnW, height: btnH)
        drawToolbarIconButton(
            id: "act_cancel",
            rect: cancelRect,
            symbolName: "xmark",
            tooltip: "取消",
            isSelected: false,
            accentColor: .systemRed,
            isEnabled: true
        ) { [weak self] in
            self?.commitPendingTextIfNeeded()
            self?.onCancel?()
        }
        cursorX += btnW + 2

        let doneRect = CGRect(x: cursorX, y: btnY, width: btnW + 4, height: btnH)
        drawToolbarIconButton(
            id: "act_done",
            rect: doneRect,
            symbolName: "checkmark",
            tooltip: "完成",
            isSelected: true,
            accentColor: NSColor(calibratedRed: 0.18, green: 0.76, blue: 0.38, alpha: 1.0),
            isEnabled: true,
            pointSize: 14.0
        ) { [weak self] in
            self?.finishCapture(mode: .copyToClipboard)
        }

        // 4. 二级样式栏（当任意标注工具激活或选中已有标注时展开：粗细圆点 + 8色圆点；马赛克模式下仅显示大小不显示颜色）
        if showStyleBar {
            let isMosaicActive: Bool = {
                if activeTool == .mosaic { return true }
                if let selId = selectedAnnotationId,
                   let ann = annotations.first(where: { $0.id == selId }),
                   ann.tool == .mosaic {
                    return true
                }
                return false
            }()

            let styleBarW: CGFloat = isMosaicActive ? 104 : 340
            let styleX: CGFloat = {
                if isMosaicActive {
                    // 马赛克模式下居中对齐在工具栏马赛克按钮下方，体验更直观
                    let mosaicBtnCenterX = mainRect.minX + 6 + 5 * 28 + 13 // 第6个按钮(索引5)中心
                    let mx = mosaicBtnCenterX - styleBarW / 2
                    return min(max(mx, 12), bounds.width - styleBarW - 12)
                } else {
                    return min(max(mainRect.minX, 12), bounds.width - styleBarW - 12)
                }
            }()
            let styleY = mainRect.maxY + 6
            let styleRect = CGRect(x: styleX, y: styleY, width: styleBarW, height: styleBarH)
            let styleBg = NSBezierPath(roundedRect: styleRect, xRadius: 7, yRadius: 7)
            NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.17, alpha: 0.95).setFill()
            styleBg.fill()

            let borderColor = isMosaicActive
                ? ScreenshotPalette.themeAccent.withAlphaComponent(0.65)
                : ScreenshotPalette.colors[selectedColorIndex].color.withAlphaComponent(0.7)
            borderColor.setStroke()
            styleBg.lineWidth = 1.2
            styleBg.stroke()

            var sx = styleRect.minX + 8
            let sy = styleRect.minY + 4

            // 线宽/马赛克大小选择（绘制细/中/粗实心圆点）
            let dotSizes: [CGFloat] = [4, 7, 10]
            for (idx, item) in ScreenshotPalette.strokeWidths.enumerated() {
                let wRect = CGRect(x: sx, y: sy, width: 24, height: 24)
                let isSel = (selectedWidthIndex == idx)
                let isHov = (hoveredToolbarId == "width_\(idx)")
                let path = NSBezierPath(roundedRect: wRect, xRadius: 4, yRadius: 4)
                if isSel {
                    ScreenshotPalette.themeAccent.withAlphaComponent(0.35).setFill()
                    path.fill()
                    ScreenshotPalette.themeAccent.setStroke()
                    path.lineWidth = 1.0
                    path.stroke()
                } else if isHov {
                    NSColor.white.withAlphaComponent(0.12).setFill()
                    path.fill()
                }

                let dotRadius = dotSizes[min(idx, dotSizes.count - 1)] / 2
                let dotRect = CGRect(
                    x: wRect.midX - dotRadius,
                    y: wRect.midY - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                (isSel ? ScreenshotPalette.themeAccent : NSColor.white).setFill()
                NSBezierPath(ovalIn: dotRect).fill()

                let tipText = isMosaicActive ? "马赛克大小: \(item.label)" : "画笔粗细: \(item.label)"
                toolbarHits.append(ToolbarHitItem(id: "width_\(idx)", rect: wRect, tooltip: tipText) { [weak self] in
                    guard let self else { return }
                    self.selectedWidthIndex = idx
                    let newWidth = ScreenshotPalette.strokeWidths[idx].width
                    if let selId = self.selectedAnnotationId,
                       let annIdx = self.annotations.firstIndex(where: { $0.id == selId }),
                       self.annotations[annIdx].lineWidth != newWidth {
                        self.recordUndoSnapshot()
                        self.annotations[annIdx].lineWidth = newWidth
                        self.annotations[annIdx].customFontSize = nil
                    }
                    if let tf = self.textInputField {
                        let fontSize = ScreenshotRenderer.textFontSize(for: newWidth)
                        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                        self.resizeActiveTextFieldToFit()
                    }
                    self.needsDisplay = true
                })
                sx += 28
            }

            // 非马赛克模式下才显示分割线与 8 色调色盘圆点
            if !isMosaicActive {
                drawToolbarDivider(at: sx + 2, minY: styleRect.minY + 5, height: 22)
                sx += 10

                // 8 色调色盘圆点
                for (idx, item) in ScreenshotPalette.colors.enumerated() {
                    let cRect = CGRect(x: sx, y: styleRect.minY + 6, width: 20, height: 20)
                    let circle = NSBezierPath(ovalIn: cRect.insetBy(dx: 2, dy: 2))
                    item.color.setFill()
                    circle.fill()

                    if selectedColorIndex == idx {
                        NSColor.white.setStroke()
                        let ring = NSBezierPath(ovalIn: cRect)
                        ring.lineWidth = 2.2
                        ring.stroke()
                    } else {
                        NSColor.white.withAlphaComponent(0.35).setStroke()
                        circle.lineWidth = 1.0
                        circle.stroke()
                    }

                    toolbarHits.append(ToolbarHitItem(id: "color_\(idx)", rect: cRect, tooltip: "颜色: \(item.name)") { [weak self] in
                        guard let self else { return }
                        self.selectedColorIndex = idx
                        let newColor = ScreenshotPalette.colors[idx].color
                        if let selId = self.selectedAnnotationId,
                           let annIdx = self.annotations.firstIndex(where: { $0.id == selId }) {
                            self.recordUndoSnapshot()
                            self.annotations[annIdx].color = newColor
                        }
                        if let tf = self.textInputField {
                            tf.textColor = newColor
                        }
                        self.needsDisplay = true
                    })
                    sx += 24
                }
            }
        }

        // 5. 悬停气泡 Tooltip
        if let hoveredId = hoveredToolbarId, let hit = toolbarHits.first(where: { $0.id == hoveredId }), !hit.tooltip.isEmpty {
            drawToolbarTooltip(hit.tooltip, forButtonRect: hit.rect, toolbarRect: mainRect)
        }
    }

    private func drawToolbarIconButton(
        id: String,
        rect: CGRect,
        symbolName: String,
        tooltip: String,
        isSelected: Bool,
        accentColor: NSColor,
        isEnabled: Bool,
        pointSize: CGFloat = 13.0,
        action: @escaping () -> Void
    ) {
        let isHovered = (hoveredToolbarId == id)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isSelected {
            accentColor.withAlphaComponent(0.88).setFill()
            path.fill()
        } else if isHovered && isEnabled {
            NSColor.white.withAlphaComponent(0.18).setFill()
            path.fill()
        }

        let symbolColor: NSColor
        if !isEnabled {
            symbolColor = NSColor.white.withAlphaComponent(0.25)
        } else if isSelected {
            symbolColor = .white
        } else if isHovered {
            symbolColor = accentColor
        } else {
            symbolColor = .white
        }

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [symbolColor]))
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?.withSymbolConfiguration(config) {
            let size = img.size
            let drawRect = CGRect(
                x: (rect.midX - size.width / 2).rounded(),
                y: (rect.midY - size.height / 2).rounded(),
                width: size.width,
                height: size.height
            )
            img.draw(in: drawRect)
        }

        if isEnabled {
            toolbarHits.append(ToolbarHitItem(id: id, rect: rect, tooltip: tooltip, action: action))
        }
    }

    private func drawToolbarTooltip(_ text: String, forButtonRect btnRect: CGRect, toolbarRect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 8
        let padY: CGFloat = 4
        let tipW = textSize.width + padX * 2
        let tipH = textSize.height + padY * 2

        var tipX = btnRect.midX - tipW / 2
        tipX = min(max(tipX, 8), bounds.width - tipW - 8)

        var tipY = toolbarRect.minY - tipH - 6
        if tipY < 8 {
            tipY = toolbarRect.maxY + 6
        }

        let tipRect = CGRect(x: tipX, y: tipY, width: tipW, height: tipH)
        let tipPath = NSBezierPath(roundedRect: tipRect, xRadius: 5, yRadius: 5)
        NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 0.96).setFill()
        tipPath.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        tipPath.lineWidth = 1.0
        tipPath.stroke()

        (text as NSString).draw(at: CGPoint(x: tipX + padX, y: tipY + padY), withAttributes: attrs)
    }

    private func drawToolbarDivider(at x: CGFloat, minY: CGFloat, height: CGFloat) {
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.0
        p.move(to: CGPoint(x: x, y: minY))
        p.line(to: CGPoint(x: x, y: minY + height))
        p.stroke()
    }
}

// MARK: - 交互事件（鼠标拖拽选区/边角微调/标注绘制、键盘快捷键）

extension ScreenshotCanvasView {
    enum FinishMode {
        case copyToClipboard
        case pinToScreen
        case pinWithOCR
        case pinWithTranslate
        case saveFile
    }

    func handleAt(_ pt: CGPoint) -> ResizeHandle? {
        guard let sel = selectionRect else { return nil }
        for handle in ResizeHandle.allCases {
            let hp = handle.point(in: sel)
            if hypot(pt.x - hp.x, pt.y - hp.y) <= 12.0 {
                return handle
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        mouseLocationInView = pt

        let prevHandle = hoveredHandle
        let prevToolbar = hoveredToolbarId
        let prevAnnId = hoveredAnnotationId
        let prevAnnHandle = hoveredAnnotationHandle

        hoveredToolbarId = toolbarHits.first(where: { $0.rect.contains(pt) })?.id
        if hoveredToolbarId != nil {
            hoveredHandle = nil
            hoveredAnnotationId = nil
            hoveredAnnotationHandle = nil
            NSCursor.pointingHand.set()
        } else if let h = handleAt(pt) {
            hoveredHandle = h
            hoveredAnnotationId = nil
            hoveredAnnotationHandle = nil
            NSCursor.crosshair.set()
        } else if let selId = selectedAnnotationId,
                  let ann = annotations.first(where: { $0.id == selId }),
                  let aHandle = ann.hitResizeHandle(at: pt) {
            hoveredHandle = nil
            hoveredAnnotationId = selId
            hoveredAnnotationHandle = aHandle
            NSCursor.crosshair.set()
        } else if let hitAnn = annotations.reversed().first(where: { $0.hitTest(pt, isSelected: $0.id == selectedAnnotationId) }) {
            hoveredHandle = nil
            hoveredAnnotationId = hitAnn.id
            hoveredAnnotationHandle = nil
            NSCursor.openHand.set()
        } else if let sel = selectionRect, sel.contains(pt) {
            hoveredHandle = nil
            hoveredAnnotationId = nil
            hoveredAnnotationHandle = nil
            if activeTool != nil {
                NSCursor.crosshair.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            hoveredHandle = nil
            hoveredAnnotationId = nil
            hoveredAnnotationHandle = nil
            NSCursor.crosshair.set()
        }

        if selectionRect == nil ||
           prevHandle != hoveredHandle ||
           prevToolbar != hoveredToolbarId ||
           prevAnnId != hoveredAnnotationId ||
           prevAnnHandle != hoveredAnnotationHandle ||
           hoveredHandle != nil {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        mouseLocationInView = pt

        // 语言菜单展开时优先处理或关闭
        if isShowingLanguageMenu {
            if let hit = toolbarHits.first(where: { $0.id.hasPrefix("lang_") && $0.rect.contains(pt) }) {
                hit.action()
                return
            }
            isShowingLanguageMenu = false
            needsDisplay = true
            if let hit = toolbarHits.first(where: { $0.rect.contains(pt) }) {
                hit.action()
                return
            }
            return
        }

        // 1. 先检查是否点击在浮动工具栏按钮上
        if let hit = toolbarHits.first(where: { $0.rect.contains(pt) }) {
            hit.action()
            return
        }

        // 若正在输入文字标注，点击别处先提交文字
        if textInputField != nil {
            commitPendingTextIfNeeded()
            needsDisplay = true
        }

        // 双击检查：若双击已有文字标注，直接进入编辑模式；若双击空白选区，直接完成截图
        if event.clickCount == 2 {
            if let textAnn = annotations.reversed().first(where: { $0.tool == .text && $0.hitTest(pt, isSelected: true) }) {
                beginTextInput(at: textAnn.startPoint, existing: textAnn)
                return
            }
            if let sel = selectionRect, sel.contains(pt), activeTool == nil, hoveredAnnotationId == nil {
                finishCapture(mode: .copyToClipboard)
                return
            }
        }

        // 2. 检查是否按在选区 8 个边角/边缘控制点上（即使处于标注模式也允许随时微调选区边角）
        if let handle = handleAt(pt), let sel = selectionRect {
            dragMode = .resizingSelection(handle: handle, initialRect: sel)
            needsDisplay = true
            return
        }

        // 3. 检查是否按在已选中标注的尺寸/端点控制点上
        if let selId = selectedAnnotationId,
           let ann = annotations.first(where: { $0.id == selId }),
           let aHandle = ann.hitResizeHandle(at: pt) {
            dragMode = .resizingAnnotation(
                id: selId,
                handle: aHandle,
                initialAnnotation: ann,
                preResizeSnapshot: annotations
            )
            needsDisplay = true
            return
        }

        // 4. 检查是否按在已有标注本体上（优先支持拖拽移动位置）
        if let hitAnn = annotations.reversed().first(where: { $0.hitTest(pt, isSelected: $0.id == selectedAnnotationId) }) {
            selectedAnnotationId = hitAnn.id
            syncPaletteToAnnotation(hitAnn)
            dragMode = .movingAnnotation(
                id: hitAnn.id,
                startMouse: pt,
                initialAnnotation: hitAnn,
                preMoveSnapshot: annotations
            )
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        // 5. 点击在选区内部非标注空白区域
        if let sel = selectionRect, sel.contains(pt) {
            selectedAnnotationId = nil
            if let tool = activeTool {
                if tool == .text {
                    beginTextInput(at: pt)
                    return
                }
                let color = ScreenshotPalette.colors[selectedColorIndex].color
                let width = ScreenshotPalette.strokeWidths[selectedWidthIndex].width
                currentAnnotation = ScreenshotAnnotation(
                    tool: tool,
                    color: color,
                    lineWidth: width,
                    startPoint: pt,
                    endPoint: pt,
                    points: [pt]
                )
                dragMode = .drawingAnnotation
            } else {
                dragMode = .movingSelection(startMouse: pt, initialRect: sel)
                NSCursor.closedHand.set()
            }
            needsDisplay = true
            return
        }

        // 6. 点击在选区外部（或尚未创建选区）：仅在无选区时重新拉框，有选区但未点工具时可重新框选
        selectedAnnotationId = nil
        if selectionRect == nil || (activeTool == nil && annotations.isEmpty) {
            selectionRect = CGRect(origin: pt, size: .zero)
            dragMode = .creatingSelection(start: pt)
            showTranslationInPlace = false
            inPlaceTranslationData = nil
            inPlaceTranslationError = nil
            isTranslatingInPlace = false
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let rawPt = convert(event.locationInWindow, from: nil)
        let pt = CGPoint(
            x: min(max(rawPt.x, 0), bounds.width),
            y: min(max(rawPt.y, 0), bounds.height)
        )
        mouseLocationInView = pt
        let isShift = event.modifierFlags.contains(.shift)

        switch dragMode {
        case .none:
            break

        case .creatingSelection(let start):
            selectionRect = ScreenshotRenderer.normalizedRect(from: start, to: pt, shiftSquare: isShift)
            needsDisplay = true

        case .resizingSelection(let handle, let initial):
            selectionRect = resizedRect(initial: initial, handle: handle, to: pt)
            needsDisplay = true

        case .movingSelection(let startMouse, let initialRect):
            var dx = pt.x - startMouse.x
            var dy = pt.y - startMouse.y
            dx = min(max(dx, -initialRect.minX), bounds.width - initialRect.maxX)
            dy = min(max(dy, -initialRect.minY), bounds.height - initialRect.maxY)
            if let currentSel = selectionRect {
                let stepDx = (initialRect.minX + dx) - currentSel.minX
                let stepDy = (initialRect.minY + dy) - currentSel.minY
                selectionRect = initialRect.offsetBy(dx: dx, dy: dy)
                for i in annotations.indices {
                    annotations[i].translate(dx: stepDx, dy: stepDy)
                }
            }
            needsDisplay = true

        case .drawingAnnotation:
            guard var current = currentAnnotation, let sel = selectionRect else { break }
            let clamped = CGPoint(
                x: min(max(pt.x, sel.minX), sel.maxX),
                y: min(max(pt.y, sel.minY), sel.maxY)
            )
            if isShift && (current.tool == .rectangle || current.tool == .ellipse) {
                let sq = ScreenshotRenderer.normalizedRect(from: current.startPoint, to: clamped, shiftSquare: true)
                current.endPoint = CGPoint(
                    x: clamped.x >= current.startPoint.x ? sq.maxX : sq.minX,
                    y: clamped.y >= current.startPoint.y ? sq.maxY : sq.minY
                )
            } else {
                current.endPoint = clamped
            }
            if current.tool == .pen || current.tool == .highlighter || current.tool == .mosaic {
                if let last = current.points.last, hypot(clamped.x - last.x, clamped.y - last.y) >= 2.0 {
                    current.points.append(clamped)
                }
            }
            currentAnnotation = current
            needsDisplay = true

        case .movingAnnotation(let id, let startMouse, let initial, _):
            guard let idx = annotations.firstIndex(where: { $0.id == id }) else { break }
            let dx = pt.x - startMouse.x
            let dy = pt.y - startMouse.y
            var updated = initial
            updated.translate(dx: dx, dy: dy)
            annotations[idx] = updated
            needsDisplay = true

        case .resizingAnnotation(let id, let handle, let initial, _):
            guard let idx = annotations.firstIndex(where: { $0.id == id }) else { break }
            var updated = initial

            if initial.tool == .arrow {
                if handle == .arrowStart {
                    updated.startPoint = pt
                } else if handle == .arrowEnd {
                    updated.endPoint = pt
                }
                annotations[idx] = updated
                needsDisplay = true
                break
            }

            // 对矩形、圆框、画笔、荧光笔、马赛克、文字：统一通过包围盒 8 方向拉伸调整大小
            let initialRect = initial.boundingRect
            let newRect = resizedRect(initial: initialRect, handle: handle, to: pt)

            switch initial.tool {
            case .rectangle, .ellipse:
                updated.startPoint = CGPoint(x: newRect.minX, y: newRect.minY)
                updated.endPoint = CGPoint(x: newRect.maxX, y: newRect.maxY)

            case .pen, .highlighter, .mosaic:
                let origW = max(initialRect.width, 1.0)
                let origH = max(initialRect.height, 1.0)
                updated.points = initial.points.map { p in
                    let u = (p.x - initialRect.minX) / origW
                    let v = (p.y - initialRect.minY) / origH
                    return CGPoint(
                        x: newRect.minX + u * newRect.width,
                        y: newRect.minY + v * newRect.height
                    )
                }
                if let first = updated.points.first { updated.startPoint = first }
                if let last = updated.points.last { updated.endPoint = last }
                // 笔刷粗细随整体缩放比例适度微调
                let scaleRatio = hypot(newRect.width, newRect.height) / max(hypot(origW, origH), 1.0)
                let clampedScale = max(0.4, min(scaleRatio, 2.5))
                updated.lineWidth = max(1.5, min(initial.lineWidth * clampedScale, 28.0))

            case .text:
                let baseFontSize = initial.customFontSize ?? ScreenshotRenderer.textFontSize(for: initial.lineWidth)
                let origW = max(initialRect.width, 12.0)
                let origH = max(initialRect.height, 12.0)
                let scaleW = newRect.width / origW
                let scaleH = newRect.height / origH
                let scale: CGFloat
                switch handle {
                case .top, .bottom:
                    scale = scaleH
                case .left, .right:
                    scale = scaleW
                default:
                    scale = (scaleW + scaleH) / 2.0
                }
                let newFontSize = max(11.0, min(baseFontSize * scale, 120.0))
                updated.customFontSize = newFontSize
                updated.startPoint = CGPoint(x: newRect.minX, y: newRect.minY)
                updated.endPoint = CGPoint(x: newRect.minX, y: newRect.minY)

            case .arrow:
                break
            }

            annotations[idx] = updated
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let rawPt = convert(event.locationInWindow, from: nil)
        let pt = CGPoint(
            x: min(max(rawPt.x, 0), bounds.width),
            y: min(max(rawPt.y, 0), bounds.height)
        )

        switch dragMode {
        case .creatingSelection:
            if let sel = selectionRect, (sel.width < 6 || sel.height < 6) {
                selectionRect = nil
            }
        case .drawingAnnotation:
            if let finished = currentAnnotation {
                if finished.isValidVisibleAnnotation {
                    recordUndoSnapshot()
                    annotations.append(finished)
                    selectedAnnotationId = finished.id
                }
                currentAnnotation = nil
            }
        case .movingAnnotation(let id, let startMouse, _, let preMoveSnapshot):
            if hypot(pt.x - startMouse.x, pt.y - startMouse.y) >= 2.0 {
                undoStack.append(preMoveSnapshot)
                if undoStack.count > 50 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            _ = id
        case .resizingAnnotation(let id, _, let initial, let preResizeSnapshot):
            if let current = annotations.first(where: { $0.id == id }) {
                let changed = (current.startPoint != initial.startPoint ||
                               current.endPoint != initial.endPoint ||
                               current.points != initial.points ||
                               current.customFontSize != initial.customFontSize ||
                               current.lineWidth != initial.lineWidth)
                if changed {
                    undoStack.append(preResizeSnapshot)
                    if undoStack.count > 50 { undoStack.removeFirst() }
                    redoStack.removeAll()
                }
            }
        default:
            break
        }
        dragMode = .none
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        commitPendingTextIfNeeded()
        if selectedAnnotationId != nil {
            selectedAnnotationId = nil
            needsDisplay = true
        } else if selectionRect != nil && !annotations.isEmpty {
            performUndo()
        } else if selectionRect != nil {
            selectionRect = nil
            activeTool = nil
            needsDisplay = true
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if textInputField != nil {
            if event.keyCode == 53 { // Esc
                cancelPendingText()
            } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                commitPendingTextIfNeeded()
            }
            return
        }

        // 若当前有选中的已放置标注：按 Delete / Backspace 删除该标注；按 Esc 取消选中
        if let selId = selectedAnnotationId {
            if event.keyCode == 51 || event.keyCode == 117 { // Backspace / Delete
                recordUndoSnapshot()
                annotations.removeAll(where: { $0.id == selId })
                selectedAnnotationId = nil
                hoveredAnnotationId = nil
                hoveredAnnotationHandle = nil
                needsDisplay = true
                return
            } else if event.keyCode == 53 { // Esc
                selectedAnnotationId = nil
                needsDisplay = true
                return
            }
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return / Enter → 完成并复制到剪贴板
            finishCapture(mode: .copyToClipboard)
        case 99: // F3 → 直接贴到屏幕
            finishCapture(mode: .pinToScreen)
        case 123, 124, 125, 126: // 方向键微调选区（或微调已选中标注）
            if let selId = selectedAnnotationId, let idx = annotations.firstIndex(where: { $0.id == selId }) {
                let dx: CGFloat = (event.keyCode == 123) ? -1 : (event.keyCode == 124 ? 1 : 0)
                let dy: CGFloat = (event.keyCode == 126) ? -1 : (event.keyCode == 125 ? 1 : 0)
                recordUndoSnapshot()
                annotations[idx].translate(dx: dx, dy: dy)
                needsDisplay = true
            } else {
                nudgeSelection(keyCode: event.keyCode, resize: flags.contains(.shift))
            }
        default:
            if flags == .command && chars == "z" {
                performUndo()
            } else if flags == [.command, .shift] && chars == "z" {
                performRedo()
            } else if flags == .command && chars == "c" {
                finishCapture(mode: .copyToClipboard)
            } else if flags == .command && chars == "s" {
                finishCapture(mode: .saveFile)
            } else if flags.isEmpty && chars == "c" {
                // 按 C 复制当前光标处的 HEX 色值（同款 Snipaste 快捷键）
                let info = sampler.colorAt(viewPoint: magnifierFocusPoint)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(info.hex, forType: .string)
                ClipboardMonitor.markInternalWrite(info.hex)
                toastMessage = "色值 \(info.hex) 已复制到剪贴板"
                needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    self?.toastMessage = nil
                    self?.needsDisplay = true
                }
            } else if flags.isEmpty && chars == "t" {
                finishCapture(mode: .pinToScreen)
            } else if flags.isEmpty && chars == "l" {
                startScrollCapture()
            }
        }
    }

    private func resizedRect(initial: CGRect, handle: ResizeHandle, to pt: CGPoint) -> CGRect {
        var minX = initial.minX
        var maxX = initial.maxX
        var minY = initial.minY
        var maxY = initial.maxY

        switch handle {
        case .topLeft:
            minX = pt.x; minY = pt.y
        case .top:
            minY = pt.y
        case .topRight:
            maxX = pt.x; minY = pt.y
        case .right:
            maxX = pt.x
        case .bottomRight:
            maxX = pt.x; maxY = pt.y
        case .bottom:
            maxY = pt.y
        case .bottomLeft:
            minX = pt.x; maxY = pt.y
        case .left:
            minX = pt.x
        }

        let x1 = min(minX, maxX)
        let x2 = max(minX, maxX)
        let y1 = min(minY, maxY)
        let y2 = max(minY, maxY)
        return CGRect(x: x1, y: y1, width: max(x2 - x1, 4), height: max(y2 - y1, 4))
    }

    private func resizedRect(initial: CGRect, handle: AnnotationHandle, to pt: CGPoint) -> CGRect {
        var minX = initial.minX
        var maxX = initial.maxX
        var minY = initial.minY
        var maxY = initial.maxY

        switch handle {
        case .topLeft:
            minX = pt.x; minY = pt.y
        case .top:
            minY = pt.y
        case .topRight:
            maxX = pt.x; minY = pt.y
        case .right:
            maxX = pt.x
        case .bottomRight:
            maxX = pt.x; maxY = pt.y
        case .bottom:
            maxY = pt.y
        case .bottomLeft:
            minX = pt.x; maxY = pt.y
        case .left:
            minX = pt.x
        case .arrowStart, .arrowEnd:
            break
        }

        let x1 = min(minX, maxX)
        let x2 = max(minX, maxX)
        let y1 = min(minY, maxY)
        let y2 = max(minY, maxY)
        return CGRect(x: x1, y: y1, width: max(x2 - x1, 6), height: max(y2 - y1, 6))
    }

    private func nudgeSelection(keyCode: UInt16, resize: Bool) {
        guard var sel = selectionRect else { return }
        let dx: CGFloat = (keyCode == 123) ? -1 : (keyCode == 124 ? 1 : 0)
        let dy: CGFloat = (keyCode == 126) ? -1 : (keyCode == 125 ? 1 : 0)
        if resize {
            sel.size.width = max(8, min(sel.width + dx, bounds.width - sel.minX))
            sel.size.height = max(8, min(sel.height + dy, bounds.height - sel.minY))
        } else {
            sel.origin.x = min(max(sel.origin.x + dx, 0), bounds.width - sel.width)
            sel.origin.y = min(max(sel.origin.y + dy, 0), bounds.height - sel.height)
        }
        selectionRect = sel
        needsDisplay = true
    }

    func performUndo() {
        commitPendingTextIfNeeded()
        guard let previous = undoStack.popLast() else {
            if !annotations.isEmpty {
                redoStack.append(annotations)
                annotations.removeAll()
                selectedAnnotationId = nil
                needsDisplay = true
            }
            return
        }
        redoStack.append(annotations)
        annotations = previous
        if let selId = selectedAnnotationId, !annotations.contains(where: { $0.id == selId }) {
            selectedAnnotationId = nil
        }
        needsDisplay = true
    }

    func performRedo() {
        commitPendingTextIfNeeded()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        if let selId = selectedAnnotationId, !annotations.contains(where: { $0.id == selId }) {
            selectedAnnotationId = nil
        }
        needsDisplay = true
    }

    // MARK: - 文字标注内联输入（支持原位编辑、拖动、自适应扩展与样式联动）

    private func beginTextInput(at pt: CGPoint, existing: ScreenshotAnnotation? = nil) {
        commitPendingTextIfNeeded()
        textInputOrigin = pt
        editingTextAnnotation = existing
        preEditTextSnapshot = annotations

        let width: CGFloat
        let color: NSColor
        let initialText: String

        if let existing {
            width = existing.lineWidth
            color = existing.color
            initialText = existing.text
            annotations.removeAll(where: { $0.id == existing.id })
            syncPaletteToAnnotation(existing)
        } else {
            width = ScreenshotPalette.strokeWidths[selectedWidthIndex].width
            color = ScreenshotPalette.colors[selectedColorIndex].color
            initialText = ""
        }

        let fontSize = existing?.customFontSize ?? ScreenshotRenderer.textFontSize(for: width)
        let tf = NSTextField(frame: NSRect(x: pt.x, y: pt.y - 4, width: 220, height: fontSize + 14))
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        tf.textColor = color
        tf.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 0.85)
        tf.drawsBackground = true
        tf.isBordered = false
        tf.wantsLayer = true
        tf.layer?.cornerRadius = 5
        tf.layer?.borderWidth = 1.0
        tf.layer?.borderColor = ScreenshotPalette.themeAccent.withAlphaComponent(0.65).cgColor
        tf.focusRingType = .none
        tf.placeholderString = "输入批注文字 (回车确认)..."
        tf.stringValue = initialText
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textInputField = tf
        resizeActiveTextFieldToFit()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitPendingTextIfNeeded()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelPendingText()
            return true
        }
        return false
    }

    func commitPendingTextIfNeeded() {
        guard let tf = textInputField else { return }
        let str = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tf.removeFromSuperview()
        textInputField = nil
        window?.makeFirstResponder(self)

        if !str.isEmpty {
            if let preSnap = preEditTextSnapshot {
                undoStack.append(preSnap)
                if undoStack.count > 50 { undoStack.removeFirst() }
                redoStack.removeAll()
            } else {
                recordUndoSnapshot()
            }
            let color = ScreenshotPalette.colors[selectedColorIndex].color
            let width = ScreenshotPalette.strokeWidths[selectedWidthIndex].width
            let annId = editingTextAnnotation?.id ?? UUID()
            let newAnn = ScreenshotAnnotation(
                id: annId,
                tool: .text,
                color: color,
                lineWidth: width,
                startPoint: textInputOrigin,
                endPoint: textInputOrigin,
                text: str,
                customFontSize: editingTextAnnotation?.customFontSize
            )
            annotations.append(newAnn)
            selectedAnnotationId = annId
        } else if let _ = editingTextAnnotation {
            if let preSnap = preEditTextSnapshot {
                undoStack.append(preSnap)
                if undoStack.count > 50 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            selectedAnnotationId = nil
        }
        editingTextAnnotation = nil
        preEditTextSnapshot = nil
        needsDisplay = true
    }

    private func cancelPendingText() {
        textInputField?.removeFromSuperview()
        textInputField = nil
        if let original = editingTextAnnotation {
            annotations.append(original)
            selectedAnnotationId = original.id
        }
        editingTextAnnotation = nil
        preEditTextSnapshot = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - 完成输出

    func finishCapture(mode: FinishMode) {
        commitPendingTextIfNeeded()
        let sel = selectionRect ?? bounds

        let inPlaceInfo: ScreenshotRenderer.InPlaceTranslationInfo? = {
            if showTranslationInPlace, let d = inPlaceTranslationData {
                return ScreenshotRenderer.InPlaceTranslationInfo(
                    text: d.translatedText,
                    dominantBgColor: d.dominantBgColor,
                    textColor: d.textColor
                )
            }
            return nil
        }()

        guard sel.width >= 4, sel.height >= 4,
              let finalImage = ScreenshotRenderer.renderFinalImage(
                  selectionRect: sel,
                  sampler: sampler,
                  annotations: annotations,
                  inPlaceTranslation: inPlaceInfo
              ) else {
            onCancel?()
            return
        }

        // 如果处于原地翻译状态，将翻译后的文本字符串也存入剪贴板文本
        if showTranslationInPlace, let transText = inPlaceTranslationData?.translatedText, !transText.isEmpty {
            let pb = NSPasteboard.general
            pb.setString(transText, forType: .string)
            ClipboardMonitor.markInternalWrite(transText)
        }

        // 将翻转视图选区坐标转换为屏幕 AppKit 坐标（左下角原点）用于贴图原位落点
        let screenFrame = window?.screen?.frame ?? NSScreen.main?.frame ?? bounds
        let appKitRect = CGRect(
            x: screenFrame.minX + sel.minX,
            y: screenFrame.maxY - sel.maxY,
            width: sel.width,
            height: sel.height
        )

        switch mode {
        case .copyToClipboard:
            onFinishCopy?(finalImage, appKitRect)
        case .pinToScreen:
            onFinishPin?(finalImage, appKitRect, false, false)
        case .pinWithOCR:
            onFinishPin?(finalImage, appKitRect, true, false)
        case .pinWithTranslate:
            onFinishPin?(finalImage, appKitRect, false, true)
        case .saveFile:
            onFinishSave?(finalImage)
        }
    }

    func startScrollCapture() {
        commitPendingTextIfNeeded()
        let sel = selectionRect ?? bounds
        guard sel.width >= 40, sel.height >= 40 else { return }
        let screenFrame = window?.screen?.frame ?? NSScreen.main?.frame ?? bounds
        let appKitRect = CGRect(
            x: screenFrame.minX + sel.minX,
            y: screenFrame.maxY - sel.maxY,
            width: sel.width,
            height: sel.height
        )
        DispatchQueue.main.async { [weak self] in
            self?.onStartScrollCapture?(appKitRect)
        }
    }
}

// MARK: - 原地截图翻译实现

extension ScreenshotCanvasView {
    func drawLanguageMenu(anchorRect: CGRect) {
        let languages = TranslationService.commonTargetLanguages
        let rowsPerCol = 12
        let colW: CGFloat = 142
        let colGap: CGFloat = 8
        let itemH: CGFloat = 26
        let headerH: CGFloat = 28
        let menuW: CGFloat = colW * 2 + colGap + 12
        let totalH = headerH + 6 + CGFloat(rowsPerCol) * itemH + 8

        var menuX = anchorRect.midX - menuW / 2
        menuX = min(max(menuX, 10), bounds.width - menuW - 10)

        var menuY = anchorRect.maxY + 8
        if menuY + totalH > bounds.height - 12 {
            menuY = max(anchorRect.minY - totalH - 8, 12)
        }

        let menuRect = CGRect(x: menuX, y: menuY, width: menuW, height: totalH)

        // 绘制外层立体阴影与背景
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 10
        shadow.set()

        let bgPath = NSBezierPath(roundedRect: menuRect, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.19, alpha: 0.98).setFill()
        bgPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 边框
        ScreenshotPalette.themeAccent.withAlphaComponent(0.4).setStroke()
        bgPath.lineWidth = 1.0
        bgPath.stroke()

        // 标题区："将内容翻译为（24 种语言）"
        let titleRect = CGRect(x: menuX + 12, y: menuY + 7, width: menuW - 24, height: 16)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.65, alpha: 1.0)
        ]
        ("将内容翻译为（24 种常用世界语言）" as NSString).draw(in: titleRect, withAttributes: titleAttrs)

        // 顶部水平分割线
        let divY = menuY + headerH
        let div = NSBezierPath()
        div.move(to: CGPoint(x: menuX + 8, y: divY))
        div.line(to: CGPoint(x: menuX + menuW - 8, y: divY))
        NSColor.white.withAlphaComponent(0.12).setStroke()
        div.lineWidth = 0.8
        div.stroke()

        // 两列中间的竖直分割线
        let midX = menuX + 6 + colW + colGap / 2
        let vDiv = NSBezierPath()
        vDiv.move(to: CGPoint(x: midX, y: divY + 6))
        vDiv.line(to: CGPoint(x: midX, y: menuRect.maxY - 8))
        NSColor.white.withAlphaComponent(0.08).setStroke()
        vDiv.lineWidth = 0.8
        vDiv.stroke()

        // 各语言行（分左右两列）
        for (idx, lang) in languages.enumerated() {
            let col = idx < rowsPerCol ? 0 : 1
            let row = idx % rowsPerCol

            let itemX = menuX + 6 + CGFloat(col) * (colW + colGap)
            let itemY = divY + 4 + CGFloat(row) * itemH
            let itemRect = CGRect(x: itemX, y: itemY, width: colW, height: itemH)

            let isHovered = (hoveredToolbarId == "lang_\(lang.code)")
            let isSelected = (lang.code == selectedTargetLanguage.code)

            if isHovered {
                let hoverPath = NSBezierPath(roundedRect: itemRect, xRadius: 5, yRadius: 5)
                NSColor.white.withAlphaComponent(0.14).setFill()
                hoverPath.fill()
            }

            // 语言名称文本
            let textRect = CGRect(x: itemRect.minX + 6, y: itemRect.minY + 4, width: itemRect.width - 24, height: 18)
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .semibold : .regular),
                .foregroundColor: isSelected ? NSColor.white : NSColor(white: 0.9, alpha: 1.0)
            ]
            (lang.name as NSString).draw(in: textRect, withAttributes: textAttrs)

            // 选中对勾 ✓
            if isSelected {
                let checkRect = CGRect(x: itemRect.maxX - 16, y: itemRect.minY + 6, width: 12, height: 12)
                if let checkIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
                    let conf = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold).applying(.init(hierarchicalColor: NSColor.systemBlue))
                    let configured = checkIcon.withSymbolConfiguration(conf) ?? checkIcon
                    configured.draw(in: checkRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }

            // 注册点击事件
            toolbarHits.append(ToolbarHitItem(id: "lang_\(lang.code)", rect: itemRect, tooltip: "") { [weak self] in
                guard let self else { return }
                self.selectedTargetLanguage = lang
                self.isShowingLanguageMenu = false
                self.performInPlaceTranslation(forceLanguage: lang)
                self.needsDisplay = true
            })
        }
    }

    func performInPlaceTranslation(forceLanguage: TranslationService.TargetLanguage? = nil) {
        guard let sel = selectionRect, sel.width >= 10, sel.height >= 10 else { return }

        commitPendingTextIfNeeded()
        let reqId = UUID()
        activeTranslationRequestId = reqId
        isTranslatingInPlace = true
        inPlaceTranslationError = nil
        needsDisplay = true

        let targetLang = forceLanguage ?? selectedTargetLanguage

        // 强行超时保底：最多等待 4.5 秒，绝不允许无限期停在“正在翻译中”！
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            guard let self, self.activeTranslationRequestId == reqId, self.isTranslatingInPlace else { return }
            self.isTranslatingInPlace = false
            self.inPlaceTranslationError = "翻译超时或暂无法识别该语言内容"
            self.needsDisplay = true
            self.scheduleErrorAutoDismiss()
        }

        // 1. 从当前采样底图裁剪选区图片用于 OCR
        guard let cropImage = ScreenshotRenderer.renderFinalImage(
            selectionRect: sel,
            sampler: sampler,
            annotations: []
        ) else {
            isTranslatingInPlace = false
            inPlaceTranslationError = "无法获取选区图像"
            needsDisplay = true
            scheduleErrorAutoDismiss()
            return
        }

        // 2. 检测背景色与文字色
        let (bgColor, textColor) = detectDominantColors(for: sel)

        // 3. 执行 OCR 识别文本
        ScreenshotManager.recognizeLines(from: cropImage) { [weak self] lines in
            guard let self, self.activeTranslationRequestId == reqId else { return }
            let joinedText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joinedText.isEmpty else {
                self.isTranslatingInPlace = false
                self.inPlaceTranslationError = "未检测到可翻译文本"
                self.needsDisplay = true
                self.scheduleErrorAutoDismiss()
                return
            }

            // 4. 自动检测源语言
            let (sourceCode, _) = TranslationService.shared.detectLanguage(for: joinedText)

            let resolvedTarget: TranslationService.TargetLanguage
            if forceLanguage != nil {
                resolvedTarget = targetLang
            } else if sourceCode.hasPrefix("zh") && targetLang.code.hasPrefix("zh") {
                resolvedTarget = TranslationService.commonTargetLanguages.first(where: { $0.id == "en" }) ?? targetLang
                self.selectedTargetLanguage = resolvedTarget
            } else {
                resolvedTarget = targetLang
            }

            // 5. 异步调用轻量级 Google/Native 翻译
            Task {
                do {
                    let translated = try await TranslationService.shared.translate(
                        text: joinedText,
                        sourceLang: sourceCode,
                        targetCode: resolvedTarget.code
                    )

                    await MainActor.run {
                        guard self.activeTranslationRequestId == reqId else { return }
                        self.isTranslatingInPlace = false
                        self.inPlaceTranslationData = InPlaceTranslationData(
                            sourceText: joinedText,
                            translatedText: translated,
                            targetLanguage: resolvedTarget,
                            dominantBgColor: bgColor,
                            textColor: textColor
                        )
                        self.showTranslationInPlace = true
                        self.needsDisplay = true
                    }
                } catch {
                    await MainActor.run {
                        guard self.activeTranslationRequestId == reqId else { return }
                        self.isTranslatingInPlace = false
                        self.inPlaceTranslationError = error.localizedDescription
                        self.needsDisplay = true
                        self.scheduleErrorAutoDismiss()
                    }
                }
            }
        }
    }

    private func detectDominantColors(for sel: CGRect) -> (bgColor: NSColor, textColor: NSColor) {
        let samplePoints: [CGPoint] = [
            CGPoint(x: sel.minX + 4, y: sel.minY + 4),
            CGPoint(x: sel.maxX - 4, y: sel.minY + 4),
            CGPoint(x: sel.minX + 4, y: sel.maxY - 4),
            CGPoint(x: sel.maxX - 4, y: sel.maxY - 4),
            CGPoint(x: sel.midX, y: sel.minY + 4),
            CGPoint(x: sel.midX, y: sel.maxY - 4),
        ]

        var totalLum: CGFloat = 0
        var totalR: CGFloat = 0, totalG: CGFloat = 0, totalB: CGFloat = 0
        var validCount: CGFloat = 0

        for pt in samplePoints {
            let color = sampler.colorAt(viewPoint: pt).nsColor
            if let rgb = color.usingColorSpace(.deviceRGB) {
                let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                totalLum += lum
                totalR += rgb.redComponent
                totalG += rgb.greenComponent
                totalB += rgb.blueComponent
                validCount += 1
            }
        }

        let avgLum = validCount > 0 ? totalLum / validCount : 1.0
        let isLight = avgLum > 0.55

        if isLight {
            let avgR = validCount > 0 ? totalR / validCount : 1.0
            let avgG = validCount > 0 ? totalG / validCount : 1.0
            let avgB = validCount > 0 ? totalB / validCount : 1.0
            let bg = NSColor(calibratedRed: avgR, green: avgG, blue: avgB, alpha: 1.0)
            let text = NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.16, alpha: 1.0)
            return (bg, text)
        } else {
            let avgR = validCount > 0 ? totalR / validCount : 0.12
            let avgG = validCount > 0 ? totalG / validCount : 0.12
            let avgB = validCount > 0 ? totalB / validCount : 0.12
            let bg = NSColor(calibratedRed: avgR, green: avgG, blue: avgB, alpha: 1.0)
            let text = NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1.0)
            return (bg, text)
        }
    }

    func drawInPlaceTranslation(_ data: InPlaceTranslationData, in sel: CGRect) {
        data.dominantBgColor.setFill()
        let bgPath = NSBezierPath(rect: sel)
        bgPath.fill()

        ScreenshotRenderer.drawInPlaceTranslationText(data.translatedText, textColor: data.textColor, in: sel)
    }

    func drawTranslatingOverlay(in sel: CGRect) {
        let badgeW: CGFloat = 140
        let badgeH: CGFloat = 34
        let badgeRect = CGRect(x: sel.midX - badgeW / 2, y: sel.midY - badgeH / 2, width: badgeW, height: badgeH)
        let path = NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.17, alpha: 0.92).setFill()
        path.fill()
        ScreenshotPalette.themeAccent.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.0
        path.stroke()

        let text = "正在翻译中..."
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textPt = CGPoint(x: badgeRect.midX - textSize.width / 2 + 8, y: badgeRect.midY - textSize.height / 2)
        (text as NSString).draw(at: textPt, withAttributes: attrs)

        if let icon = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            let configured = icon.withSymbolConfiguration(conf) ?? icon
            let iconRect = CGRect(x: textPt.x - 18, y: badgeRect.midY - 6, width: 12, height: 12)
            configured.draw(in: iconRect)
        }
    }

    func drawTranslationErrorOverlay(_ msg: String, in sel: CGRect) {
        let badgeW: CGFloat = min(max(CGFloat(msg.count) * 13 + 52, 170), sel.width)
        let badgeH: CGFloat = 34
        let badgeRect = CGRect(x: sel.midX - badgeW / 2, y: sel.midY - badgeH / 2, width: badgeW, height: badgeH)
        let path = NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.18, green: 0.08, blue: 0.08, alpha: 0.94).setFill()
        path.fill()
        NSColor.systemRed.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1.0
        path.stroke()

        let text = msg
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textPt = CGPoint(x: badgeRect.midX - textSize.width / 2 + 7, y: badgeRect.midY - textSize.height / 2)
        (text as NSString).draw(at: textPt, withAttributes: attrs)

        if let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(hierarchicalColor: NSColor.systemOrange))
            let configured = icon.withSymbolConfiguration(conf) ?? icon
            let iconRect = CGRect(x: textPt.x - 17, y: badgeRect.midY - 6, width: 12, height: 12)
            configured.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // 注册点击关闭提示
        toolbarHits.append(ToolbarHitItem(id: "act_dismiss_error", rect: badgeRect, tooltip: "") { [weak self] in
            guard let self else { return }
            self.inPlaceTranslationError = nil
            self.needsDisplay = true
        })
    }

    private func scheduleErrorAutoDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { [weak self] in
            guard let self, self.inPlaceTranslationError != nil else { return }
            self.inPlaceTranslationError = nil
            self.needsDisplay = true
        }
    }
}
