import AppKit

/// 剪贴板监听：0.5s 轮询 changeCount，变化时读取内容并分类入库
final class ClipboardMonitor {
    /// MacPaste 自身回写剪贴板（如复制/粘贴历史条目、分段复制、按序粘贴）时记录的 changeCount 与内容 hash，避免把内部回写或分段内容当成新复制入库
    private static var ignoredChangeCount: Int = -1
    private static var internalHashes = Set<String>()

    static func markInternalWrite(_ text: String? = nil) {
        ignoredChangeCount = NSPasteboard.general.changeCount
        if let text, !text.isEmpty {
            internalHashes.insert(sha256Hex(of: text))
        }
    }

    private var timer: Timer?
    private var lastCount = 0
    var onChange: ((ClipboardKind) -> Void)?
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    func start() {
        lastCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastCount else { return }
        lastCount = current
        if current == Self.ignoredChangeCount { return }

        // 1. 文件 URL（Finder 复制文件时也带 string 类型，需先判）
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [NSURL],
           !urls.isEmpty {
            let paths = urls.compactMap { $0.path }.filter { !$0.isEmpty }
            if !paths.isEmpty {
                let content = paths.joined(separator: "\n")
                ingest(kind: content.count > 100 ? .longText : .shortText,
                       content: String(content.prefix(500_000)),
                       dataPath: nil, thumbPath: nil, hash: sha256Hex(of: content))
                return
            }
        }

        // 2. HTML 表格（网页/飞书等复制表格时带 text/html）
        if let htmlData = pb.data(forType: .html),
           let html = String(data: htmlData, encoding: .utf8),
           let rows = TableParser.parse(html: html),
           rows.count >= 2, rows.first?.count ?? 0 >= 2 {
            ingestTable(rows)
            return
        }

        // 3. 文本（TSV 表格启发式 → 表格类型；否则普通文本）
        if let s = pb.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let h = sha256Hex(of: s)
            if Self.internalHashes.contains(h) { return }
            // TSV 检测先做低成本预判（含 tab 且不太长），避免大文本在主线程做全量解析
            if s.count <= 60_000, s.contains("\t"),
               TableParser.looksLikeTSV(s), let rows = TableParser.parseTSV(s) {
                ingestTable(rows)
                return
            }
            ingest(kind: s.count > 100 ? .longText : .shortText,
                   content: String(s.prefix(50_000)),
                   dataPath: nil, thumbPath: nil, hash: h)
            return
        }

        // 4. 图片（PNG 优先，回落 TIFF），重活放后台线程
        let imgData = pb.data(forType: .png) ?? pb.data(forType: .tiff)
        if let d = imgData, !d.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                guard let saved = ImageStore.save(data: d) else {
                    NSLog("MacPaste: 图片入库失败（过大或无法解码）")
                    return
                }
                DispatchQueue.main.async {
                    let size = ByteCountFormatter.string(fromByteCount: Int64(saved.pngByteCount), countStyle: .file)
                    let desc = "\(saved.pixelWidth)×\(saved.pixelHeight) · \(size)"
                    self.ingest(kind: .image, content: desc,
                                dataPath: saved.dataPath, thumbPath: saved.thumbPath,
                                hash: saved.hash)
                }
            }
        }
    }

    private func ingest(kind: ClipboardKind, content: String, dataPath: String?, thumbPath: String?, hash: String, tableJson: String? = nil) {
        if store.upsert(kind: kind, content: content, dataPath: dataPath, thumbPath: thumbPath, hash: hash, tableJson: tableJson) {
            onChange?(kind)
        }
    }

    /// 表格入库：尺寸截断 → canonical TSV 作为去重 hash 与检索文本 → 行列结构存 JSON
    private func ingestTable(_ rawRows: [[String]]) {
        let rows = TableParser.cap(rawRows)
        guard rows.count >= 2, rows.first?.count ?? 0 >= 2 else { return }
        let tsv = TableParser.canonicalTSV(rows)
        guard !tsv.isEmpty else { return }
        guard let json = try? String(data: JSONEncoder().encode(rows), encoding: .utf8) else { return }
        ingest(kind: .table,
               content: String(tsv.prefix(50_000)),
               dataPath: nil, thumbPath: nil,
               hash: sha256Hex(of: tsv),
               tableJson: json)
    }
}
