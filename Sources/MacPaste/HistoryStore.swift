import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite 直连的历史存储：插入去重、搜索、分页、置顶、淘汰、清空
final class HistoryStore {
    private var db: OpaquePointer?

    private var limit: Int {
        let v = UserDefaults.standard.object(forKey: "historyLimit") as? Int
        return v ?? 500
    }

    init() {
        AppPaths.ensureDirectories()
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(AppPaths.dbPath.path, &db, flags, nil) == SQLITE_OK else {
            NSLog("MacPaste: 无法打开数据库 \(AppPaths.dbPath.path)")
            db = nil
            return
        }
        createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func createSchema() {
        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind INTEGER NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            data_path TEXT,
            thumb_path TEXT,
            hash TEXT NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_history_kind ON history(kind);")
        exec("CREATE INDEX IF NOT EXISTS idx_history_hash ON history(hash);")
        exec("CREATE INDEX IF NOT EXISTS idx_history_time ON history(pinned DESC, created_at DESC);")
        migrateIfNeeded()
    }

    // MARK: - 迁移

    /// 迁移链：v2 图片像素指纹去重；v3 新增 table_json 列。事务 + user_version 门禁，幂等。
    private func migrateIfNeeded() {
        var version: Int32 = 0
        if let stmt = prepare("PRAGMA user_version;") {
            if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        guard version < 3 else { return }
        exec("BEGIN IMMEDIATE;")
        if version < 2 { dedupeImagesByPixelHash() }
        exec("ALTER TABLE history ADD COLUMN table_json TEXT;")
        exec("PRAGMA user_version = 3;")
        exec("COMMIT;")
    }

    private func dedupeImagesByPixelHash() {
        guard let stmt = prepare("SELECT id, data_path, thumb_path FROM history WHERE kind = 2 ORDER BY created_at DESC, id DESC;") else { return }
        var rows: [(id: Int64, dataPath: String?, thumbPath: String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0),
                         sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                         sqlite3_column_text(stmt, 2).map { String(cString: $0) }))
        }
        sqlite3_finalize(stmt)

        var seen = Set<String>()
        for row in rows {
            guard let p = row.dataPath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                  let fp = ImageStore.pixelFingerprint(of: data) else { continue } // 文件缺失/解码失败：保守跳过
            if seen.contains(fp) {
                // 同图旧条目：删行 + 删文件
                removeFile(row.dataPath)
                removeFile(row.thumbPath)
                if let del = prepare("DELETE FROM history WHERE id = ?;") {
                    sqlite3_bind_int64(del, 1, row.id)
                    sqlite3_step(del)
                    sqlite3_finalize(del)
                }
            } else {
                seen.insert(fp)
                // 统一文件命名为像素指纹
                let newDataPath = AppPaths.imagesDir.appendingPathComponent("\(fp).png").path
                let newThumbPath = AppPaths.thumbsDir.appendingPathComponent("\(fp).png").path
                renameReplacing(row.dataPath, to: newDataPath)
                renameReplacing(row.thumbPath, to: newThumbPath)
                if let upd = prepare("UPDATE history SET hash = ?, data_path = ?, thumb_path = ? WHERE id = ?;") {
                    sqlite3_bind_text(upd, 1, fp, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(upd, 2, newDataPath, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(upd, 3, newThumbPath, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(upd, 4, row.id)
                    sqlite3_step(upd)
                    sqlite3_finalize(upd)
                }
            }
        }
    }

    private func renameReplacing(_ oldPath: String?, to newPath: String) {
        guard let oldPath, !oldPath.isEmpty, oldPath != newPath else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: newPath) { try? fm.removeItem(atPath: newPath) }
        if fm.fileExists(atPath: oldPath) {
            try? fm.moveItem(atPath: oldPath, toPath: newPath)
        }
    }

    // MARK: - 写入

    /// 按内容去重：若已存在相同 hash 的条目，或属于已有分段条目的子段落，则不产生新条目、不打乱现有顺序。
    @discardableResult
    func upsert(kind: ClipboardKind, content: String, dataPath: String?, thumbPath: String?, hash: String, tableJson: String? = nil) -> Bool {
        guard db != nil else { return false }
        let now = Date().timeIntervalSince1970

        if let find = prepare("SELECT id FROM history WHERE hash = ? LIMIT 1;") {
            sqlite3_bind_text(find, 1, hash, -1, SQLITE_TRANSIENT)
            if sqlite3_step(find) == SQLITE_ROW {
                sqlite3_finalize(find)
                // 已存在相同内容：保持原条目位置，不产生新条目也不打乱列表
                return false
            }
            sqlite3_finalize(find)
        }

        // 若复制的是单段文本，且该段内容已包含在现有的多段历史记录中，则不重复生成碎片条目
        if (kind == .shortText || kind == .longText), !content.contains("\n") {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, isSegmentOfExistingMultiLineItem(trimmed) {
                return false
            }
        }

        if let ins = prepare("INSERT INTO history(kind, content, data_path, thumb_path, hash, pinned, created_at, table_json) VALUES(?,?,?,?,?,0,?,?);") {
            sqlite3_bind_int(ins, 1, Int32(kind.rawValue))
            sqlite3_bind_text(ins, 2, content, -1, SQLITE_TRANSIENT)
            bindOptionalText(ins, 3, dataPath)
            bindOptionalText(ins, 4, thumbPath)
            sqlite3_bind_text(ins, 5, hash, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(ins, 6, now)
            bindOptionalText(ins, 7, tableJson)
            sqlite3_step(ins)
            sqlite3_finalize(ins)
            evictIfNeeded()
            return true
        }
        return false
    }

    private func isSegmentOfExistingMultiLineItem(_ trimmed: String) -> Bool {
        guard let stmt = prepare("SELECT content FROM history WHERE (kind = 0 OR kind = 1) AND content LIKE '%' || char(10) || '%' ORDER BY created_at DESC LIMIT 30;") else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) {
                if parseParagraphs(c).contains(trimmed) {
                    return true
                }
            }
        }
        return false
    }

    func setPinned(id: Int64, pinned: Bool) {
        guard let stmt = prepare("UPDATE history SET pinned = ? WHERE id = ?;") else { return }
        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func delete(id: Int64) {
        if let stmt = prepare("SELECT data_path, thumb_path FROM history WHERE id = ?;") {
            sqlite3_bind_int64(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                removeFile(sqlite3_column_text(stmt, 0).map { String(cString: $0) })
                removeFile(sqlite3_column_text(stmt, 1).map { String(cString: $0) })
            }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare("DELETE FROM history WHERE id = ?;") {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// 清空历史；keepPinned=true 时保留置顶条目（含文件只删未保留行的）
    func clearAll(keepPinned: Bool = true) {
        let whereClause = keepPinned ? "WHERE pinned = 0" : ""
        if let stmt = prepare("SELECT data_path, thumb_path FROM history \(whereClause);") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                removeFile(sqlite3_column_text(stmt, 0).map { String(cString: $0) })
                removeFile(sqlite3_column_text(stmt, 1).map { String(cString: $0) })
            }
            sqlite3_finalize(stmt)
        }
        exec("DELETE FROM history \(whereClause);")
    }

    // MARK: - 读取

    func fetch(kind: ClipboardKind, search: String?, limit: Int = 1000) -> [ClipboardItem] {
        guard db != nil else { return [] }
        let hasSearch = !(search ?? "").isEmpty
        var sql = "SELECT id, kind, content, data_path, thumb_path, pinned, created_at, table_json FROM history WHERE kind = ?"
        if hasSearch { sql += " AND content LIKE ? ESCAPE '\\'" }
        sql += " ORDER BY pinned DESC, created_at DESC LIMIT ?;"

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        sqlite3_bind_int(stmt, idx, Int32(kind.rawValue)); idx += 1
        if hasSearch {
            var kw = search!
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            kw = "%\(kw)%"
            sqlite3_bind_text(stmt, idx, kw, -1, SQLITE_TRANSIENT); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var items: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let k = ClipboardKind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .shortText
            let content = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let dataPath = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let thumbPath = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let pinned = sqlite3_column_int(stmt, 5) != 0
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let tableJson = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            items.append(ClipboardItem(id: id, kind: k, content: content,
                                       dataPath: dataPath, thumbPath: thumbPath,
                                       pinned: pinned, createdAt: createdAt,
                                       tableJson: tableJson))
        }
        return items
    }

    func count(kind: ClipboardKind, search: String?) -> Int {
        guard db != nil else { return 0 }
        let hasSearch = !(search ?? "").isEmpty
        var sql = "SELECT COUNT(*) FROM history WHERE kind = ?"
        if hasSearch { sql += " AND content LIKE ? ESCAPE '\\'" }
        sql += ";"
        guard let stmt = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        sqlite3_bind_int(stmt, idx, Int32(kind.rawValue)); idx += 1
        if hasSearch {
            var kw = search!
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            kw = "%\(kw)%"
            sqlite3_bind_text(stmt, idx, kw, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 淘汰

    /// 超出上限时淘汰最旧的非置顶条目（含其图片文件）
    private func evictIfNeeded() {
        guard let stmt = prepare("""
            SELECT id, data_path, thumb_path FROM history
            WHERE pinned = 0 AND id NOT IN (
                SELECT id FROM history WHERE pinned = 0 ORDER BY created_at DESC, id DESC LIMIT ?
            );
            """) else { return }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var ids: [Int64] = []
        var files: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
            if let dp = sqlite3_column_text(stmt, 1) { files.append(String(cString: dp)) }
            if let tp = sqlite3_column_text(stmt, 2) { files.append(String(cString: tp)) }
        }
        sqlite3_finalize(stmt)
        guard !ids.isEmpty else { return }
        for f in files { try? FileManager.default.removeItem(atPath: f) }
        if let del = prepare("DELETE FROM history WHERE id = ?;") {
            for id in ids {
                sqlite3_reset(del)
                sqlite3_clear_bindings(del)
                sqlite3_bind_int64(del, 1, id)
                sqlite3_step(del)
            }
            sqlite3_finalize(del)
        }
    }

    // MARK: - 内部工具

    private func exec(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            NSLog("MacPaste SQL error: \(msg) | sql: \(sql)")
        }
        if let errMsg { sqlite3_free(errMsg) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("MacPaste prepare failed: \(sql)")
            return nil
        }
        return stmt
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s {
            sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, i)
        }
    }

    private func removeFile(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
