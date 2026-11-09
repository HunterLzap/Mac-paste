import AppKit
import CoreGraphics

// MARK: - 截图工具枚举

enum ScreenshotTool: String, CaseIterable {
    case rectangle = "横框"
    case ellipse = "圆框"
    case arrow = "箭头"
    case pen = "标记"
    case highlighter = "荧光"
    case mosaic = "打码"
    case text = "文字"

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "textformat"
        }
    }

    var tooltip: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "圆框"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        }
    }
}

// MARK: - 选区 8 个边角/边缘控制点

enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var label: String {
        switch self {
        case .topLeft: return "左上角"
        case .top: return "上边缘"
        case .topRight: return "右上角"
        case .right: return "右边缘"
        case .bottomRight: return "右下角"
        case .bottom: return "下边缘"
        case .bottomLeft: return "左下角"
        case .left: return "左边缘"
        }
    }
}

// MARK: - 标注数据结构

struct ScreenshotAnnotation: Identifiable {
    let id = UUID()
    var tool: ScreenshotTool
    var color: NSColor
    var lineWidth: CGFloat
    var startPoint: CGPoint
    var endPoint: CGPoint
    var points: [CGPoint] = []
    var text: String = ""

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        startPoint.x += dx
        startPoint.y += dy
        endPoint.x += dx
        endPoint.y += dy
        for i in points.indices {
            points[i].x += dx
            points[i].y += dy
        }
    }

    /// 校验是否为真正绘制出来的有效标注（过滤单击/微抖产生的 0 尺寸隐形标注，避免撤销失效）
    var isValidVisibleAnnotation: Bool {
        switch tool {
        case .rectangle, .ellipse, .arrow:
            return hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) >= 3.0
        case .pen, .highlighter:
            guard points.count >= 2 else { return false }
            return points.contains { hypot($0.x - startPoint.x, $0.y - startPoint.y) >= 2.0 }
        case .mosaic:
            return points.count >= 2 || hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) >= 2.0
        case .text:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - 调色盘预设与线宽预设

struct ScreenshotPalette {
    static let colors: [(name: String, color: NSColor)] = [
        ("红", NSColor(calibratedRed: 1.00, green: 0.23, blue: 0.19, alpha: 1.0)),
        ("橙", NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.00, alpha: 1.0)),
        ("黄", NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.00, alpha: 1.0)),
        ("绿", NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)),
        ("青", NSColor(calibratedRed: 0.00, green: 0.78, blue: 1.00, alpha: 1.0)),
        ("蓝", NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.00, alpha: 1.0)),
        ("紫", NSColor(calibratedRed: 0.69, green: 0.32, blue: 0.87, alpha: 1.0)),
        ("白", NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0)),
    ]

    static let strokeWidths: [(label: String, width: CGFloat)] = [
        ("细", 2.5),
        ("中", 4.5),
        ("粗", 7.5),
    ]

    /// 截图模式主题亮色（青蓝高亮）
    static let themeAccent = NSColor(calibratedRed: 0.00, green: 0.78, blue: 1.00, alpha: 1.0)
    static let themeGlow = NSColor(calibratedRed: 0.00, green: 0.82, blue: 1.00, alpha: 0.38)
}

// MARK: - 屏幕像素采样器（用于实时放大镜预览与色值提取、马赛克取色）

final class ScreenBitmapSampler {
    let cgImage: CGImage
    let width: Int
    let height: Int
    let scaleFactor: CGFloat
    private let pixelData: [UInt8]

    init(cgImage: CGImage, scaleFactor: CGFloat) {
        self.cgImage = cgImage
        self.width = cgImage.width
        self.height = cgImage.height
        self.scaleFactor = max(scaleFactor, 1.0)

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
        self.pixelData = buffer
    }

    /// 根据翻转视图坐标 (左上角为原点) 获取像素 RGB (0...255) 与 HEX
    func colorAt(viewPoint: CGPoint) -> (r: Int, g: Int, b: Int, hex: String, nsColor: NSColor) {
        let px = min(max(Int((viewPoint.x * scaleFactor).rounded()), 0), max(width - 1, 0))
        let py = min(max(Int((viewPoint.y * scaleFactor).rounded()), 0), max(height - 1, 0))
        guard width > 0, height > 0 else {
            return (0, 0, 0, "#000000", .black)
        }
        let idx = (py * width + px) * 4
        let r = Int(pixelData[idx])
        let g = Int(pixelData[idx + 1])
        let b = Int(pixelData[idx + 2])
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let color = NSColor(
            calibratedRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
        return (r, g, b, hex, color)
    }

    /// 裁剪放大镜局部像素图
    func croppedMagnifierPatch(centerViewPoint: CGPoint, radiusInPoints: CGFloat) -> CGImage? {
        let cx = centerViewPoint.x * scaleFactor
        let cy = centerViewPoint.y * scaleFactor
        let rPx = radiusInPoints * scaleFactor
        let rect = CGRect(x: cx - rPx, y: cy - rPx * 0.72, width: rPx * 2, height: rPx * 1.44).integral
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clamped.width >= 2, clamped.height >= 2 else { return nil }
        return cgImage.cropping(to: clamped)
    }
}

// MARK: - 标注绘制渲染器（同时用于实时画布与最终导出图片合成）

enum ScreenshotRenderer {
    static func drawAnnotation(_ item: ScreenshotAnnotation, sampler: ScreenBitmapSampler?) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        switch item.tool {
        case .rectangle:
            let rect = Self.normalizedRect(from: item.startPoint, to: item.endPoint)
            guard rect.width >= 1 || rect.height >= 1 else { return }
            item.color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = item.lineWidth
            path.lineJoinStyle = .round
            path.stroke()

        case .ellipse:
            let rect = Self.normalizedRect(from: item.startPoint, to: item.endPoint)
            guard rect.width >= 1 || rect.height >= 1 else { return }
            item.color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = item.lineWidth
            path.stroke()

        case .arrow:
            drawArrow(from: item.startPoint, to: item.endPoint, color: item.color, lineWidth: item.lineWidth)

        case .pen:
            guard item.points.count >= 2 else { return }
            item.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = item.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: item.points[0])
            for pt in item.points.dropFirst() {
                path.line(to: pt)
            }
            path.stroke()

        case .highlighter:
            guard item.points.count >= 2 else { return }
            item.color.withAlphaComponent(0.36).setStroke()
            let path = NSBezierPath()
            path.lineWidth = item.lineWidth * 4.0
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: item.points[0])
            for pt in item.points.dropFirst() {
                path.line(to: pt)
            }
            path.stroke()

        case .mosaic:
            drawMosaic(points: item.points, brushWidth: item.lineWidth, sampler: sampler)

        case .text:
            guard !item.text.isEmpty else { return }
            let fontSize: CGFloat = item.lineWidth <= 3 ? 15 : (item.lineWidth <= 5 ? 19 : 25)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: item.color,
                .shadow: shadow,
            ]
            (item.text as NSString).draw(at: item.startPoint, withAttributes: attrs)
        }
    }

    static func normalizedRect(from p1: CGPoint, to p2: CGPoint, shiftSquare: Bool = false) -> CGRect {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        if shiftSquare {
            let side = max(abs(dx), abs(dy))
            let sx = dx >= 0 ? side : -side
            let sy = dy >= 0 ? side : -side
            return CGRect(
                x: min(p1.x, p1.x + sx),
                y: min(p1.y, p1.y + sy),
                width: abs(sx),
                height: abs(sy)
            )
        }
        return CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(dx),
            height: abs(dy)
        )
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dist = hypot(dx, dy)
        guard dist >= 4 else { return }

        let angle = atan2(dy, dx)
        let headLength = max(14.0, lineWidth * 4.0)
        let headAngle: CGFloat = 0.46

        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * (headLength * 0.65),
            y: end.y - sin(angle) * (headLength * 0.65)
        )

        color.setStroke()
        color.setFill()

        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: start)
        shaft.line(to: shaftEnd)
        shaft.stroke()

        let wing1 = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let wing2 = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        let neck = CGPoint(
            x: end.x - headLength * 0.72 * cos(angle),
            y: end.y - headLength * 0.72 * sin(angle)
        )

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: wing1)
        head.line(to: neck)
        head.line(to: wing2)
        head.close()
        head.fill()
    }

    private static func drawMosaic(points: [CGPoint], brushWidth: CGFloat, sampler: ScreenBitmapSampler?) {
        guard !points.isEmpty else { return }
        let blockSize: CGFloat = brushWidth <= 3 ? 8 : (brushWidth <= 5 ? 12 : 16)
        let radius: CGFloat = blockSize * 1.4
        var visitedCells = Set<Int>()

        for pt in points {
            let minCol = Int(floor((pt.x - radius) / blockSize))
            let maxCol = Int(floor((pt.x + radius) / blockSize))
            let minRow = Int(floor((pt.y - radius) / blockSize))
            let maxRow = Int(floor((pt.y + radius) / blockSize))

            for row in minRow...maxRow {
                for col in minCol...maxCol {
                    let key = (row &* 73856093) ^ (col &* 19349663)
                    guard !visitedCells.contains(key) else { continue }
                    let cellRect = CGRect(
                        x: CGFloat(col) * blockSize,
                        y: CGFloat(row) * blockSize,
                        width: blockSize,
                        height: blockSize
                    )
                    let center = CGPoint(x: cellRect.midX, y: cellRect.midY)
                    guard hypot(center.x - pt.x, center.y - pt.y) <= radius else { continue }
                    visitedCells.insert(key)

                    if let sampler {
                        let sample = sampler.colorAt(viewPoint: center)
                        sample.nsColor.setFill()
                    } else {
                        let shade: CGFloat = ((row + col) % 2 == 0) ? 0.35 : 0.55
                        NSColor(calibratedWhite: shade, alpha: 0.92).setFill()
                    }
                    cellRect.fill()
                }
            }
        }
    }

    /// 将当前选区与标注合成为高分辨率 NSImage
    static func renderFinalImage(
        selectionRect: CGRect,
        sampler: ScreenBitmapSampler,
        annotations: [ScreenshotAnnotation]
    ) -> NSImage? {
        let scale = sampler.scaleFactor
        let pixelRect = CGRect(
            x: (selectionRect.minX * scale).rounded(),
            y: (selectionRect.minY * scale).rounded(),
            width: max((selectionRect.width * scale).rounded(), 1),
            height: max((selectionRect.height * scale).rounded(), 1)
        ).intersection(CGRect(x: 0, y: 0, width: sampler.width, height: sampler.height))

        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let baseCG = sampler.cgImage.cropping(to: pixelRect) else {
            return nil
        }

        let targetSize = NSSize(width: selectionRect.width, height: selectionRect.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelRect.width),
            pixelsHigh: Int(pixelRect.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(cgImage: baseCG, size: targetSize)
        }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            // 先画底层高清裁剪图（CGContext 默认左下角原点）
            cg.draw(baseCG, in: CGRect(origin: .zero, size: targetSize))

            // 翻转坐标系以绘制左上角原点的标注
            cg.translateBy(x: 0, y: targetSize.height)
            cg.scaleBy(x: 1, y: -1)
            cg.translateBy(x: -selectionRect.minX, y: -selectionRect.minY)

            for item in annotations {
                drawAnnotation(item, sampler: sampler)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let finalImage = NSImage(size: targetSize)
        finalImage.addRepresentation(rep)
        return finalImage
    }
}
