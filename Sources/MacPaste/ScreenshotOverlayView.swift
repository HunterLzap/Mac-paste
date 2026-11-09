import AppKit
import CoreGraphics

// MARK: - 全屏截图交互窗口

final class ScreenshotOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 全屏截图画布视图（isFlipped = true，左上角为原点）

final class ScreenshotCanvasView: NSView, NSTextFieldDelegate {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    let sampler: ScreenBitmapSampler
    let hasScreenPermission: Bool

    var onFinishCopy: ((NSImage, CGRect) -> Void)?
    var onFinishPin: ((NSImage, CGRect, Bool) -> Void)?
    var onFinishSave: ((NSImage) -> Void)?
    var onStartScrollCapture: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    // 选区与交互状态
    private(set) var selectionRect: CGRect?
    private var activeTool: ScreenshotTool?
    private var selectedColorIndex: Int = 0
    private var selectedWidthIndex: Int = 1
    private var annotations: [ScreenshotAnnotation] = []
    private var redoStack: [ScreenshotAnnotation] = []
    private var currentAnnotation: ScreenshotAnnotation?

    private enum DragMode {
        case none
        case creatingSelection(start: CGPoint)
        case resizingSelection(handle: ResizeHandle, initialRect: CGRect)
        case movingSelection(startMouse: CGPoint, initialRect: CGRect)
        case drawingAnnotation
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
            for item in annotations {
                ScreenshotRenderer.drawAnnotation(item, sampler: sampler)
            }
            if let current = currentAnnotation {
                ScreenshotRenderer.drawAnnotation(current, sampler: sampler)
            }
            NSGraphicsContext.restoreGraphicsState()

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
        case .movingSelection, .drawingAnnotation:
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
}

// MARK: - 选区浮动工具栏与鼠标/键盘事件处理

extension ScreenshotCanvasView {
    func drawFloatingToolbar(for sel: CGRect) {
        let mainBarW: CGFloat = 480
        let mainBarH: CGFloat = 36
        let styleBarH: CGFloat = 32
        let totalH: CGFloat = activeTool != nil ? (mainBarH + styleBarH + 6) : mainBarH

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
            isEnabled: !annotations.isEmpty
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
            self.redoStack = self.annotations
            self.annotations.removeAll()
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

        // 4. 二级样式栏（当任意标注工具激活时展开：粗细圆点 + 8色圆点）
        if activeTool != nil {
            let styleBarW: CGFloat = 340
            let styleX = min(max(mainRect.minX, 12), bounds.width - styleBarW - 12)
            let styleY = mainRect.maxY + 6
            let styleRect = CGRect(x: styleX, y: styleY, width: styleBarW, height: styleBarH)
            let styleBg = NSBezierPath(roundedRect: styleRect, xRadius: 7, yRadius: 7)
            NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.17, alpha: 0.95).setFill()
            styleBg.fill()
            ScreenshotPalette.colors[selectedColorIndex].color.withAlphaComponent(0.7).setStroke()
            styleBg.lineWidth = 1.2
            styleBg.stroke()

            var sx = styleRect.minX + 8
            let sy = styleRect.minY + 4

            // 线宽选择（绘制细/中/粗实心圆点）
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

                toolbarHits.append(ToolbarHitItem(id: "width_\(idx)", rect: wRect, tooltip: "画笔粗细: \(item.label)") { [weak self] in
                    self?.selectedWidthIndex = idx
                    self?.needsDisplay = true
                })
                sx += 28
            }

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
                    self?.selectedColorIndex = idx
                    self?.needsDisplay = true
                })
                sx += 24
            }
        }

        // 5. 悬停气泡 Tooltip
        if let hoveredId = hoveredToolbarId, let hit = toolbarHits.first(where: { $0.id == hoveredId }) {
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

        hoveredToolbarId = toolbarHits.first(where: { $0.rect.contains(pt) })?.id
        if hoveredToolbarId != nil {
            hoveredHandle = nil
            NSCursor.pointingHand.set()
        } else if let h = handleAt(pt) {
            hoveredHandle = h
            NSCursor.crosshair.set()
        } else if let sel = selectionRect, sel.contains(pt) {
            hoveredHandle = nil
            if activeTool != nil {
                NSCursor.crosshair.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            hoveredHandle = nil
            NSCursor.crosshair.set()
        }

        if selectionRect == nil || prevHandle != hoveredHandle || prevToolbar != hoveredToolbarId || hoveredHandle != nil {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        mouseLocationInView = pt

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

        // 双击选区内部 → 直接完成截图（等同 Snipaste 双击复制）
        if event.clickCount == 2, let sel = selectionRect, sel.contains(pt), activeTool == nil {
            finishCapture(mode: .copyToClipboard)
            return
        }

        // 2. 检查是否按在 8 个边角/边缘控制点上（即使处于标注模式也允许随时微调选区边角）
        if let handle = handleAt(pt), let sel = selectionRect {
            dragMode = .resizingSelection(handle: handle, initialRect: sel)
            needsDisplay = true
            return
        }

        // 3. 若已有选区且点击在选区内部
        if let sel = selectionRect, sel.contains(pt) {
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

        // 4. 点击在选区外部（或尚未创建选区）：仅在无选区时重新拉框，有选区但未点工具时可重新框选
        if selectionRect == nil || (activeTool == nil && annotations.isEmpty) {
            selectionRect = CGRect(origin: pt, size: .zero)
            dragMode = .creatingSelection(start: pt)
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
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .creatingSelection:
            if let sel = selectionRect, (sel.width < 6 || sel.height < 6) {
                selectionRect = nil
            }
        case .drawingAnnotation:
            if let finished = currentAnnotation {
                if finished.isValidVisibleAnnotation {
                    annotations.append(finished)
                    redoStack.removeAll()
                }
                currentAnnotation = nil
            }
        default:
            break
        }
        dragMode = .none
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        commitPendingTextIfNeeded()
        if selectionRect != nil && !annotations.isEmpty {
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

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return / Enter → 完成并复制到剪贴板
            finishCapture(mode: .copyToClipboard)
        case 99: // F3 → 直接贴到屏幕
            finishCapture(mode: .pinToScreen)
        case 123, 124, 125, 126: // 方向键 1px 微调选区
            nudgeSelection(keyCode: event.keyCode, resize: flags.contains(.shift))
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
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        needsDisplay = true
    }

    func performRedo() {
        commitPendingTextIfNeeded()
        guard let next = redoStack.popLast() else { return }
        annotations.append(next)
        needsDisplay = true
    }

    // MARK: - 文字标注内联输入

    private func beginTextInput(at pt: CGPoint) {
        commitPendingTextIfNeeded()
        textInputOrigin = pt
        let width = ScreenshotPalette.strokeWidths[selectedWidthIndex].width
        let fontSize: CGFloat = width <= 3 ? 15 : (width <= 5 ? 19 : 25)
        let color = ScreenshotPalette.colors[selectedColorIndex].color

        let tf = NSTextField(frame: NSRect(x: pt.x, y: pt.y - 4, width: 220, height: fontSize + 14))
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        tf.textColor = color
        tf.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        tf.drawsBackground = true
        tf.isBordered = true
        tf.focusRingType = .exterior
        tf.placeholderString = "输入批注文字 (回车确认)..."
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textInputField = tf
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
        guard !str.isEmpty else { return }
        let color = ScreenshotPalette.colors[selectedColorIndex].color
        let width = ScreenshotPalette.strokeWidths[selectedWidthIndex].width
        annotations.append(
            ScreenshotAnnotation(
                tool: .text,
                color: color,
                lineWidth: width,
                startPoint: textInputOrigin,
                endPoint: textInputOrigin,
                text: str
            )
        )
        redoStack.removeAll()
        needsDisplay = true
    }

    private func cancelPendingText() {
        textInputField?.removeFromSuperview()
        textInputField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - 完成输出

    func finishCapture(mode: FinishMode) {
        commitPendingTextIfNeeded()
        let sel = selectionRect ?? bounds
        guard sel.width >= 4, sel.height >= 4,
              let finalImage = ScreenshotRenderer.renderFinalImage(
                  selectionRect: sel,
                  sampler: sampler,
                  annotations: annotations
              ) else {
            onCancel?()
            return
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
            onFinishPin?(finalImage, appKitRect, false)
        case .pinWithOCR:
            onFinishPin?(finalImage, appKitRect, true)
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
