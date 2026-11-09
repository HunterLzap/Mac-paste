import AppKit
import ImageIO

/// 图片落盘：原图 PNG 化（TIFF→PNG 防体积爆炸）+ 256px 缩略图，按内容 SHA256 命名
enum ImageStore {
    struct Saved {
        let dataPath: String
        let thumbPath: String
        let hash: String
        let pixelWidth: Int
        let pixelHeight: Int
        let pngByteCount: Int
    }

    static let maxBytes = 50_000_000

    /// 像素指纹：解码 → 缩到 32×32 sRGB RGBA 位图（铺白底）→ SHA256。
    /// 同一张图即使 pasteboard 编码不同（PNG/TIFF、回填重编码）也得到同一指纹，用于可靠去重。
    static func pixelFingerprint(of data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let side = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        // 先铺白底：透明图合成结果确定，且 premultiplied 通道无未初始化字节
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buf = ctx.data else { return nil }
        return sha256Hex(of: Data(bytes: buf, count: side * side * 4))
    }

    static func save(data: Data) -> Saved? {
        guard !data.isEmpty, data.count < maxBytes else { return nil }

        // PNG 魔数直通：剪贴板本来就是 PNG 时跳过整图解码+重编码（截图场景的最大性能瓶颈）
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let png: Data
        if data.starts(with: pngMagic) {
            png = data
        } else if let rep = NSBitmapImageRep(data: data),
                  let p = rep.representation(using: .png, properties: [:]),
                  !p.isEmpty, p.count < maxBytes {
            png = p // TIFF 等其他格式才统一 PNG 化
        } else {
            return nil
        }

        // 以像素指纹（而非编码字节）做 hash：文件名与去重均按像素收敛
        guard let hash = pixelFingerprint(of: data) else { return nil }
        try? FileManager.default.createDirectory(at: AppPaths.imagesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.thumbsDir, withIntermediateDirectories: true)

        let imgURL = AppPaths.imagesDir.appendingPathComponent("\(hash).png")
        let thumbURL = AppPaths.thumbsDir.appendingPathComponent("\(hash).png")

        if !FileManager.default.fileExists(atPath: imgURL.path) {
            try? png.write(to: imgURL)
        }
        if !FileManager.default.fileExists(atPath: thumbURL.path) {
            if let cg = makeThumbnail(from: data) {
                if let td = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? td.write(to: thumbURL)
                }
            }
        }

        // 像素尺寸（不解码整图）
        // 像素尺寸（不解码整图）
        var w = 0, h = 0
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        if w == 0, let rep2 = NSBitmapImageRep(data: png) {
            w = rep2.pixelsWide; h = rep2.pixelsHigh
        }

        return Saved(dataPath: imgURL.path, thumbPath: thumbURL.path, hash: hash,
                     pixelWidth: w, pixelHeight: h, pngByteCount: png.count)
    }

    private static func makeThumbnail(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: - 缩略图缓存

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    static func cachedThumb(at path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}
