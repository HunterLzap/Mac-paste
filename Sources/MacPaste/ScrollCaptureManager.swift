import AppKit
import CoreGraphics
import Vision
import ApplicationServices

// MARK: - 临时诊断日志（写文件，绕开菜单栏 App 的 NSLog 丢失问题）
fileprivate func scdbg(_ format: String, _ args: CVarArg...) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    let line = "\(ts) " + String(format: format, arguments: args) + "\n"
    let url = URL(fileURLWithPath: "/tmp/macpaste_scdbg.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8) ?? Data())
        try? h.close()
    } else {
        try? (line.data(using: .utf8) ?? Data()).write(to: url)
    }
}

fileprivate func frameSignature(_ cg: CGImage) -> UInt64 {
    guard let dp = cg.dataProvider, let cf = dp.data else { return 0 }
    let data = cf as Data
    var h: UInt64 = 1469598103934665603
    let step = max(1, data.count / 4096)
    data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        var i = 0
        while i < p.count {
            h = (h ^ UInt64(p[i])) &* 1099511628211
            i += step
        }
    }
    return h
}

// MARK: - 滚动长截图高精度拼接引擎（Apple Vision 亚像素配准 + 残差双重检验 + 实时逆向回滚）

final class ScrollImageStitcher {
    let width: Int
    let frameHeight: Int
    let scaleFactor: CGFloat

    /// 已拼接的长图像素数据（RGBA 32位，width * totalPixelHeight * 4）
    private var accumulatedData: Data

    /// 上一帧完整 CGImage 与提取的像素缓存，用于 Vision 配准及重叠区域残差校验
    private var prevCG: CGImage
    private var prevPixels: [UInt8]
    private var consecutiveNoMatch: Int = 0
    /// 当前参考帧顶行在已拼接长图中的行号（锚点），用于定位、避免来回滚动重复
    private var anchorTop: Int = 0

    private(set) var stitchedFrameCount: Int = 0
    let maxPixelHeight: Int = 24_000

    enum StitchResult {
        case firstFrame
        case appended(addedPixels: Int)
        case noMovement
        case rejected
        case reachedLimit
    }

    init(firstFrame: CGImage, scaleFactor: CGFloat) {
        self.width = firstFrame.width
        self.frameHeight = firstFrame.height
        self.scaleFactor = max(scaleFactor, 1.0)
        self.prevCG = firstFrame

        let pixels = Self.extractRGBA(from: firstFrame, width: width, height: frameHeight)
        self.accumulatedData = Data(pixels)
        self.prevPixels = pixels
        self.stitchedFrameCount = 1
    }

    var totalPixelHeight: Int {
        guard width > 0 else { return 0 }
        return accumulatedData.count / (width * 4)
    }

    /// 追加新帧：不依赖 Vision 位移正负号，改用真实像素重叠投票判定方向。
    /// 位移大小取 |ty|，分别按“新内容在下方(追加底部)”和“新内容在上方(前插顶部)”算重叠残差，
    /// 取残差更小且达标的那个方向；对不齐则跳过本帧保留锚点，连续多次失败才重锚定恢复。
    func appendFrame(_ currCG: CGImage) -> StitchResult {
        guard currCG.width == width, currCG.height == frameHeight else {
            return .noMovement
        }
        let currPixels = Self.extractRGBA(from: currCG, width: width, height: frameHeight)

        // 1. Vision 仅用于估计位移“大小”，方向由下面的像素重叠决定，避免正负号踩错。
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: prevCG, options: [:])
        let handler = VNImageRequestHandler(cgImage: currCG, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return recoverOrSkip(currCG: currCG, currPixels: currPixels, reason: "visionThrew")
        }
        guard let obs = req.results?.first as? VNImageTranslationAlignmentObservation else {
            return recoverOrSkip(currCG: currCG, currPixels: currPixels, reason: "noObs")
        }
        let tx = obs.alignmentTransform.tx
        let ty = obs.alignmentTransform.ty
        scdbg("[SCDBG] vision tx=%.2f ty=%.2f conf=%.2f", tx, ty, obs.confidence)

        let rowBytes = width * 4
        if !tx.isFinite || !ty.isFinite || abs(tx) > 12.0 {
            return recoverOrSkip(currCG: currCG, currPixels: currPixels, reason: "badTxOrNaN")
        }
        let magnitude = abs(ty)
        if magnitude < 1.0 {
            consecutiveNoMatch = 0
            return .noMovement
        }

        // 2. 候选位移大小（考虑亚像素四舍五入），两个方向都试，选像素残差最小者。
        let center = Int(round(magnitude))
        var candidates = Set<Int>()
        for d in [center - 1, center, center + 1] where d >= 1 && d < frameHeight {
            candidates.insert(d)
        }
        guard !candidates.isEmpty else {
            return recoverOrSkip(currCG: currCG, currPixels: currPixels, reason: "jumpTooBig")
        }

        var bestD = 0
        var bestAppend = true
        var bestMad = Double.infinity
        for d in candidates {
            // 新内容在下方：prev[d...] 对齐 curr[0...] → 追加 curr 底部 d 行
            let madDown = overlapDifference(prev: prevPixels, curr: currPixels, delta: d)
            if madDown < bestMad { bestMad = madDown; bestD = d; bestAppend = true }
            // 新内容在上方：prev[0...] 对齐 curr[d...] → 前插 curr 顶部 d 行
            let madUp = overlapDifference(prev: prevPixels, curr: currPixels, delta: -d)
            if madUp < bestMad { bestMad = madUp; bestD = d; bestAppend = false }
        }

        let threshold = 25.0
        guard bestD > 0, bestMad <= threshold else {
            return recoverOrSkip(currCG: currCG, currPixels: currPixels, reason: "noOverlap mad=\(String(format: "%.1f", bestMad))")
        }

        // 3. 锚点模型：定位当前帧在长图中的位置，向上退回已拍区域不重复，向下超出才补新行。
        let oldH = totalPixelHeight
        var added = 0
        if bestAppend {
            // 内容上移：当前帧在文档中下移 bestD 行（锚点增大）
            let newAnchor = anchorTop + bestD
            let newBottom = newAnchor + frameHeight
            if newBottom > oldH {
                let addRows = newBottom - oldH
                if oldH + addRows > maxPixelHeight { return .reachedLimit }
                let sliceStart = (frameHeight - addRows) * rowBytes
                currPixels.withUnsafeBytes { rawBuf in
                    if let ptr = rawBuf.baseAddress?.advanced(by: sliceStart) {
                        accumulatedData.append(ptr.assumingMemoryBound(to: UInt8.self), count: addRows * rowBytes)
                    }
                }
                added = addRows
            }
            anchorTop = newAnchor
        } else {
            // 内容下移：当前帧在文档中上移 bestD 行（锚点减小）
            let newAnchor = anchorTop - bestD
            if newAnchor < 0 {
                let prependRows = -newAnchor
                if oldH + prependRows > maxPixelHeight { return .reachedLimit }
                var head = Data()
                currPixels.withUnsafeBytes { rawBuf in
                    if let ptr = rawBuf.baseAddress {
                        head.append(ptr.assumingMemoryBound(to: UInt8.self), count: prependRows * rowBytes)
                    }
                }
                head.append(accumulatedData)
                accumulatedData = head
                added = prependRows
                anchorTop = 0
            } else {
                // 退回到已拼接区域内部：只移动锚点，不改变长图（消除重复）
                anchorTop = newAnchor
            }
        }

        prevCG = currCG
        prevPixels = currPixels
        consecutiveNoMatch = 0
        if added > 0 { stitchedFrameCount += 1 }
        scdbg("[SCDBG] step d=\(bestD) dir=\(bestAppend ? "down" : "up") mad=\(String(format: "%.1f", bestMad)) anchor=\(anchorTop) added=\(added) total=\(totalPixelHeight)")
        return added > 0 ? .appended(addedPixels: added) : .noMovement
    }

    /// 连续对不齐时不要死锁：累计 N 次失配后把参考帧重锚定到当前帧
    /// （可能留下缺口，但能从死锁中恢复，继续滚动）。
    private func recoverOrSkip(currCG: CGImage, currPixels: [UInt8], reason: String) -> StitchResult {
        consecutiveNoMatch += 1
        if consecutiveNoMatch >= 6, accumulatedData.count / (width * 4) >= frameHeight {
            prevCG = currCG
            prevPixels = currPixels
            consecutiveNoMatch = 0
            scdbg("[SCDBG] reanchor reason=\(reason) total=\(totalPixelHeight)")
        }
        return .noMovement
    }

    /// 双向重叠区域残差校验：对上一帧与当前帧的理论重叠部分进行多点采样，杜绝段落重复与文字错位
    private func verifyOverlap(prev: [UInt8], curr: [UInt8], delta: Int) -> Bool {
        return overlapDifference(prev: prev, curr: curr, delta: delta) <= 22.0
    }

    private func overlapDifference(prev: [UInt8], curr: [UInt8], delta: Int) -> Double {
        let rowBytes = width * 4
        let overlapH = frameHeight - abs(delta)
        guard overlapH >= 8 else { return .infinity }

        let prevStartRow = delta > 0 ? delta : 0
        let currStartRow = delta > 0 ? 0 : -delta

        // 在重叠区域均匀采样至多 28 行
        let rowStep = max(1, overlapH / 28)
        var diffSum: Int = 0
        var pixelCount: Int = 0

        // 左右两端适当内缩 5%~6%，避开右侧滚动条滑块与边缘边框可能产生的局部干扰
        let xStart = min(max(0, width / 20), max(0, width - 1))
        let xEnd = max(xStart + 1, width * 19 / 20)
        let colStep = max(1, (xEnd - xStart) / 45)

        for r in stride(from: 0, to: overlapH, by: rowStep) {
            let prevRowOffset = (prevStartRow + r) * rowBytes
            let currRowOffset = (currStartRow + r) * rowBytes

            for x in stride(from: xStart, to: xEnd, by: colStep) {
                let pIdx = prevRowOffset + x * 4
                let cIdx = currRowOffset + x * 4
                let dr = abs(Int(prev[pIdx]) - Int(curr[cIdx]))
                let dg = abs(Int(prev[pIdx + 1]) - Int(curr[cIdx + 1]))
                let db = abs(Int(prev[pIdx + 2]) - Int(curr[cIdx + 2]))
                diffSum += (dr + dg + db)
                pixelCount += 3
            }
        }

        guard pixelCount > 0 else { return .infinity }
        return Double(diffSum) / Double(pixelCount)
    }

    /// 生成当前拼接完成的长图 NSImage（利用 Data 原生免拷贝桥接 CGDataProvider，高性能 < 3ms）
    func renderCurrentImage() -> NSImage? {
        let totalH = totalPixelHeight
        guard width > 0, totalH > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: accumulatedData as CFData),
              let cgImg = CGImage(
                  width: width,
                  height: totalH,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }

        let ptSize = NSSize(
            width: CGFloat(width) / scaleFactor,
            height: CGFloat(totalH) / scaleFactor
        )
        return NSImage(cgImage: cgImg, size: ptSize)
    }

    static func extractRGBA(from cgImage: CGImage, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        if let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }
}

// MARK: - 选区四边镂空高亮线（中间零窗口遮挡，滚轮与触控板 100% 直达底层网页/应用！）

final class ScrollBorderOverlay {
    private var borderPanels: [NSPanel] = []

    init(captureRect: CGRect) {
        let borderW: CGFloat = 2.5
        let outer = captureRect.insetBy(dx: -borderW, dy: -borderW)

        let topFrame = CGRect(x: outer.minX, y: outer.maxY - borderW, width: outer.width, height: borderW)
        let bottomFrame = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: borderW)
        let leftFrame = CGRect(x: outer.minX, y: outer.minY, width: borderW, height: outer.height)
        let rightFrame = CGRect(x: outer.maxX - borderW, y: outer.minY, width: borderW, height: outer.height)

        for frame in [topFrame, bottomFrame, leftFrame, rightFrame] {
            let p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.85)
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.orderFrontRegardless()
            borderPanels.append(p)
        }
    }

    func close() {
        borderPanels.forEach { $0.orderOut(nil) }
        borderPanels.removeAll()
    }
}

// MARK: - 极简右侧实时缩略图卡片（纯视觉反馈，100% 鼠标完全穿透，无任何杂乱按钮）

final class ScrollPreviewCardWindow: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

final class ScrollPreviewCardView: NSView {
    var previewImage: NSImage? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil // 绝对穿透
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clear(bounds)

        let bgPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.92).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()

        if let img = previewImage, img.size.width > 1, img.size.height > 1 {
            let inner = bounds.insetBy(dx: 6, dy: 6)
            let scale = min(inner.width / img.size.width, inner.height / img.size.height)
            let drawW = img.size.width * scale
            let drawH = img.size.height * scale
            let drawRect = CGRect(
                x: inner.midX - drawW / 2,
                y: inner.maxY - drawH,
                width: drawW,
                height: drawH
            )
            img.draw(in: drawRect)
        }
        ctx.restoreGState()
    }
}

// MARK: - 极简清爽悬浮工具条（高度 34pt，纯图标，少字，无冗余按钮组）

final class ScrollToolbarWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = true
    }
}

final class ScrollToolbarView: NSView {
    /// 关键修复：重写 acceptsFirstMouse，确保初次点击立即响应，彻底消除“需要点击两次”问题
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    var sizeText: String = "0 × 0" { didSet { needsDisplay = true } }
    var isAutoScrolling: Bool = false { didSet { needsDisplay = true } }

    var onToggleAutoScroll: (() -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?

    private var hoveredId: String?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func itemLayouts() -> (sizeRect: CGRect, autoBtn: CGRect, pinBtn: CGRect, saveBtn: CGRect, cancelBtn: CGRect, doneBtn: CGRect) {
        let sizeR = CGRect(x: 10, y: 5, width: 84, height: 24)
        let autoR = CGRect(x: 100, y: 4, width: 54, height: 26)
        let pinR = CGRect(x: 160, y: 4, width: 24, height: 26)
        let saveR = CGRect(x: 187, y: 4, width: 24, height: 26)
        let cancelR = CGRect(x: 214, y: 4, width: 24, height: 26)
        let doneR = CGRect(x: 241, y: 4, width: 26, height: 26)
        return (sizeR, autoR, pinR, saveR, cancelR, doneR)
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let l = itemLayouts()
        let hit: String?
        if l.autoBtn.contains(pt) { hit = "auto" }
        else if l.pinBtn.contains(pt) { hit = "pin" }
        else if l.saveBtn.contains(pt) { hit = "save" }
        else if l.cancelBtn.contains(pt) { hit = "cancel" }
        else if l.doneBtn.contains(pt) { hit = "done" }
        else { hit = nil }

        if hit != hoveredId {
            hoveredId = hit
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredId != nil {
            hoveredId = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let l = itemLayouts()
        if l.autoBtn.contains(pt) {
            onToggleAutoScroll?()
        } else if l.pinBtn.contains(pt) {
            onPin?()
        } else if l.saveBtn.contains(pt) {
            onSave?()
        } else if l.cancelBtn.contains(pt) {
            onCancel?()
        } else if l.doneBtn.contains(pt) {
            onFinish?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clear(bounds)

        let bgPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.15, alpha: 0.95).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()

        let l = itemLayouts()

        // 1. 尺寸显示
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ]
        let sSize = (sizeText as NSString).size(withAttributes: sizeAttrs)
        (sizeText as NSString).draw(
            at: NSPoint(x: l.sizeRect.minX + max(0, (l.sizeRect.width - sSize.width) / 2),
                        y: l.sizeRect.minY + (l.sizeRect.height - sSize.height) / 2),
            withAttributes: sizeAttrs
        )

        // 竖线分隔符
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: 96, y: 7))
        ctx.addLine(to: CGPoint(x: 96, y: 27))
        ctx.strokePath()

        // 2. 自动滚动按钮
        let isAutoHovered = (hoveredId == "auto")
        let autoBg = CGPath(roundedRect: l.autoBtn, cornerWidth: 5, cornerHeight: 5, transform: nil)
        if isAutoScrolling {
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(isAutoHovered ? 0.35 : 0.22).cgColor)
        } else {
            ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(isAutoHovered ? 0.32 : 0.16).cgColor)
        }
        ctx.addPath(autoBg)
        ctx.fillPath()

        let autoTitle = isAutoScrolling ? "⏹ 停止" : "▶ 自动"
        let autoColor: NSColor = isAutoScrolling ? .systemOrange : .systemCyan
        let autoAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: autoColor
        ]
        let atSize = (autoTitle as NSString).size(withAttributes: autoAttrs)
        (autoTitle as NSString).draw(
            at: NSPoint(x: l.autoBtn.midX - atSize.width / 2, y: l.autoBtn.midY - atSize.height / 2),
            withAttributes: autoAttrs
        )

        // 3. 纯图标按钮：贴图 F3、保存、取消、完成
        drawIconButton(rect: l.pinBtn, symbolName: "pin.fill", id: "pin", tint: .white, ptSize: 11)
        drawIconButton(rect: l.saveBtn, symbolName: "square.and.arrow.down", id: "save", tint: .white, ptSize: 11)
        drawIconButton(rect: l.cancelBtn, symbolName: "xmark", id: "cancel", tint: .systemRed, ptSize: 11)
        drawIconButton(rect: l.doneBtn, symbolName: "checkmark", id: "done", tint: .systemGreen, ptSize: 12)

        // Tooltip 悬浮提示
        if let h = hoveredId {
            let tipText: String?
            let tipRect: CGRect
            switch h {
            case "auto": tipText = isAutoScrolling ? "停止自动滚动 (空格)" : "自动缓慢向下滚动 (空格)"; tipRect = l.autoBtn
            case "pin": tipText = "贴图 (F3)"; tipRect = l.pinBtn
            case "save": tipText = "保存为图片"; tipRect = l.saveBtn
            case "cancel": tipText = "取消 (Esc)"; tipRect = l.cancelBtn
            case "done": tipText = "完成复制 (Enter)"; tipRect = l.doneBtn
            default: tipText = nil; tipRect = .zero
            }
            if let t = tipText {
                drawTooltip(t, for: tipRect)
            }
        }

        ctx.restoreGState()
    }

    private func drawIconButton(rect: CGRect, symbolName: String, id: String, tint: NSColor, ptSize: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isHov = (hoveredId == id)
        if isHov {
            let p = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.addPath(p)
            ctx.fillPath()
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: ptSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = sym.size
            let r = CGRect(
                x: (rect.midX - s.width / 2).rounded(),
                y: (rect.midY - s.height / 2).rounded(),
                width: s.width,
                height: s.height
            )
            sym.draw(in: r)
        }
    }

    private func drawTooltip(_ text: String, for anchorRect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let tipW = s.width + padX * 2
        let tipH = s.height + padY * 2
        let tipX = min(max(anchorRect.midX - tipW / 2, 4), bounds.width - tipW - 4)
        let tipY = bounds.height + 4
        let tipRect = CGRect(x: tipX, y: tipY, width: tipW, height: tipH)

        let path = NSBezierPath(roundedRect: tipRect, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.12, alpha: 0.95).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        (text as NSString).draw(at: NSPoint(x: tipX + padX, y: tipY + padY), withAttributes: attrs)
    }
}

// MARK: - 滚动长截图协调总控

final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    private var borderOverlay: ScrollBorderOverlay?
    private var previewWindow: ScrollPreviewCardWindow?
    private var previewView: ScrollPreviewCardView?
    private var toolbarWindow: ScrollToolbarWindow?
    private var toolbarView: ScrollToolbarView?

    private var stitcher: ScrollImageStitcher?
    private var sampleTimer: Timer?
    private var autoScrollTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var appKitCaptureRect: CGRect = .zero
    private var cgCaptureRect: CGRect = .zero
    private var isAutoScrolling: Bool = false
    private var unchangedTickCount: Int = 0
    private var dbgAutoTick: Int = 0
    private var lastFrameSig: UInt64 = 0
    /// 定向投递滚轮事件的目标 App PID（避免用全局事件把鼠标光标拽住）
    private var targetPID: pid_t = 0

    private var onFinishCopy: ((NSImage) -> Void)?
    private var onFinishPin: ((NSImage) -> Void)?
    private var onFinishSave: ((NSImage) -> Void)?

    /// 当前是否正处于长截图模式中
    var isActive: Bool {
        return stitcher != nil
    }

    private init() {}

    /// 启动滚动截图模式
    func start(
        appKitRect: CGRect,
        targetApplication: NSRunningApplication? = nil,
        onFinishCopy: @escaping (NSImage) -> Void,
        onFinishPin: @escaping (NSImage) -> Void,
        onFinishSave: @escaping (NSImage) -> Void
    ) {
        stopCleanup()

        let primaryH = NSScreen.screens.first?.frame.height ?? 1080
        let cgRect = CGRect(
            x: appKitRect.origin.x,
            y: primaryH - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )

        self.appKitCaptureRect = appKitRect
        self.cgCaptureRect = cgRect
        self.onFinishCopy = onFinishCopy
        self.onFinishPin = onFinishPin
        self.onFinishSave = onFinishSave
        self.isAutoScrolling = false
        self.unchangedTickCount = 0

        // 截图面板曾激活 MacPaste；恢复启动截图前的应用，工具条不再抢焦点。
        if let targetApplication, targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApplication.activate(options: [.activateIgnoringOtherApps])
        }
        self.targetPID = targetApplication?.processIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if self.targetPID == ProcessInfo.processInfo.processIdentifier { self.targetPID = 0 }
        guard let firstCG = captureFrame() else {
            scdbg("[SCDBG] start FAILED firstCG=nil cgRect=\(cgCaptureRect) axTrusted=\(AXIsProcessTrusted()) target=\(targetApplication?.localizedName ?? "nil")")
            return
        }

        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) }) ?? NSScreen.main
        let scaleFactor = targetScreen?.backingScaleFactor ?? 2.0
        let newStitcher = ScrollImageStitcher(firstFrame: firstCG, scaleFactor: scaleFactor)
        self.stitcher = newStitcher
        scdbg("[SCDBG] start OK firstCG=\(firstCG.width)x\(firstCG.height) scale=\(scaleFactor) axTrusted=\(AXIsProcessTrusted()) target=\(targetApplication?.localizedName ?? "nil") cgRect=\(cgCaptureRect)")

        // 1. 创建四边镂空高亮线（中间零窗口遮挡，保证触控板/鼠标直接控制下方应用）
        self.borderOverlay = ScrollBorderOverlay(captureRect: appKitRect)

        let screenFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // 2. 右侧实时卡片预览窗（纯视觉反馈，100% 鼠标完全穿透，随滚动实时生长与回退）
        let prevW: CGFloat = 130
        let prevH: CGFloat = 190
        var prevX = appKitRect.maxX + 12
        if prevX + prevW > screenFrame.maxX - 8 {
            prevX = appKitRect.minX - prevW - 12
        }
        let prevY = min(max(appKitRect.midY - prevH / 2, screenFrame.minY + 10), screenFrame.maxY - prevH - 10)

        let pWin = ScrollPreviewCardWindow(frame: CGRect(x: prevX, y: prevY, width: prevW, height: prevH))
        let pView = ScrollPreviewCardView(frame: NSRect(x: 0, y: 0, width: prevW, height: prevH))
        pView.previewImage = newStitcher.renderCurrentImage()
        pWin.contentView = pView
        pWin.orderFrontRegardless()
        self.previewWindow = pWin
        self.previewView = pView

        // 3. 极简清爽悬浮工具条（高度 34pt，纯图标，少字）
        let barW: CGFloat = 276
        let barH: CGFloat = 34
        var barX = appKitRect.maxX - barW
        barX = min(max(barX, screenFrame.minX + 8), screenFrame.maxX - barW - 8)
        var barY = appKitRect.minY - barH - 8
        if barY < screenFrame.minY + 6 {
            barY = appKitRect.maxY + 8
        }

        let tbWin = ScrollToolbarWindow(frame: CGRect(x: barX, y: barY, width: barW, height: barH))
        let tbView = ScrollToolbarView(frame: NSRect(x: 0, y: 0, width: barW, height: barH))
        tbView.sizeText = "\(newStitcher.width) × \(newStitcher.totalPixelHeight)"
        tbView.isAutoScrolling = false

        tbView.onToggleAutoScroll = { [weak self] in self?.toggleAutoScroll() }
        tbView.onPin = { [weak self] in self?.finishPin() }
        tbView.onSave = { [weak self] in self?.finishSave() }
        tbView.onCancel = { [weak self] in self?.stopCleanup() }
        tbView.onFinish = { [weak self] in self?.finishCopy() }

        tbWin.contentView = tbView
        tbWin.orderFrontRegardless()
        self.toolbarWindow = tbWin
        self.toolbarView = tbView

        // 4. 键盘快捷键监听（Enter 复制，F3 贴图，Esc 取消，空格 自动滚动）
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil
            }
            return event
        }

        // 5. 定时采样比对：每 0.10 秒使用 Vision 配准对比一次当前屏幕
        let sTimer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.sampleAndStitchFrame()
        }
        RunLoop.main.add(sTimer, forMode: .common)
        self.sampleTimer = sTimer
    }

    func finishCopy() {
        finishWithAction(.copy)
    }

    func finishPin() {
        finishWithAction(.pin)
    }

    func finishSave() {
        finishWithAction(.save)
    }

    enum FinishAction {
        case copy
        case pin
        case save
    }

    private func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    private func startAutoScroll() {
        guard canPostScrollEvents() else { return }
        isAutoScrolling = true
        unchangedTickCount = 0
        toolbarView?.toolTip = nil
        toolbarView?.isAutoScrolling = true

        autoScrollTimer?.invalidate()
        // 80ms 匀速平滑微步滚动，杜绝洪泛，且绝对不抢占/锁定鼠标光标！
        let aTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.tickAutoScroll()
        }
        RunLoop.main.add(aTimer, forMode: .common)
        self.autoScrollTimer = aTimer
    }

    private func stopAutoScroll() {
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        toolbarView?.isAutoScrolling = false
    }

    private func tickAutoScroll() {
        guard isAutoScrolling else { return }
        dbgAutoTick += 1
        if dbgAutoTick % 12 == 1 { scdbg("[SCDBG] autoTick #\(dbgAutoTick) post -26") }
        postManualScroll(pixelDeltaY: -26)
    }

    /// 取当前选区画面。改用与截图主流程一致的 CGWindowListCreateImage，保证兼容性；
    /// 预览卡片与工具条正常位于选区之外，不会进入取帧区域。
    /// （此前用 CGImage(windowListFromArrayScreenBounds:...) 在部分环境下返回空图，导致点“滚动截图”无反应，已废弃该路径。）
    private func captureFrame() -> CGImage? {
        // 只截取目标 App 的那个窗口，排除我们自己的预览/工具条/边框浮窗（否则浮窗缩略图会被拼进长图）。
        var winID: CGWindowID = 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let center = CGPoint(x: cgCaptureRect.midX, y: cgCaptureRect.midY)
            for w in infos {
                guard let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber else { continue }
                let pid = pid_t(pidNum.int32Value)
                if pid == ownPID { continue }
                if targetPID != 0 && pid != targetPID { continue }
                guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                      let x = (b["X"] as? NSNumber)?.doubleValue,
                      let y = (b["Y"] as? NSNumber)?.doubleValue,
                      let wd = (b["Width"] as? NSNumber)?.doubleValue,
                      let ht = (b["Height"] as? NSNumber)?.doubleValue else { continue }
                let rect = CGRect(x: x, y: y, width: wd, height: ht)
                if rect.contains(center), let num = w[kCGWindowNumber as String] as? NSNumber {
                    winID = CGWindowID(num.uint32Value)
                    if targetPID == 0 { targetPID = pid }
                    break
                }
            }
        }
        var img: CGImage?
        if winID != 0 {
            img = CGWindowListCreateImage(cgCaptureRect, .optionIncludingWindow, winID, [.bestResolution])
        }
        if img == nil {
            img = CGWindowListCreateImage(cgCaptureRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        }
        guard let full = img else { return nil }
        // 裁掉边缘若干像素：去除选区高亮边框(青色线)/滚动条等边缘干扰
        let inset = 8
        if full.width > inset * 2 + 8, full.height > inset * 2 + 8,
           let cropped = full.cropping(to: CGRect(x: inset, y: inset, width: full.width - inset * 2, height: full.height - inset * 2)) {
            return cropped
        }
        return full
    }

    private func sampleAndStitchFrame() {
        guard let stitcher = self.stitcher else { return }
        guard let frameCG = captureFrame() else { scdbg("[SCDBG] sample frameCG=nil"); return }

        let sig = frameSignature(frameCG)
        let changed = sig != lastFrameSig
        lastFrameSig = sig
        let result = stitcher.appendFrame(frameCG)
        scdbg("[SCDBG] sample frame=\(frameCG.width)x\(frameCG.height) changed=\(changed) result=\(result) total=\(stitcher.totalPixelHeight)")
        switch result {
        case .firstFrame, .appended:
            unchangedTickCount = 0
            previewView?.previewImage = stitcher.renderCurrentImage()
            toolbarView?.sizeText = "\(stitcher.width) × \(stitcher.totalPixelHeight)"

        case .noMovement:
            // 只有“画面完全没变(changed=false)”才计入到底判定；画面在动只是回到已拍区域，不当作到底
            if isAutoScrolling && !changed {
                unchangedTickCount += 1
                if unchangedTickCount >= 16 { // 连续约 1.6 秒画面无变化，判定已到底自动停止
                    stopAutoScroll()
                }
            }

        case .rejected:
            // 保留分支以防万一；单帧不匹配不中断自动滚动，按静止处理、等下一帧重新对齐
            if isAutoScrolling {
                unchangedTickCount += 1
                if unchangedTickCount >= 16 { stopAutoScroll() }
            }

        case .reachedLimit:
            stopAutoScroll()
            toolbarView?.sizeText = "已达高度上限"
            toolbarView?.toolTip = "长图上限为 \(stitcher.maxPixelHeight) 像素；已保留 \(stitcher.totalPixelHeight) 像素，请完成后分段截图。"
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            stopCleanup()
            return true
        case 36, 76: // Return / Enter
            finishCopy()
            return true
        case 99: // F3
            finishPin()
            return true
        case 49: // Space
            toggleAutoScroll()
            return true
        case 125: // Down arrow (↓)
            if isAutoScrolling { stopAutoScroll() }
            postManualScroll(pixelDeltaY: -36)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.sampleAndStitchFrame()
            }
            return true
        case 126: // Up arrow (↑)
            if isAutoScrolling { stopAutoScroll() }
            postManualScroll(pixelDeltaY: 36)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.sampleAndStitchFrame()
            }
            return true
        default:
            return false
        }
    }

    private func canPostScrollEvents() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        toolbarView?.sizeText = "需辅助功能权限"
        toolbarView?.toolTip = "请在系统设置 → 隐私与安全性 → 辅助功能中允许 MacPaste 控制滚动，或使用鼠标手动滚动。"
        return false
    }

    private func postManualScroll(pixelDeltaY: Int32) {
        guard canPostScrollEvents() else { stopAutoScroll(); return }
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: pixelDeltaY,
            wheel2: 0,
            wheel3: 0
        ) {
            // CGEvent 使用左上角为原点的屏幕坐标。
            scrollEvent.location = CGPoint(x: cgCaptureRect.midX, y: cgCaptureRect.midY)
            // 关键：定向发给目标 App，而不是投到 HID 全局事件流（后者会把鼠标光标拽到该坐标、导致鼠标动不了）。
            if targetPID != 0 {
                scrollEvent.postToPid(targetPID)
            } else {
                scrollEvent.post(tap: .cghidEventTap)
            }
            if !isAutoScrolling {
                scdbg("[SCDBG] postManualScroll delta=\(pixelDeltaY) at=(\(cgCaptureRect.midX),\(cgCaptureRect.midY))")
            }
        } else {
            scdbg("[SCDBG] postManualScroll CGEvent=nil delta=\(pixelDeltaY)")
        }
    }

    private func saveDebugPng(_ img: NSImage) {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "/tmp/macpaste_last.png"))
        scdbg("[SCDBG] saved /tmp/macpaste_last.png")
    }

    func finishWithAction(_ action: FinishAction) {
        stopAutoScroll()
        sampleTimer?.invalidate()
        sampleTimer = nil
        // 用户可在两个定时采样之间结束，先补采当前画面，再生成最终长图。
        sampleAndStitchFrame()
        let finalImg = stitcher?.renderCurrentImage()
        if let fi = finalImg { saveDebugPng(fi) }
        let copyCB = onFinishCopy
        let pinCB = onFinishPin
        let saveCB = onFinishSave
        stopCleanup()

        guard let img = finalImg else { return }
        switch action {
        case .copy:
            copyCB?(img)
        case .pin:
            pinCB?(img)
        case .save:
            saveCB?(img)
        }
    }

    func stopCleanup() {
        stopAutoScroll()
        sampleTimer?.invalidate()
        sampleTimer = nil
        if let g = globalKeyMonitor {
            NSEvent.removeMonitor(g)
            globalKeyMonitor = nil
        }
        if let l = localKeyMonitor {
            NSEvent.removeMonitor(l)
            localKeyMonitor = nil
        }
        borderOverlay?.close()
        borderOverlay = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
        previewView = nil
        toolbarWindow?.orderOut(nil)
        toolbarWindow = nil
        toolbarView = nil
        stitcher = nil
        onFinishCopy = nil
        onFinishPin = nil
        onFinishSave = nil
    }
}
