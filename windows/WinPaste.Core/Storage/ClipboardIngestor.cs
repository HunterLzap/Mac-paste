using System.Text.Json;
using WinPaste.Core.Models;
using WinPaste.Core.Parsing;

namespace WinPaste.Core.Storage;

/// <summary>
/// 剪贴板内容分类与入库逻辑（与平台剪贴板监听解耦，便于单元测试与 Win32 消息循环复用）
/// </summary>
public sealed class ClipboardIngestor
{
    private readonly HistoryStore _store;
    private readonly AppPaths _paths;
    private readonly object _gate = new();
    private uint? _ignoredSequenceNumber;
    private readonly HashSet<string> _internalHashes = new(StringComparer.Ordinal);

    public ClipboardIngestor(HistoryStore store, AppPaths? paths = null)
    {
        _store = store;
        _paths = paths ?? AppPaths.Default;
    }

    public void MarkInternalWrite(uint? sequenceNumber = null, string? text = null)
    {
        lock (_gate)
        {
            if (sequenceNumber.HasValue)
                _ignoredSequenceNumber = sequenceNumber.Value;
            if (!string.IsNullOrEmpty(text))
                _internalHashes.Add(HashHelper.Sha256Hex(text));
        }
    }

    public bool ShouldIgnoreSequence(uint sequenceNumber)
    {
        lock (_gate)
        {
            return _ignoredSequenceNumber.HasValue && _ignoredSequenceNumber.Value == sequenceNumber;
        }
    }

    public bool IsInternalHash(string hash)
    {
        lock (_gate)
        {
            return _internalHashes.Contains(hash);
        }
    }

    public ClipboardKind? IngestSnapshot(
        uint sequenceNumber,
        IReadOnlyList<string>? filePaths = null,
        string? html = null,
        string? text = null,
        byte[]? imageBytes = null)
    {
        if (ShouldIgnoreSequence(sequenceNumber))
            return null;

        // 1. 文件列表（Explorer 复制文件时也可能带文本，需先判）
        if (filePaths is { Count: > 0 })
        {
            var validPaths = filePaths.Where(p => !string.IsNullOrEmpty(p)).ToArray();
            if (validPaths.Length > 0)
            {
                var content = string.Join("\n", validPaths);
                var kind = content.Length > 100 ? ClipboardKind.LongText : ClipboardKind.ShortText;
                var truncated = content.Length > 500_000 ? content[..500_000] : content;
                if (_store.Upsert(kind, truncated, null, null, HashHelper.Sha256Hex(content)))
                    return kind;
                return null;
            }
        }

        // 2. HTML 表格
        if (!string.IsNullOrEmpty(html))
        {
            var htmlRows = TableParser.ParseHtml(html);
            if (htmlRows is not null && htmlRows.Length >= 2 && htmlRows[0].Length >= 2)
                return IngestTable(htmlRows);
        }

        // 3. 文本（TSV 表格启发式 → 表格类型；否则普通文本）
        if (!string.IsNullOrWhiteSpace(text))
        {
            var h = HashHelper.Sha256Hex(text);
            if (IsInternalHash(h))
                return null;

            if (text.Length <= 60_000 && text.Contains('\t') && TableParser.LooksLikeTsv(text))
            {
                var tsvRows = TableParser.ParseTsv(text);
                if (tsvRows is not null)
                    return IngestTable(tsvRows);
            }

            var kind = text.Length > 100 ? ClipboardKind.LongText : ClipboardKind.ShortText;
            var truncated = text.Length > 50_000 ? text[..50_000] : text;
            if (_store.Upsert(kind, truncated, null, null, h))
                return kind;
            return null;
        }

        // 4. 图片
        if (imageBytes is { Length: > 0 })
            return IngestImageBytes(imageBytes);

        return null;
    }

    public ClipboardKind? IngestImageBytes(byte[] imageBytes)
    {
        var saved = ImageStore.Save(imageBytes, _paths);
        if (saved is null)
            return null;

        var sizeText = ImageStore.FormatFileSize(saved.PngByteCount);
        var desc = $"{saved.PixelWidth}×{saved.PixelHeight} · {sizeText}";
        if (_store.Upsert(ClipboardKind.Image, desc, saved.DataPath, saved.ThumbPath, saved.Hash))
            return ClipboardKind.Image;
        return null;
    }

    private ClipboardKind? IngestTable(string[][] rawRows)
    {
        var rows = TableParser.Cap(rawRows);
        if (rows.Length < 2 || rows[0].Length < 2)
            return null;

        var tsv = TableParser.CanonicalTsv(rows);
        if (string.IsNullOrEmpty(tsv))
            return null;

        var json = JsonSerializer.Serialize(rows);
        var content = tsv.Length > 50_000 ? tsv[..50_000] : tsv;
        if (_store.Upsert(ClipboardKind.Table, content, null, null, HashHelper.Sha256Hex(tsv), json))
            return ClipboardKind.Table;

        return null;
    }
}
