using Microsoft.Data.Sqlite;
using WinPaste.Core.Models;

namespace WinPaste.Core.Storage;

/// <summary>
/// SQLite 直连的历史存储：插入去重、搜索、分页、置顶、淘汰、清空
/// </summary>
public sealed class HistoryStore : IDisposable
{
    private readonly AppPaths _paths;
    private readonly Func<int> _historyLimitProvider;
    private readonly SqliteConnection _conn;
    private readonly object _gate = new();

    public HistoryStore(AppPaths? paths = null, Func<int>? historyLimitProvider = null)
    {
        _paths = paths ?? AppPaths.Default;
        _paths.EnsureDirectories();
        _historyLimitProvider = historyLimitProvider ?? (() => 500);

        var connStr = new SqliteConnectionStringBuilder
        {
            DataSource = _paths.DbPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false
        }.ToString();

        _conn = new SqliteConnection(connStr);
        _conn.Open();
        CreateSchema();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _conn.Dispose();
        }
    }

    private void CreateSchema()
    {
        Exec("PRAGMA journal_mode=WAL;");
        Exec("""
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
            """);
        Exec("CREATE INDEX IF NOT EXISTS idx_history_kind ON history(kind);");
        Exec("CREATE INDEX IF NOT EXISTS idx_history_hash ON history(hash);");
        Exec("CREATE INDEX IF NOT EXISTS idx_history_time ON history(pinned DESC, created_at DESC);");
        MigrateIfNeeded();
    }

    /// <summary>
    /// 迁移链：v2 图片像素指纹去重；v3 新增 table_json 列。事务 + user_version 门禁，幂等。
    /// </summary>
    private void MigrateIfNeeded()
    {
        int version = 0;
        using (var cmd = _conn.CreateCommand())
        {
            cmd.CommandText = "PRAGMA user_version;";
            var res = cmd.ExecuteScalar();
            if (res is not null && res != DBNull.Value)
                version = Convert.ToInt32(res);
        }
        if (version >= 3)
            return;

        Exec("BEGIN IMMEDIATE;");
        try
        {
            if (version < 2)
                DedupeImagesByPixelHash();

            if (!ColumnExists("history", "table_json"))
                Exec("ALTER TABLE history ADD COLUMN table_json TEXT;");

            Exec("PRAGMA user_version = 3;");
            Exec("COMMIT;");
        }
        catch
        {
            Exec("ROLLBACK;");
            throw;
        }
    }

    private bool ColumnExists(string table, string column)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = $"PRAGMA table_info({table});";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            if (string.Equals(reader.GetString(1), column, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    private void DedupeImagesByPixelHash()
    {
        var rows = new List<(long Id, string? DataPath, string? ThumbPath)>();
        using (var cmd = _conn.CreateCommand())
        {
            cmd.CommandText = "SELECT id, data_path, thumb_path FROM history WHERE kind = 2 ORDER BY created_at DESC, id DESC;";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                rows.Add((
                    reader.GetInt64(0),
                    reader.IsDBNull(1) ? null : reader.GetString(1),
                    reader.IsDBNull(2) ? null : reader.GetString(2)));
            }
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (string.IsNullOrEmpty(row.DataPath) || !File.Exists(row.DataPath))
                continue;

            byte[] data;
            try { data = File.ReadAllBytes(row.DataPath); }
            catch { continue; }

            var fp = ImageStore.PixelFingerprint(data);
            if (fp is null)
                continue;

            if (!seen.Add(fp))
            {
                RemoveFile(row.DataPath);
                RemoveFile(row.ThumbPath);
                using var del = _conn.CreateCommand();
                del.CommandText = "DELETE FROM history WHERE id = $id;";
                del.Parameters.AddWithValue("$id", row.Id);
                del.ExecuteNonQuery();
            }
            else
            {
                var newDataPath = Path.Combine(_paths.ImagesDir, $"{fp}.png");
                var newThumbPath = Path.Combine(_paths.ThumbsDir, $"{fp}.png");
                RenameReplacing(row.DataPath, newDataPath);
                RenameReplacing(row.ThumbPath, newThumbPath);

                using var upd = _conn.CreateCommand();
                upd.CommandText = "UPDATE history SET hash = $hash, data_path = $dp, thumb_path = $tp WHERE id = $id;";
                upd.Parameters.AddWithValue("$hash", fp);
                upd.Parameters.AddWithValue("$dp", newDataPath);
                upd.Parameters.AddWithValue("$tp", newThumbPath);
                upd.Parameters.AddWithValue("$id", row.Id);
                upd.ExecuteNonQuery();
            }
        }
    }

    private static void RenameReplacing(string? oldPath, string newPath)
    {
        if (string.IsNullOrEmpty(oldPath) || string.Equals(oldPath, newPath, StringComparison.OrdinalIgnoreCase))
            return;
        try
        {
            if (File.Exists(oldPath))
                File.Move(oldPath, newPath, overwrite: true);
        }
        catch
        {
            // Conservative ignore matching Swift implementation.
        }
    }

    /// <summary>
    /// 按内容去重：若已存在相同 hash 的条目，或属于已有分段条目的子段落，则不产生新条目、不打乱现有顺序。
    /// </summary>
    public bool Upsert(
        ClipboardKind kind,
        string content,
        string? dataPath,
        string? thumbPath,
        string hash,
        string? tableJson = null,
        DateTimeOffset? timestamp = null)
    {
        lock (_gate)
        {
            using (var find = _conn.CreateCommand())
            {
                find.CommandText = "SELECT id FROM history WHERE hash = $hash LIMIT 1;";
                find.Parameters.AddWithValue("$hash", hash);
                using var r = find.ExecuteReader();
                if (r.Read())
                    return false;
            }

            if ((kind == ClipboardKind.ShortText || kind == ClipboardKind.LongText) && !content.Contains('\n'))
            {
                var trimmed = content.Trim();
                if (!string.IsNullOrEmpty(trimmed) && IsSegmentOfExistingMultiLineItem(trimmed))
                    return false;
            }

            var now = (timestamp ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
            using (var ins = _conn.CreateCommand())
            {
                ins.CommandText = "INSERT INTO history(kind, content, data_path, thumb_path, hash, pinned, created_at, table_json) VALUES($kind,$content,$dp,$tp,$hash,0,$ts,$tj);";
                ins.Parameters.AddWithValue("$kind", (int)kind);
                ins.Parameters.AddWithValue("$content", content);
                ins.Parameters.AddWithValue("$dp", (object?)dataPath ?? DBNull.Value);
                ins.Parameters.AddWithValue("$tp", (object?)thumbPath ?? DBNull.Value);
                ins.Parameters.AddWithValue("$hash", hash);
                ins.Parameters.AddWithValue("$ts", now);
                ins.Parameters.AddWithValue("$tj", (object?)tableJson ?? DBNull.Value);
                ins.ExecuteNonQuery();
            }

            EvictIfNeeded();
            return true;
        }
    }

    private bool IsSegmentOfExistingMultiLineItem(string trimmed)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = "SELECT content FROM history WHERE (kind = 0 OR kind = 1) AND content LIKE '%' || char(10) || '%' ORDER BY created_at DESC LIMIT 30;";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            if (!reader.IsDBNull(0))
            {
                var c = reader.GetString(0);
                if (ParagraphParser.Parse(c).Contains(trimmed, StringComparer.Ordinal))
                    return true;
            }
        }
        return false;
    }

    public void SetPinned(long id, bool pinned)
    {
        lock (_gate)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "UPDATE history SET pinned = $pinned WHERE id = $id;";
            cmd.Parameters.AddWithValue("$pinned", pinned ? 1 : 0);
            cmd.Parameters.AddWithValue("$id", id);
            cmd.ExecuteNonQuery();
        }
    }

    public void Delete(long id)
    {
        lock (_gate)
        {
            using (var sel = _conn.CreateCommand())
            {
                sel.CommandText = "SELECT data_path, thumb_path FROM history WHERE id = $id;";
                sel.Parameters.AddWithValue("$id", id);
                using var reader = sel.ExecuteReader();
                if (reader.Read())
                {
                    RemoveFile(reader.IsDBNull(0) ? null : reader.GetString(0));
                    RemoveFile(reader.IsDBNull(1) ? null : reader.GetString(1));
                }
            }

            using var del = _conn.CreateCommand();
            del.CommandText = "DELETE FROM history WHERE id = $id;";
            del.Parameters.AddWithValue("$id", id);
            del.ExecuteNonQuery();
        }
    }

    /// <summary>
    /// 清空历史；keepPinned=true 时保留置顶条目（含文件只删未保留行的）
    /// </summary>
    public void ClearAll(bool keepPinned = true)
    {
        lock (_gate)
        {
            var whereClause = keepPinned ? "WHERE pinned = 0" : string.Empty;
            using (var sel = _conn.CreateCommand())
            {
                sel.CommandText = $"SELECT data_path, thumb_path FROM history {whereClause};";
                using var reader = sel.ExecuteReader();
                while (reader.Read())
                {
                    RemoveFile(reader.IsDBNull(0) ? null : reader.GetString(0));
                    RemoveFile(reader.IsDBNull(1) ? null : reader.GetString(1));
                }
            }
            Exec($"DELETE FROM history {whereClause};");
        }
    }

    public List<ClipboardItem> Fetch(ClipboardKind kind, string? search, int limit = 1000)
    {
        lock (_gate)
        {
            var hasSearch = !string.IsNullOrEmpty(search);
            var sql = "SELECT id, kind, content, data_path, thumb_path, pinned, created_at, table_json FROM history WHERE kind = $kind";
            if (hasSearch)
                sql += @" AND content LIKE $kw ESCAPE '\'";
            sql += " ORDER BY pinned DESC, created_at DESC LIMIT $limit;";

            using var cmd = _conn.CreateCommand();
            cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("$kind", (int)kind);
            if (hasSearch)
                cmd.Parameters.AddWithValue("$kw", EscapeLikePattern(search!));
            cmd.Parameters.AddWithValue("$limit", limit);

            var items = new List<ClipboardItem>();
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var id = reader.GetInt64(0);
                var k = Enum.IsDefined(typeof(ClipboardKind), reader.GetInt32(1))
                    ? (ClipboardKind)reader.GetInt32(1)
                    : ClipboardKind.ShortText;
                var content = reader.IsDBNull(2) ? string.Empty : reader.GetString(2);
                var dataPath = reader.IsDBNull(3) ? null : reader.GetString(3);
                var thumbPath = reader.IsDBNull(4) ? null : reader.GetString(4);
                var pinned = reader.GetInt32(5) != 0;
                var sec = reader.GetDouble(6);
                var createdAt = DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(sec * 1000.0));
                var tableJson = reader.IsDBNull(7) ? null : reader.GetString(7);

                items.Add(new ClipboardItem(id, k, content, dataPath, thumbPath, pinned, createdAt, tableJson));
            }
            return items;
        }
    }

    public int Count(ClipboardKind kind, string? search)
    {
        lock (_gate)
        {
            var hasSearch = !string.IsNullOrEmpty(search);
            var sql = "SELECT COUNT(*) FROM history WHERE kind = $kind";
            if (hasSearch)
                sql += @" AND content LIKE $kw ESCAPE '\'";
            sql += ";";

            using var cmd = _conn.CreateCommand();
            cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("$kind", (int)kind);
            if (hasSearch)
                cmd.Parameters.AddWithValue("$kw", EscapeLikePattern(search!));

            var res = cmd.ExecuteScalar();
            return res is null || res == DBNull.Value ? 0 : Convert.ToInt32(res);
        }
    }

    private void EvictIfNeeded()
    {
        var limit = Math.Max(1, _historyLimitProvider());
        var ids = new List<long>();
        var files = new List<string>();

        using (var cmd = _conn.CreateCommand())
        {
            cmd.CommandText = """
                SELECT id, data_path, thumb_path FROM history
                WHERE pinned = 0 AND id NOT IN (
                    SELECT id FROM history WHERE pinned = 0 ORDER BY created_at DESC, id DESC LIMIT $limit
                );
                """;
            cmd.Parameters.AddWithValue("$limit", limit);
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                ids.Add(reader.GetInt64(0));
                if (!reader.IsDBNull(1)) files.Add(reader.GetString(1));
                if (!reader.IsDBNull(2)) files.Add(reader.GetString(2));
            }
        }

        if (ids.Count == 0)
            return;

        foreach (var f in files)
            RemoveFile(f);

        using var del = _conn.CreateCommand();
        del.CommandText = "DELETE FROM history WHERE id = $id;";
        var p = del.Parameters.Add("$id", SqliteType.Integer);
        foreach (var id in ids)
        {
            p.Value = id;
            del.ExecuteNonQuery();
        }
    }

    private static string EscapeLikePattern(string search)
    {
        var kw = search
            .Replace(@"\", @"\\")
            .Replace("%", @"\%")
            .Replace("_", @"\_");
        return $"%{kw}%";
    }

    private void Exec(string sql)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static void RemoveFile(string? path)
    {
        if (string.IsNullOrEmpty(path))
            return;
        try
        {
            if (File.Exists(path))
                File.Delete(path);
        }
        catch
        {
            // Best-effort cleanup.
        }
    }
}
