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

    /// 使用 macOS 原生 Vision 框架离线高精度识别图片中的中英文文本（包含 CoreImage 预处理、超分锐化与同行碎片智能拼接）
    static func recognizeLines(from image: NSImage, completion: @escaping ([String]) -> Void) {
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
            completion([])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let processedCGImage = preprocessForOCR(cgImage: validCGImage)

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
                DispatchQueue.main.async { completion([]) }
                return
            }

            struct TextFragment {
                let text: String
                let box: CGRect
            }

            let fragments = observations.compactMap { obs -> TextFragment? in
                guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return TextFragment(text: text, box: obs.boundingBox)
            }

            // 同行碎片智能聚类：垂直中心差小于行高的 55% 归入同一物理行
            var lineGroups: [[TextFragment]] = []
            for frag in fragments {
                if let idx = lineGroups.firstIndex(where: { group in
                    let avgH = group.reduce(0.0) { $0 + $1.box.height } / CGFloat(group.count)
                    let midY = group.reduce(0.0) { $0 + $1.box.midY } / CGFloat(group.count)
                    return abs(frag.box.midY - midY) < avgH * 0.55
                }) {
                    lineGroups[idx].append(frag)
                } else {
                    lineGroups.append([frag])
                }
            }

            // 按垂直位置从上到下排序（Vision 坐标系原点在左下角，midY 越大越靠上）
            lineGroups.sort { a, b in
                let midYA = a.reduce(0.0) { $0 + $1.box.midY } / CGFloat(a.count)
                let midYB = b.reduce(0.0) { $0 + $1.box.midY } / CGFloat(b.count)
                return midYA > midYB
            }

            // 每行内部从左到右排序并智能拼接
            let resultLines = lineGroups.compactMap { group -> String? in
                let sorted = group.sorted { $0.box.minX < $1.box.minX }
                var lineStr = ""
                for (i, frag) in sorted.enumerated() {
                    if i == 0 {
                        lineStr += frag.text
                    } else {
                        let prev = sorted[i - 1]
                        let prevLast = prev.text.last ?? " "
                        let currFirst = frag.text.first ?? " "
                        let gap = frag.box.minX - prev.box.maxX
                        // 若前后均为中文且间距极小，直接拼接不加空格
                        if isCJK(prevLast) && isCJK(currFirst) && gap < 0.025 {
                            lineStr += frag.text
                        } else {
                            lineStr += " " + frag.text
                        }
                    }
                }
                let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            DispatchQueue.main.async {
                completion(resultLines)
            }
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

    private static func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x20000...0x2A6DF).contains(scalar.value)
    }
}
