import Foundation
import CryptoKit

/// 条目分类：短文本 / 长文本 / 图片 / 表格（文件路径按内容长度落入文本类）
enum ClipboardKind: Int, CaseIterable, Hashable {
    case shortText = 0
    case longText = 1
    case image = 2
    case table = 3

    var tabTitle: String {
        switch self {
        case .shortText: return "短文本"
        case .longText: return "长文本"
        case .image: return "图片"
        case .table: return "表格"
        }
    }
}

struct ClipboardItem: Identifiable, Equatable {
    let id: Int64
    let kind: ClipboardKind
    let content: String
    let dataPath: String?
    let thumbPath: String?
    let pinned: Bool
    let createdAt: Date
    /// 表格条目专用：[[String]] 行列结构的 JSON（其他类型为 nil）
    let tableJson: String?
    /// 文本条目专用：按空行（连续换行）自动解析出的多段列表（不足 2 段时为空数组）
    let paragraphs: [String]

    init(id: Int64, kind: ClipboardKind, content: String, dataPath: String?, thumbPath: String?, pinned: Bool, createdAt: Date, tableJson: String?) {
        self.id = id
        self.kind = kind
        self.content = content
        self.dataPath = dataPath
        self.thumbPath = thumbPath
        self.pinned = pinned
        self.createdAt = createdAt
        self.tableJson = tableJson
        if kind == .shortText || kind == .longText {
            self.paragraphs = parseParagraphs(content)
        } else {
            self.paragraphs = []
        }
    }
}

/// 自动分段：只要内容中间有换行，每一行（过滤空行后）就算一段；不足 2 段时返回空数组
func parseParagraphs(_ text: String) -> [String] {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\u{2028}", with: "\n")
        .replacingOccurrences(of: "\u{2029}", with: "\n")
    guard normalized.contains("\n") else { return [] }
    let lines = normalized
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return lines.count >= 2 ? lines : []
}

enum AppPaths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacPaste", isDirectory: true)
    }()
    static let imagesDir = supportDir.appendingPathComponent("images", isDirectory: true)
    static let thumbsDir = supportDir.appendingPathComponent("thumbs", isDirectory: true)
    static var dbPath: URL { supportDir.appendingPathComponent("history.db") }

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
    }
}

func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(of string: String) -> String {
    sha256Hex(of: Data(string.utf8))
}

/// 分钟级相对时间（不含秒）
private let _dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func relativeTimeShort(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86400 { return "\(seconds / 3600) 小时前" }
    if seconds < 86400 * 30 { return "\(seconds / 86400) 天前" }
    return _dayFormatter.string(from: date)
}

/// 列表展示用截断：避免超长文本进入 SwiftUI Text 布局（大文本是列表卡顿的主因）
func displayTruncate(_ s: String, _ limit: Int = 300) -> String {
    s.count > limit ? String(s.prefix(limit)) : s
}
