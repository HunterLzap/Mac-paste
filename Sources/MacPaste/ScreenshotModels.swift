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

// MARK: - 已放置标注的控制点（用于选中后调整箭头端点或矩形/圆框/画笔/荧光笔/文字四角与四边缘）

enum AnnotationHandle: Equatable {
    case arrowStart
    case arrowEnd
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

// MARK: - 标注数据结构

struct ScreenshotAnnotation: Identifiable {
    let id: UUID
    var tool: ScreenshotTool
    var color: NSColor
    var lineWidth: CGFloat
    var startPoint: CGPoint
    var endPoint: CGPoint
    var points: [CGPoint]
    var text: String
    var customFontSize: CGFloat?

    init(
        id: UUID = UUID(),
        tool: ScreenshotTool,
        color: NSColor,
        lineWidth: CGFloat,
        startPoint: CGPoint,
        endPoint: CGPoint,
        points: [CGPoint] = [],
        text: String = "",
        customFontSize: CGFloat? = nil
    ) {
        self.id = id
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.points = points
        self.text = text
        self.customFontSize = customFontSize
    }

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

    /// 计算标注在视图坐标系下的包围盒（用于选中高亮框、边界约束与拖拽命中判定）
    var boundingRect: CGRect {
        switch tool {
        case .rectangle, .ellipse, .arrow:
            return ScreenshotRenderer.normalizedRect(from: startPoint, to: endPoint)
        case .pen, .highlighter, .mosaic:
            guard let first = points.first else {
                return CGRect(origin: startPoint, size: .zero)
            }
            var minX = first.x, maxX = first.x
            var minY = first.y, maxY = first.y
            for pt in points.dropFirst() {
                minX = min(minX, pt.x)
                maxX = max(maxX, pt.x)
                minY = min(minY, pt.y)
                maxY = max(maxY, pt.y)
            }
            let pad: CGFloat = tool == .highlighter ? lineWidth * 2.0 : (tool == .mosaic ? 12.0 : lineWidth / 2.0 + 2.0)
            return CGRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
        case .text:
            let attrs = ScreenshotRenderer.textAttributes(color: color, lineWidth: lineWidth, customFontSize: customFontSize)
            let size = (text as NSString).size(withAttributes: attrs)
            return CGRect(
                x: startPoint.x,
                y: startPoint.y,
                width: max(size.width, 18),
                height: max(size.height, 18)
            )
        }
    }

    /// 选中态下可拖拽调整大小与形状的控制点列表（框选、画笔、荧光笔、文字均支持 8 方向拉伸）
    var resizeHandles: [(handle: AnnotationHandle, point: CGPoint)] {
        switch tool {
        case .arrow:
            return [
                (.arrowStart, startPoint),
                (.arrowEnd, endPoint),
            ]
        case .rectangle, .ellipse, .pen, .highlighter, .mosaic, .text:
            let r = boundingRect
            guard r.width >= 4, r.height >= 4 else { return [] }
            return [
                (.topLeft, CGPoint(x: r.minX, y: r.minY)),
                (.top, CGPoint(x: r.midX, y: r.minY)),
                (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                (.right, CGPoint(x: r.maxX, y: r.midY)),
                (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
                (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
                (.left, CGPoint(x: r.minX, y: r.midY)),
            ]
        }
    }

    /// 检测点是否命中该标注的控制点
    func hitResizeHandle(at pt: CGPoint, radius: CGFloat = 9.0) -> AnnotationHandle? {
        for item in resizeHandles {
            if hypot(pt.x - item.point.x, pt.y - item.point.y) <= radius {
                return item.handle
            }
        }
        return nil
    }

    /// 检测点是否命中该标注本体（用于鼠标悬停抓手提示与点击拖拽移动位置）
    func hitTest(_ pt: CGPoint, isSelected: Bool = false) -> Bool {
        switch tool {
        case .text:
            return boundingRect.insetBy(dx: -6, dy: -4).contains(pt)

        case .rectangle:
            let rect = ScreenshotRenderer.normalizedRect(from: startPoint, to: endPoint)
            let tol = max(7.0, lineWidth / 2.0 + 5.0)
            let outer = rect.insetBy(dx: -tol, dy: -tol)
            guard outer.contains(pt) else { return false }
            if rect.width <= tol * 2.4 || rect.height <= tol * 2.4 {
                return true
            }
            return !rect.insetBy(dx: tol, dy: tol).contains(pt)

        case .ellipse:
            let rect = ScreenshotRenderer.normalizedRect(from: startPoint, to: endPoint)
            let tol = max(7.0, lineWidth / 2.0 + 5.0)
            guard rect.insetBy(dx: -tol, dy: -tol).contains(pt) else { return false }
            let rx = max(rect.width / 2.0, 1.0)
            let ry = max(rect.height / 2.0, 1.0)
            let dx = pt.x - rect.midX
            let dy = pt.y - rect.midY
            let outerRx = rx + tol
            let outerRy = ry + tol
            let outerVal = (dx * dx) / (outerRx * outerRx) + (dy * dy) / (outerRy * outerRy)
            guard outerVal <= 1.0 else { return false }
            if rx <= tol * 1.2 || ry <= tol * 1.2 {
                return true
            }
            let innerRx = max(rx - tol, 1.0)
            let innerRy = max(ry - tol, 1.0)
            let innerVal = (dx * dx) / (innerRx * innerRx) + (dy * dy) / (innerRy * innerRy)
            return innerVal >= 1.0

        case .arrow:
            let tol = max(8.0, lineWidth * 1.8)
            return Self.distanceToSegment(pt, a: startPoint, b: endPoint) <= tol

        case .pen, .highlighter, .mosaic:
            if isSelected && boundingRect.insetBy(dx: -4, dy: -4).contains(pt) {
                return true
            }
            let tol: CGFloat = {
                switch tool {
                case .highlighter: return max(10.0, lineWidth * 2.2)
                case .mosaic: return 14.0
                default: return max(8.0, lineWidth + 5.0)
                }
            }()
            guard boundingRect.insetBy(dx: -tol, dy: -tol).contains(pt) else { return false }
            if points.count == 1 {
                return hypot(pt.x - points[0].x, pt.y - points[0].y) <= tol
            }
            guard points.count >= 2 else { return false }
            for i in 0..<(points.count - 1) {
                if Self.distanceToSegment(pt, a: points[i], b: points[i + 1]) <= tol {
                    return true
                }
            }
            return false
        }
    }

    private static func distanceToSegment(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0.0001 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq, 0.0), 1.0)
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(p.x - projX, p.y - projY)
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
            let attrs = Self.textAttributes(color: item.color, lineWidth: item.lineWidth, customFontSize: item.customFontSize)
            (item.text as NSString).draw(at: item.startPoint, withAttributes: attrs)
        }
    }

    static func textFontSize(for lineWidth: CGFloat) -> CGFloat {
        lineWidth <= 3 ? 15 : (lineWidth <= 5 ? 19 : 25)
    }

    static func textAttributes(color: NSColor, lineWidth: CGFloat, customFontSize: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        let fontSize = customFontSize ?? textFontSize(for: lineWidth)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
        // 红色、蓝色、绿色、黄色等常规彩色与深色文字完全不加阴影，保持字迹边缘纯净平滑、极度锐利清晰；
        // 仅在白色等极浅色文字时保留一层极细微极淡的柔和微暗影（防止在浅白底色上无法辨识），彻底杜绝黑重发糊的黑晕
        if isLightColor(color) {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.shadowBlurRadius = 1.2
            attrs[.shadow] = shadow
        }
        return attrs
    }

    private static func isLightColor(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return lum > 0.88
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

    // MARK: - 原地截图翻译数据与渲染

    struct InPlaceTranslationInfo {
        let text: String
        let dominantBgColor: NSColor
        let textColor: NSColor
    }

    static func drawInPlaceTranslationText(_ text: String, textColor: NSColor, in sel: CGRect) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let hPad: CGFloat = min(max(sel.width * 0.03, 10), 20)
        let vPad: CGFloat = min(max(sel.height * 0.04, 8), 16)
        let textRect = sel.insetBy(dx: hPad, dy: vPad)
        guard textRect.width > 20, textRect.height > 10 else { return }

        let baseSize: CGFloat = min(max(sel.height * 0.42, 13), 22)
        var fontSize = baseSize
        var bestAttrs = makeInPlaceAttributes(fontSize: fontSize, textColor: textColor)

        var measured = (trimmed as NSString).boundingRect(
            with: CGSize(width: textRect.width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bestAttrs
        )
        while measured.height > textRect.height && fontSize > 11 {
            fontSize -= 1.0
            bestAttrs = makeInPlaceAttributes(fontSize: fontSize, textColor: textColor)
            measured = (trimmed as NSString).boundingRect(
                with: CGSize(width: textRect.width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: bestAttrs
            )
        }

        let drawY = max(textRect.minY + (textRect.height - measured.height) / 2, textRect.minY)
        let drawRect = CGRect(x: textRect.minX, y: drawY, width: textRect.width, height: measured.height)

        (trimmed as NSString).draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bestAttrs
        )
    }

    private static func makeInPlaceAttributes(fontSize: CGFloat, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = max(fontSize * 0.22, 3)
        style.alignment = .left
        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: style
        ]
    }

    /// 将当前选区与标注合成为高分辨率 NSImage
    static func renderFinalImage(
        selectionRect: CGRect,
        sampler: ScreenBitmapSampler,
        annotations: [ScreenshotAnnotation],
        inPlaceTranslation: InPlaceTranslationInfo? = nil
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
            let cg = ctx.cgContext
            // 先画底层高清裁剪图（CGContext 默认左下角原点）
            cg.draw(baseCG, in: CGRect(origin: .zero, size: targetSize))

            // 翻转坐标系以绘制左上角原点的标注，并同步绑定 flipped = true 的 NSGraphicsContext
            // 确保 NSString.draw / NSAttributedString 等文本渲染与实时画布方向完全一致，避免导出后文字上下颠倒
            cg.translateBy(x: 0, y: targetSize.height)
            cg.scaleBy(x: 1, y: -1)
            cg.translateBy(x: -selectionRect.minX, y: -selectionRect.minY)

            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

            // 如果处于原地翻译生效状态，先在底层画出翻译后的背景与文本，替换原屏幕像素！
            if let trans = inPlaceTranslation {
                trans.dominantBgColor.setFill()
                NSBezierPath(rect: selectionRect).fill()
                drawInPlaceTranslationText(trans.text, textColor: trans.textColor, in: selectionRect)
            }

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
