import AppKit
import CoreGraphics
import Vision

/// 交互式区域截图（带全屏颜色提示、8控制点边角放大镜预览、横框/圆框/箭头/画笔/荧光笔/马赛克/文字标注）与图片 OCR 识别服务
final class ScreenshotManager {
    static let shared = ScreenshotManager()
    private(set) var isCapturing = false
    private var overlayWindow: ScreenshotOverlayWindow?
    private var canvasView: ScreenshotCanvasView?
    private var didPromptPermission = false

    /// 触发自定义 Snipaste 风格交互式区域截图（F1）
    func captureToClipboard(onCaptured: (() -> Void)? = nil) {
        if isCapturing {
            overlayWindow?.makeKeyAndOrderFront(nil)
            return
        }

        // 记录启动截图前真实的外部前台应用（若菜单栏等入口使 MacPaste 已在前台，则回退到最近激活的外部应用）
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let scrollTargetApplication: NSRunningApplication? = {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ownPID {
                return front
            }
            return ExternalAppTracker.shared.lastExternal
        }()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen = screen else { return }

        let hasPerm = CGPreflightScreenCaptureAccess()
        if !hasPerm && !didPromptPermission {
            didPromptPermission = true
            _ = CGRequestScreenCaptureAccess()
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
        let cgRect = CGRect(
            x: targetScreen.frame.minX,
            y: primaryHeight - targetScreen.frame.maxY,
            width: targetScreen.frame.width,
            height: targetScreen.frame.height
        )

        guard let cgImage = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            fallbackSystemCapture(onCaptured: onCaptured)
            return
        }

        isCapturing = true
        let sampler = ScreenBitmapSampler(cgImage: cgImage, scaleFactor: targetScreen.backingScaleFactor)

        let panel = ScreenshotOverlayWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true

        let canvas = ScreenshotCanvasView(
            frame: NSRect(origin: .zero, size: targetScreen.frame.size),
            sampler: sampler,
            hasScreenPermission: hasPerm
        )

        canvas.onFinishCopy = { [weak self] finalImg, _ in
            self?.writeImageToPasteboard(finalImg)
            self?.dismissOverlay()
            onCaptured?()
        }

        canvas.onFinishPin = { [weak self] finalImg, screenRect, triggerOCR, triggerTranslate in
            self?.writeImageToPasteboard(finalImg)
            self?.dismissOverlay()
            onCaptured?()
            Task { @MainActor in
                PinWindowManager.shared.pinImage(
                    finalImg,
                    atScreenRect: screenRect,
                    triggerOCR: triggerOCR,
                    triggerTranslate: triggerTranslate
                )
            }
        }

        canvas.onFinishSave = { [weak self] finalImg in
            self?.writeImageToPasteboard(finalImg)
            self?.dismissOverlay()
            onCaptured?()
            self?.saveImageToDisk(finalImg)
        }

        canvas.onStartScrollCapture = { [weak self] appKitRect in
            self?.dismissOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                ScrollCaptureController.shared.start(
                    appKitRect: appKitRect,
                    targetApplication: scrollTargetApplication,
                    onFinishCopy: { finalImg in
                        self?.writeImageToPasteboard(finalImg)
                        onCaptured?()
                    },
                    onFinishPin: { finalImg in
                        self?.writeImageToPasteboard(finalImg)
                        onCaptured?()
                        Task { @MainActor in
                            PinWindowManager.shared.pinImage(finalImg, atScreenRect: appKitRect, triggerOCR: false)
                        }
                    },
                    onFinishSave: { finalImg in
                        self?.writeImageToPasteboard(finalImg)
                        onCaptured?()
                        self?.saveImageToDisk(finalImg)
                    }
                )
            }
        }

        canvas.onCancel = { [weak self] in
            self?.dismissOverlay()
        }

        panel.contentView = canvas
        self.overlayWindow = panel
        self.canvasView = canvas

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        canvas.syncInitialMouseLocation()
    }

    /// 在截图模式中直接按全局 F3 时触发：完成当前选区并直接贴到屏幕上
    func finishAndPinIfCapturing() {
        guard isCapturing, let canvas = canvasView else { return }
        canvas.finishCapture(mode: .pinToScreen)
    }

    func dismissOverlay() {
        NSCursor.arrow.set()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        canvasView = nil
        isCapturing = false
    }

    /// 供自测或外部快速打开并预置选区/标注
    func debugTestRender(rect: CGRect, annotations: [ScreenshotAnnotation]) -> NSImage? {
        guard let screen = NSScreen.main else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgRect = CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        guard let cg = CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            return nil
        }
        let sampler = ScreenBitmapSampler(cgImage: cg, scaleFactor: screen.backingScaleFactor)
        return ScreenshotRenderer.renderFinalImage(selectionRect: rect, sampler: sampler, annotations: annotations)
    }

    private func writeImageToPasteboard(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
    }

    private func saveImageToDisk(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        savePanel.nameFieldStringValue = "MacPaste-\(formatter.string(from: Date())).png"
        savePanel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? pngData.write(to: url, options: .atomic)
        }
    }

    private func fallbackSystemCapture(onCaptured: (() -> Void)?) {
        isCapturing = true
        let beforeCount = NSPasteboard.general.changeCount
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-c"]
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isCapturing = false
                if NSPasteboard.general.changeCount != beforeCount {
                    onCaptured?()
                }
            }
        }
        try? proc.run()
    }

    private struct OCRLineSegment {
        var text: String
        var box: CGRect
        var totalHeight: CGFloat
        var count: Int

        var avgHeight: CGFloat { max(totalHeight / CGFloat(max(count, 1)), box.height * 0.90) }
    }

    /// 使用 macOS 原生 Vision 框架离线高精度识别图片中的文本行（水平间距感知，避免同行不同栏/按钮错误拼合）
    static func recognizeLines(from image: NSImage, completion: @escaping ([String]) -> Void) {
        extractLineSegments(from: image) { segments, _ in
            let lines = segments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async {
                completion(lines)
            }
        }
    }

    /// 识别图片中的语义文本块及其归一化位置（左上角为原点），供原位分块翻译与双语对照使用
    static func recognizeTextBlocks(from image: NSImage, completion: @escaping ([OCRTextBlock]) -> Void) {
        extractLineSegments(from: image) { segments, aspect in
            guard !segments.isEmpty else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            struct BlockAccumulator {
                var text: String
                var box: CGRect
                var lineCount: Int
                var totalLineHeight: CGFloat
                var segments: [OCRLineSegment]

                var lastSegment: OCRLineSegment { segments[segments.count - 1] }
                var avgLineHeight: CGFloat { totalLineHeight / CGFloat(max(lineCount, 1)) }
            }

            func canMergeIntoParagraph(_ acc: BlockAccumulator, next seg: OCRLineSegment) -> Bool {
                let curr = acc.lastSegment
                let avgH = acc.avgLineHeight
                let avgHInX = avgH * aspect

                // 1. 左边缘对齐或中心轴对称居中对齐
                let isLeftAligned = abs(acc.box.minX - seg.box.minX) <= avgHInX * 1.5
                let isCenterAligned = abs(acc.box.midX - seg.box.midX) <= max(avgHInX * 2.0, 0.025)
                    && seg.box.width <= curr.box.width * 1.25
                guard isLeftAligned || isCenterAligned else { return false }

                // 2. 垂直间距紧凑（Vision 左下角坐标系，上一行 minY 在下一行 maxY 上方）
                let verticalGap = curr.box.minY - seg.box.maxY
                guard verticalGap >= -avgH * 0.25 && verticalGap <= avgH * 0.90 else { return false }

                // 3. 字号高度相近（兼容含上伸/下延字母与仅短小写字母的跨行大标题）
                let ratio = max(curr.avgHeight, seg.avgHeight) / max(min(curr.avgHeight, seg.avgHeight), 0.0001)
                guard ratio <= 1.50 else { return false }

                // 4. 上一行需为较长正文行且两行水平投影充分重叠
                let prevIsBodyLine = curr.text.count >= 16 || curr.box.width >= avgHInX * 7.0
                guard prevIsBodyLine else { return false }

                let overlapW = min(curr.box.maxX, seg.box.maxX) - max(curr.box.minX, seg.box.minX)
                let minW = min(curr.box.width, seg.box.width)
                return minW > 0 && (overlapW / minW) >= 0.45
            }

            var accumulators: [BlockAccumulator] = []
            for seg in segments {
                if let matchIdx = accumulators.indices.reversed().first(where: { idx in
                    guard canMergeIntoParagraph(accumulators[idx], next: seg) else { return false }
                    // 确保两行之间没有真正夹在中间的已成块文本（排除同行兄弟片段）
                    let curr = accumulators[idx].lastSegment
                    let hasIntervening = accumulators[(idx + 1)...].contains { other in
                        let ox = min(other.box.maxX, seg.box.maxX) - max(other.box.minX, seg.box.minX)
                        return ox > 0 && other.box.midY < curr.box.minY && other.box.midY > seg.box.maxY
                    }
                    return !hasIntervening
                }) {
                    accumulators[matchIdx].text = joinParagraphLines(accumulators[matchIdx].text, seg.text)
                    accumulators[matchIdx].box = accumulators[matchIdx].box.union(seg.box)
                    accumulators[matchIdx].lineCount += 1
                    accumulators[matchIdx].totalLineHeight += seg.avgHeight
                    accumulators[matchIdx].segments.append(seg)
                } else {
                    accumulators.append(BlockAccumulator(
                        text: seg.text,
                        box: seg.box,
                        lineCount: 1,
                        totalLineHeight: seg.avgHeight,
                        segments: [seg]
                    ))
                }
            }

            let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
            var blocks: [OCRTextBlock] = accumulators.compactMap { acc in
                let trimmed = acc.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let topLeftRect = CGRect(
                    x: acc.box.minX,
                    y: 1.0 - acc.box.maxY,
                    width: acc.box.width,
                    height: acc.box.height
                ).intersection(unitBounds)
                guard !topLeftRect.isNull, topLeftRect.width > 0, topLeftRect.height > 0 else { return nil }

                var blockCentered = false
                if acc.segments.count >= 2,
                   let widest = acc.segments.max(by: { $0.box.width < $1.box.width }),
                   let shortest = acc.segments.min(by: { $0.box.width < $1.box.width }),
                   shortest.box.width < widest.box.width * 0.92 {
                    let centerDiff = abs(shortest.box.midX - widest.box.midX)
                    let leftDiff = abs(shortest.box.minX - widest.box.minX)
                    let maxCenterTol = max(acc.avgLineHeight * aspect * 2.0, 0.025)
                    if centerDiff <= maxCenterTol && centerDiff < leftDiff * 0.55 {
                        blockCentered = true
                    }
                }

                return OCRTextBlock(
                    text: trimmed,
                    normalizedRect: topLeftRect,
                    normalizedLineHeight: acc.avgLineHeight,
                    lineCount: acc.lineCount,
                    isCentered: blockCentered
                )
            }

            // 同轴居中传染：若同列存在已判定的居中块或两个宽度明显不同却共享中心轴的块，则均视为居中
            var centeredFlags = blocks.map(\.isCentered)
            for i in blocks.indices where !centeredFlags[i] {
                let a = blocks[i].normalizedRect
                for j in blocks.indices where i != j {
                    let b = blocks[j].normalizedRect
                    let centerDiff = abs(a.midX - b.midX)
                    if centeredFlags[j] && centerDiff <= 0.055 {
                        centeredFlags[i] = true
                        break
                    }
                    let leftDiff = abs(a.minX - b.minX)
                    if centerDiff <= 0.035 && leftDiff > 0.035 && abs(a.width - b.width) > 0.08 {
                        centeredFlags[i] = true
                        break
                    }
                }
            }
            blocks = blocks.enumerated().map { idx, blk in
                OCRTextBlock(
                    text: blk.text,
                    normalizedRect: blk.normalizedRect,
                    normalizedLineHeight: blk.normalizedLineHeight,
                    lineCount: blk.lineCount,
                    isCentered: centeredFlags[idx]
                )
            }

            blocks.sort { a, b in
                let minH = min(a.normalizedRect.height, b.normalizedRect.height)
                if abs(a.normalizedRect.midY - b.normalizedRect.midY) < minH * 0.5 {
                    return a.normalizedRect.minX < b.normalizedRect.minX
                }
                return a.normalizedRect.minY < b.normalizedRect.minY
            }

            DispatchQueue.main.async {
                completion(blocks)
            }
        }
    }

    private static func extractLineSegments(
        from image: NSImage,
        completion: @escaping ([OCRLineSegment], CGFloat) -> Void
    ) {
        let rawCGImage: CGImage? = {
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
            if let rep = image.representations.first as? NSBitmapImageRep, let cg = rep.cgImage {
                return cg
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage {
                return cg
            }
            return nil
        }()
        guard let validCGImage = rawCGImage else {
            DispatchQueue.main.async { completion([], 1.0) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let processedCGImage = preprocessForOCR(cgImage: validCGImage)
            let aspect = CGFloat(processedCGImage.height) / max(CGFloat(processedCGImage.width), 1.0)

            let req = VNRecognizeTextRequest()
            req.revision = VNRecognizeTextRequestRevision3
            req.recognitionLevel = .accurate
            req.recognitionLanguages = [
                "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "ar-SA", "fr-FR", "de-DE",
                "es-ES", "ru-RU", "pt-BR", "it-IT", "th-TH", "vi-VT", "id-ID", "tr-TR",
                "uk-UA", "pl-PL", "nl-NL", "sv-SE", "cs-CZ", "ms-MY", "hi-IN"
            ]
            req.automaticallyDetectsLanguage = true
            req.usesLanguageCorrection = true
            req.minimumTextHeight = 0.0

            let handler = VNImageRequestHandler(cgImage: processedCGImage, options: [:])
            try? handler.perform([req])

            let observations = req.results ?? []
            guard !observations.isEmpty else {
                completion([], aspect)
                return
            }

            struct TextFragment {
                let text: String
                let box: CGRect
            }

            let fragments = observations.compactMap { obs -> TextFragment? in
                guard let raw = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                let text = normalizeOCRText(raw)
                return TextFragment(text: text, box: obs.boundingBox)
            }.sorted { $0.box.midY > $1.box.midY }

            // 1. 先按垂直重叠或中心接近度分入水平行组（避免行尾短碎片因缺少下延字母导致中心上偏而另起一行）
            var rowGroups: [[TextFragment]] = []
            for frag in fragments {
                if let idx = rowGroups.firstIndex(where: { group in
                    let avgH = group.reduce(0.0) { $0 + $1.box.height } / CGFloat(group.count)
                    let midY = group.reduce(0.0) { $0 + $1.box.midY } / CGFloat(group.count)
                    let groupMinY = group.map(\.box.minY).min() ?? frag.box.minY
                    let groupMaxY = group.map(\.box.maxY).max() ?? frag.box.maxY
                    let overlapY = min(frag.box.maxY, groupMaxY) - max(frag.box.minY, groupMinY)
                    let minH = min(frag.box.height, avgH)
                    let maxH = max(frag.box.height, avgH)
                    return (minH > 0 && overlapY >= minH * 0.25) || abs(frag.box.midY - midY) < maxH * 0.65
                }) {
                    rowGroups[idx].append(frag)
                } else {
                    rowGroups.append([frag])
                }
            }

            // 按垂直位置从上到下排序（Vision 坐标系原点在左下角，midY 越大越靠上）
            rowGroups.sort { a, b in
                let midYA = a.reduce(0.0) { $0 + $1.box.midY } / CGFloat(a.count)
                let midYB = b.reduce(0.0) { $0 + $1.box.midY } / CGFloat(b.count)
                return midYA > midYB
            }

            // 2. 每行内按从左到右顺序，仅合并水平间距较小的邻近碎片；远距分栏/按钮保持为独立片段
            var segments: [OCRLineSegment] = []
            for group in rowGroups {
                let sorted = group.sorted { $0.box.minX < $1.box.minX }
                var current: OCRLineSegment?

                for frag in sorted {
                    if var curr = current {
                        let lineH = max(curr.avgHeight, curr.box.height)
                        let lineHInX = lineH * aspect
                        let gapX = frag.box.minX - curr.box.maxX
                        let overlapY = min(frag.box.maxY, curr.box.maxY) - max(frag.box.minY, curr.box.minY)
                        let minH = min(frag.box.height, lineH)
                        let verticalMatch = (minH > 0 && overlapY >= minH * 0.20)
                            || abs(frag.box.midY - curr.box.midY) < max(frag.box.height, lineH) * 0.65
                        let horizontalMatch = gapX < max(lineHInX * 2.8, 0.04) && gapX >= -lineHInX * 1.5

                        if verticalMatch && horizontalMatch {
                            let prevLast = curr.text.last ?? " "
                            let currFirst = frag.text.first ?? " "
                            if isCJK(prevLast) && isCJK(currFirst) && gapX < max(lineHInX * 0.45, 0.015) {
                                curr.text += frag.text
                            } else {
                                curr.text += " " + frag.text
                            }
                            curr.box = curr.box.union(frag.box)
                            curr.totalHeight += frag.box.height
                            curr.count += 1
                            current = curr
                        } else {
                            segments.append(curr)
                            current = OCRLineSegment(text: frag.text, box: frag.box, totalHeight: frag.box.height, count: 1)
                        }
                    } else {
                        current = OCRLineSegment(text: frag.text, box: frag.box, totalHeight: frag.box.height, count: 1)
                    }
                }
                if let lastSeg = current {
                    segments.append(lastSeg)
                }
            }

            completion(segments, aspect)
        }
    }

    /// OCR 图像增强预处理：根据背景亮度自适应反色、小尺寸图 2x Lanczos 超分放大与四周防裁切留白
    private static func preprocessForOCR(cgImage: CGImage) -> CGImage {
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var ci = CIImage(cgImage: cgImage)
        let extent = ci.extent

        // 1. 判断是否为深色背景（黑底/深灰底白字）
        if isDarkBackground(cgImage: cgImage) {
            if let invert = CIFilter(name: "CIColorInvert") {
                invert.setValue(ci, forKey: kCIInputImageKey)
                if let inv = invert.outputImage {
                    ci = inv
                }
            }
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(ci, forKey: kCIInputImageKey)
                colorControls.setValue(1.25, forKey: kCIInputContrastKey)
                colorControls.setValue(0.05, forKey: kCIInputBrightnessKey)
                if let adjusted = colorControls.outputImage {
                    ci = adjusted
                }
            }
        }

        // 2. 小尺寸图 2 倍超分放大
        let scale: CGFloat = (extent.width < 1200 || extent.height < 600) ? 2.0 : 1.0
        if scale > 1.0 {
            if let filter = CIFilter(name: "CILanczosScaleTransform") {
                filter.setValue(ci, forKey: kCIInputImageKey)
                filter.setValue(scale, forKey: kCIInputScaleKey)
                filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let scaled = filter.outputImage {
                    ci = scaled
                }
            }
        }

        // 3. 轻微锐化
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(ci, forKey: kCIInputImageKey)
            sharpen.setValue(0.35, forKey: kCIInputSharpnessKey)
            if let sharpened = sharpen.outputImage {
                ci = sharpened
            }
        }

        if let rendered = ciContext.createCGImage(ci, from: ci.extent) {
            return rendered
        }
        return cgImage
    }

    private static func isDarkBackground(cgImage: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixel[0]) / 255.0
        let g = CGFloat(pixel[1]) / 255.0
        let b = CGFloat(pixel[2]) / 255.0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 0.40
    }

    private static let spellLock = NSLock()
    private static let commonShortEnglishWords: Set<String> = [
        "a", "i", "in", "on", "at", "to", "by", "of", "or", "as", "is", "it",
        "be", "an", "no", "up", "we", "he", "my", "if", "do", "go", "so", "us",
        "me", "for", "and", "the", "are", "but", "not", "you", "all", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has", "him",
        "his", "how", "man", "new", "now", "old", "see", "two", "way", "who",
        "its", "let", "put", "say", "she", "too", "use", "off", "per", "via"
    ]

    /// 修复无衬线字体中大写 I 与小写 l 常见的 OCR 混淆（如 Al-Native -> AI-Native、AlGC -> AIGC）
    private static func normalizeOCRText(_ text: String) -> String {
        let patterns: [(String, String)] = [
            (#"\bAl-(?=[A-Za-z])"#, "AI-"),
            (#"\bAlGC\b"#, "AIGC"),
            (#"\bOpenAl\b"#, "OpenAI"),
            (#"\bGenAl\b"#, "GenAI"),
            (#"\bAl(?=\s+(?:Native|Powered|Driven|First|Agent|Agents|Chat|Model|Models|Assistant))"#, "AI"),
        ]
        var result = text
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
        }
        return result
    }

    /// 智能拼接跨行文本：识别 CJK 连续字、连字符断行及英文跨行断词（如 Ex + perts -> Experts）
    private static func joinParagraphLines(_ prev: String, _ next: String) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return n }
        guard !n.isEmpty else { return p }

        if let pLast = p.last, let nFirst = n.first, isCJK(pLast), isCJK(nFirst) {
            return p + n
        }

        if p.hasSuffix("-"), let nFirst = n.first, nFirst.isASCII && nFirst.isLowercase {
            let pNoHyphen = String(p.dropLast())
            if let leftStem = trailingASCIILetters(in: pNoHyphen),
               let rightStem = leadingASCIILetters(in: n),
               isEnglishWordValid(leftStem + rightStem) {
                return pNoHyphen + n
            }
        }

        if let lastWord = trailingASCIILetters(in: p),
           let firstWord = leadingASCIILetters(in: n),
           let firstChar = firstWord.first, firstChar.isLowercase {
            let combined = lastWord + firstWord
            if isEnglishWordValid(combined) {
                let firstMissing = !isEnglishWordValid(firstWord)
                let lastMissing = !isEnglishWordValid(lastWord)
                let shortNonFunctionStem = lastWord.count <= 3 && !commonShortEnglishWords.contains(lastWord.lowercased())
                if firstMissing || lastMissing || shortNonFunctionStem {
                    return p + n
                }
            }
        }

        return p + " " + n
    }

    private static func trailingASCIILetters(in text: String) -> String? {
        var chars: [Character] = []
        for ch in text.reversed() {
            if ch.isASCII && ch.isLetter {
                chars.append(ch)
            } else {
                break
            }
        }
        guard !chars.isEmpty else { return nil }
        return String(chars.reversed())
    }

    private static func leadingASCIILetters(in text: String) -> String? {
        var result = ""
        for ch in text {
            if ch.isASCII && ch.isLetter {
                result.append(ch)
            } else {
                break
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func isEnglishWordValid(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        spellLock.lock()
        defer { spellLock.unlock() }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    private static func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x20000...0x2A6DF).contains(scalar.value)
    }
}
