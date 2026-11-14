import AppKit
import CoreGraphics

// MARK: - OCR 分块结果模型

struct OCRTextBlock {
    let text: String
    /// 归一化坐标（左上角为原点，x/y/width/height 均在 0...1 之间）
    let normalizedRect: CGRect
    /// 归一化单行文字平均高度（不含行间距），用于准确推断字号与字重
    let normalizedLineHeight: CGFloat
    let lineCount: Int
    let isCentered: Bool
}

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

    /// 截图模式主题强调色（与剪贴板浅色系及 macOS 系统蓝保持一致）
    static let themeAccent = NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 1.0)
    static let themeGlow = NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 0.24)

    /// 浅色 HUD 视觉色板（与剪贴板主窗口浅灰白面板风格一致）
    static let surfaceBackground = NSColor(calibratedRed: 0.975, green: 0.980, blue: 0.990, alpha: 0.96)
    static let cardBackground = NSColor(calibratedRed: 0.995, green: 0.997, blue: 1.000, alpha: 0.98)
    static let surfaceBorder = NSColor.black.withAlphaComponent(0.12)
    static let dividerColor = NSColor.black.withAlphaComponent(0.10)
    static let primaryText = NSColor(calibratedWhite: 0.14, alpha: 1.0)
    static let secondaryText = NSColor(calibratedWhite: 0.46, alpha: 1.0)
    static let disabledIcon = NSColor.black.withAlphaComponent(0.26)
    static let hoverFill = NSColor.black.withAlphaComponent(0.06)
    static let selectedSoftFill = NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 0.14)
    static let screenMask = NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 0.26)
}

// MARK: - 屏幕像素采样器（用于实时放大镜预览与色值提取、马赛克取色）

final class ScreenBitmapSampler {
    let cgImage: CGImage
    let width: Int
    let height: Int
    let scaleFactor: CGFloat
    let cgColorSpace: CGColorSpace
    let nsColorSpace: NSColorSpace
    private let pixelData: [UInt8]

    init(cgImage: CGImage, scaleFactor: CGFloat) {
        self.cgImage = cgImage
        self.width = cgImage.width
        self.height = cgImage.height
        self.scaleFactor = max(scaleFactor, 1.0)

        let resolvedCGColorSpace: CGColorSpace = {
            if let cs = cgImage.colorSpace, cs.model == .rgb {
                return cs
            }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()
        self.cgColorSpace = resolvedCGColorSpace
        self.nsColorSpace = NSColorSpace(cgColorSpace: resolvedCGColorSpace) ?? .sRGB

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        if let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: resolvedCGColorSpace,
            bitmapInfo: bitmapInfo
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.pixelData = buffer
    }

    /// 使用采样器原始色彩空间构造 NSColor，避免 calibrated/deviceRGB 转换导致渐变色差
    func makeColor(r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat = 1.0) -> NSColor {
        let components: [CGFloat] = [r, g, b, alpha]
        return NSColor(colorSpace: nsColorSpace, components: components, count: 4)
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
        let color = makeColor(
            r: CGFloat(r) / 255.0,
            g: CGFloat(g) / 255.0,
            b: CGFloat(b) / 255.0
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

    struct InPlaceTranslatedBlock {
        var rect: CGRect          // 在翻转视图坐标系 (selectionRect 所在坐标系) 下的文本块原位矩形
        let sourceText: String
        let translatedText: String
        let bgColor: NSColor
        let stripColors: [(top: NSColor, bottom: NSColor)]
        let textColor: NSColor
        let lineCount: Int
        let trueLineHeight: CGFloat
        let isBold: Bool
        let isCentered: Bool
        let fontWeight: NSFont.Weight
    }

    struct InPlaceTranslationInfo {
        let blocks: [InPlaceTranslatedBlock]
    }

    private struct PreparedInPlaceBlockDraw {
        let coverRect: CGRect
        let textDrawRect: CGRect
        let bgColor: NSColor
        let stripColors: [(top: NSColor, bottom: NSColor)]
        let text: String
        let attrs: [NSAttributedString.Key: Any]
    }

    static func drawInPlaceTranslationBlocks(_ blocks: [InPlaceTranslatedBlock], in sel: CGRect) {
        guard !blocks.isEmpty else { return }

        var prepared: [PreparedInPlaceBlockDraw] = []
        prepared.reserveCapacity(blocks.count)

        for (idx, block) in blocks.enumerated() {
            let trimmed = block.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let baseRect = block.rect.intersection(sel)
            guard !baseRect.isNull, baseRect.width >= 2, baseRect.height >= 2 else { continue }

            let fontWeight = block.fontWeight
            let alignment: NSTextAlignment = block.isCentered ? .center : .left
            let effectiveLineH = block.trueLineHeight > 0
                ? block.trueLineHeight
                : (baseRect.height / CGFloat(max(block.lineCount, 1)))
            let attrs: [NSAttributedString.Key: Any]
            let textDrawRect: CGRect

            if block.lineCount <= 1 {
                // 计算同行左右两侧无其他文本块遮挡的可扩展宽度上限
                var leftLimit = sel.minX + 4.0
                var rightLimit = sel.maxX - 4.0
                for (otherIdx, other) in blocks.enumerated() where otherIdx != idx {
                    let otherRect = other.rect.intersection(sel)
                    guard !otherRect.isNull else { continue }
                    let overlapY = min(otherRect.maxY, baseRect.maxY) - max(otherRect.minY, baseRect.minY)
                    guard overlapY > 2.0 else { continue }
                    if otherRect.minX >= baseRect.maxX - 2.0 {
                        rightLimit = min(rightLimit, otherRect.minX - 6.0)
                    } else if otherRect.maxX <= baseRect.minX + 2.0 {
                        leftLimit = max(leftLimit, otherRect.maxX + 6.0)
                    }
                }
                let maxSingleLineWidth: CGFloat
                if block.isCentered {
                    let halfAvail = min(baseRect.midX - leftLimit, rightLimit - baseRect.midX)
                    maxSingleLineWidth = max(baseRect.width, halfAvail * 2.0)
                } else {
                    maxSingleLineWidth = max(baseRect.width, rightLimit - baseRect.minX)
                }

                let initialFontSize = min(max(effectiveLineH * 0.80, 11.0), 64.0)
                let minFontSize = max(10.0, initialFontSize * 0.62)
                var fontSize = initialFontSize
                var currentAttrs = makeInPlaceAttributes(
                    fontSize: fontSize,
                    weight: fontWeight,
                    textColor: block.textColor,
                    alignment: alignment
                )
                var singleSize = (trimmed as NSString).size(withAttributes: currentAttrs)

                while singleSize.width > baseRect.width + 2.0 && fontSize > minFontSize {
                    fontSize = max(minFontSize, fontSize - 0.5)
                    currentAttrs = makeInPlaceAttributes(
                        fontSize: fontSize,
                        weight: fontWeight,
                        textColor: block.textColor,
                        alignment: alignment
                    )
                    singleSize = (trimmed as NSString).size(withAttributes: currentAttrs)
                }

                attrs = currentAttrs
                if singleSize.width + 2.0 <= maxSingleLineWidth {
                    let drawW = max(baseRect.width, min(ceil(singleSize.width) + 2.0, maxSingleLineWidth))
                    let drawH = ceil(singleSize.height)
                    let rawDrawX = block.isCentered ? (baseRect.midX - drawW / 2.0) : baseRect.minX
                    let drawX = min(max(rawDrawX, sel.minX + 2.0), max(sel.minX + 2.0, sel.maxX - drawW - 2.0))
                    let drawY = min(
                        max(baseRect.midY - drawH / 2.0, sel.minY + 1.0),
                        max(sel.minY + 1.0, sel.maxY - drawH - 1.0)
                    )
                    textDrawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)
                } else {
                    let measured = (trimmed as NSString).boundingRect(
                        with: CGSize(width: maxSingleLineWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: currentAttrs
                    )
                    let wrappedH = min(ceil(measured.height), max(baseRect.height, sel.maxY - baseRect.minY - 2.0))
                    let rawDrawX = block.isCentered ? (baseRect.midX - maxSingleLineWidth / 2.0) : baseRect.minX
                    let drawX = min(max(rawDrawX, sel.minX + 2.0), max(sel.minX + 2.0, sel.maxX - maxSingleLineWidth - 2.0))
                    let drawY = min(
                        max(baseRect.minY, sel.minY + 1.0),
                        max(sel.minY + 1.0, sel.maxY - wrappedH - 1.0)
                    )
                    textDrawRect = CGRect(x: drawX, y: drawY, width: maxSingleLineWidth, height: wrappedH)
                }
            } else {
                let initialFontSize = min(max(effectiveLineH * 0.82, 11.0), 56.0)
                var fontSize = initialFontSize
                var currentAttrs = makeInPlaceAttributes(
                    fontSize: fontSize,
                    weight: fontWeight,
                    textColor: block.textColor,
                    alignment: alignment
                )
                var measured = (trimmed as NSString).boundingRect(
                    with: CGSize(width: baseRect.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: currentAttrs
                )

                while measured.height > baseRect.height && fontSize > 10.0 {
                    fontSize = max(10.0, fontSize - 0.5)
                    currentAttrs = makeInPlaceAttributes(
                        fontSize: fontSize,
                        weight: fontWeight,
                        textColor: block.textColor,
                        alignment: alignment
                    )
                    measured = (trimmed as NSString).boundingRect(
                        with: CGSize(width: baseRect.width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: currentAttrs
                    )
                }

                attrs = currentAttrs
                let drawH = min(ceil(measured.height), max(baseRect.height, sel.maxY - baseRect.minY - 2.0))
                let rawY: CGFloat = (block.isBold && measured.height < baseRect.height * 0.75)
                    ? (baseRect.midY - drawH / 2.0)
                    : baseRect.minY
                let drawY = min(
                    max(rawY, sel.minY + 1.0),
                    max(sel.minY + 1.0, sel.maxY - drawH - 1.0)
                )
                textDrawRect = CGRect(x: baseRect.minX, y: drawY, width: baseRect.width, height: drawH)
            }

            let coverRect = baseRect.union(textDrawRect).insetBy(dx: -4.0, dy: -2.0).intersection(sel)
            prepared.append(PreparedInPlaceBlockDraw(
                coverRect: coverRect,
                textDrawRect: textDrawRect,
                bgColor: block.bgColor,
                stripColors: block.stripColors,
                text: trimmed,
                attrs: attrs
            ))
        }

        // 先统一填充所有块背景底色（按分片裁剪绘制渐变擦除），再绘制译文，避免相邻块互相擦除
        for item in prepared {
            let radius = min(item.coverRect.height * 0.18, 4.0)
            let clipPath = NSBezierPath(roundedRect: item.coverRect, xRadius: radius, yRadius: radius)
            if item.stripColors.count >= 2 {
                NSGraphicsContext.saveGraphicsState()
                clipPath.addClip()
                let stripW = item.coverRect.width / CGFloat(item.stripColors.count)
                for (sIdx, pair) in item.stripColors.enumerated() {
                    let x0 = item.coverRect.minX + CGFloat(sIdx) * stripW
                    let stripRect = CGRect(x: x0 - 0.5, y: item.coverRect.minY, width: stripW + 1.0, height: item.coverRect.height)
                    if let grad = NSGradient(
                        colors: [pair.top, pair.bottom],
                        atLocations: [0.0, 1.0],
                        colorSpace: pair.top.colorSpace
                    ) ?? NSGradient(starting: pair.top, ending: pair.bottom) {
                        NSGraphicsContext.saveGraphicsState()
                        NSBezierPath.clip(stripRect)
                        grad.draw(
                            from: CGPoint(x: stripRect.midX, y: item.coverRect.minY),
                            to: CGPoint(x: stripRect.midX, y: item.coverRect.maxY),
                            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
                        )
                        NSGraphicsContext.restoreGraphicsState()
                    } else {
                        pair.top.setFill()
                        stripRect.fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                item.bgColor.setFill()
                clipPath.fill()
            }
        }
        for item in prepared {
            (item.text as NSString).draw(
                with: item.textDrawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: item.attrs
            )
        }
    }

    private static func makeInPlaceAttributes(
        fontSize: CGFloat,
        weight: NSFont.Weight = .regular,
        textColor: NSColor,
        alignment: NSTextAlignment = .left
    ) -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = max(fontSize * 0.16, 2.0)
        style.alignment = alignment
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
        guard let rawRep = NSBitmapImageRep(
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
        let rep = rawRep.retagging(with: sampler.nsColorSpace) ?? rawRep
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

            // 如果处于原地翻译生效状态，仅在各文本块原位覆盖背景与译文，保留其余原图视觉
            if let trans = inPlaceTranslation {
                drawInPlaceTranslationBlocks(trans.blocks, in: selectionRect)
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
