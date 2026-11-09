import Foundation

/// 表格解析/序列化：HTML <table> 与 TSV 双路解析，统一为 [[String]] 行列结构。
/// 去重 hash 基于解析后的 canonical TSV（而非原始字节），同一张表不同来源编码也能收敛。
enum TableParser {
    static let maxRows = 300
    static let maxCols = 60
    static let maxCellChars = 2000
    static let maxHTMLInputChars = 2_000_000
    static let maxTSVChars = 200_000
    /// 展开预览渲染上限（超出仅预览）
    static let maxRenderRows = 100
    static let maxRenderCols = 40

    // MARK: - HTML 解析

    static func parse(html: String) -> [[String]]? {
        guard html.count <= maxHTMLInputChars else { return nil }
        guard let block = firstTableBlock(in: html) else { return nil }
        guard let rowRegex = try? NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>",
                                                      options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let cellRegex = try? NSRegularExpression(pattern: "<t[dh][^>]*>(.*?)</t[dh]>",
                                                       options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }

        var rows: [[String]] = []
        let bns = block as NSString
        for rowMatch in rowRegex.matches(in: block, options: [],
                                          range: NSRange(location: 0, length: bns.length)) {
            let rowStr = bns.substring(with: rowMatch.range(at: 1))
            let rns = rowStr as NSString
            var cells: [String] = []
            for cellMatch in cellRegex.matches(in: rowStr, options: [],
                                               range: NSRange(location: 0, length: rns.length)) {
                var cell = rns.substring(with: cellMatch.range(at: 1))
                cell = collapseWhitespace(decodeEntities(stripTags(cell)))
                if cell.count > maxCellChars { cell = String(cell.prefix(maxCellChars)) }
                cells.append(cell)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return normalized(rows)
    }

    /// 取第一个（最外层）<table>…</table> 块；用事件扫描处理嵌套表
    private static func firstTableBlock(in html: String) -> String? {
        guard let openRegex = try? NSRegularExpression(pattern: "<table[\\s>]", options: .caseInsensitive),
              let closeRegex = try? NSRegularExpression(pattern: "</table[\\s>]", options: .caseInsensitive) else { return nil }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        var events: [(loc: Int, isOpen: Bool)] = []
        openRegex.enumerateMatches(in: html, options: [], range: full) { m, _, _ in
            if let m { events.append((m.range.location, true)) }
        }
        closeRegex.enumerateMatches(in: html, options: [], range: full) { m, _, _ in
            if let m { events.append((m.range.location, false)) }
        }
        guard let firstOpen = events.first(where: { $0.isOpen })?.loc else { return nil }
        var depth = 0
        for (loc, isOpen) in events.filter({ $0.loc >= firstOpen }).sorted(by: { $0.loc < $1.loc }) {
            if isOpen {
                depth += 1
            } else {
                depth -= 1
                if depth == 0 {
                    let end = min(loc + 8, ns.length) // "</table>" 长度
                    return ns.substring(with: NSRange(location: firstOpen, length: end - firstOpen))
                }
            }
        }
        return nil
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    static func decodeEntities(_ s: String) -> String {
        var r = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in named { r = r.replacingOccurrences(of: k, with: v) }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);", options: .caseInsensitive) else { return r }
        let ns = r as NSString
        var out = ""
        var cursor = 0
        for m in regex.matches(in: r, options: [], range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let body = ns.substring(with: m.range(at: 1))
            let scalar: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalar = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(body, radix: 10)
            }
            if let v = scalar, let uni = Unicode.Scalar(v) {
                out += String(Character(uni))
            } else {
                out += ns.substring(with: m.range)
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - TSV 解析（Excel / Google Sheets / 飞书导出等）

    static func parseTSV(_ text: String) -> [[String]]? {
        guard text.count <= maxTSVChars else { return nil }
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        for line in normalizedText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty && !line.contains("\t") { continue }
            let cells = line.components(separatedBy: "\t").map { c -> String in
                let t = String(c)
                return t.count > maxCellChars ? String(t.prefix(maxCellChars)) : t
            }
            rows.append(cells)
        }
        return normalized(rows)
    }

    /// TSV 表格启发式判定：≥2 行、每行含 tab、列数众数占比 ≥80%、
    /// 首列全空行占比 ≤50%（排除缩进代码）、至少一行有 ≥2 个非空单元格
    static func looksLikeTSV(_ text: String) -> Bool {
        guard text.count <= maxTSVChars, text.contains("\t") else { return false }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map { String($0) }
        guard lines.count >= 2, lines.allSatisfy({ $0.contains("\t") }) else { return false }
        let colCounts = lines.map { $0.components(separatedBy: "\t").count }
        guard let maxColsSeen = colCounts.max(), maxColsSeen >= 2, maxColsSeen <= maxCols else { return false }
        var freq: [Int: Int] = [:]
        for c in colCounts { freq[c, default: 0] += 1 }
        guard let modeCount = freq.values.max() else { return false }
        guard Double(modeCount) / Double(colCounts.count) >= 0.8 else { return false }
        let emptyFirst = lines.filter {
            $0.components(separatedBy: "\t").first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true
        }.count
        guard Double(emptyFirst) / Double(lines.count) <= 0.5 else { return false }
        return lines.contains { line in
            line.components(separatedBy: "\t").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
        }
    }

    // MARK: - 规范化与序列化

    /// 去掉末尾全空行；按最大列数补齐为矩形
    static func normalized(_ rows: [[String]]) -> [[String]]? {
        var rows = rows
        while let last = rows.last, last.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            rows.removeLast()
        }
        guard !rows.isEmpty else { return nil }
        let width = rows.map(\.count).max() ?? 0
        guard width >= 1 else { return nil }
        return rows.map { row -> [String] in
            var r = row
            if r.count < width { r.append(contentsOf: Array(repeating: "", count: width - r.count)) }
            return r
        }
    }

    /// 应用尺寸上限（捕获时）
    static func cap(_ rows: [[String]]) -> [[String]] {
        Array(rows.prefix(maxRows)).map { Array($0.prefix(maxCols)) }
    }

    /// 规范 TSV：行内 \t、行间 \n（同时作为去重 hash 的输入与剪贴板纯文本表示）
    static func canonicalTSV(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// 结构化 HTML（整表复制时写入剪贴板，富文本应用粘贴保持表格）
    static func htmlTable(_ rows: [[String]]) -> String {
        var out = "<table>"
        for row in rows {
            out += "<tr>"
            for cell in row {
                out += "<td>\(escapeHTML(cell))</td>"
            }
            out += "</tr>"
        }
        out += "</table>"
        return out
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 列标：0→A, 1→B … 25→Z, 26→AA
    static func columnLetter(_ index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 {
            let rem = (n - 1) % 26
            out = String(Character(UnicodeScalar(65 + rem)!)) + out
            n = (n - 1) / 26
        }
        return out
    }
}
