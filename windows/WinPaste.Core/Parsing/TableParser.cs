using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace WinPaste.Core.Parsing;

/// <summary>
/// 表格解析/序列化：HTML &lt;table&gt; 与 TSV 双路解析，统一为 string[][] 行列结构。
/// 去重 hash 基于解析后的 canonical TSV（而非原始字节），同一张表不同来源编码也能收敛。
/// </summary>
public static partial class TableParser
{
    public const int MaxRows = 300;
    public const int MaxCols = 60;
    public const int MaxCellChars = 2000;
    public const int MaxHtmlInputChars = 2_000_000;
    public const int MaxTsvChars = 200_000;
    /// <summary>展开预览渲染上限（超出仅预览）</summary>
    public const int MaxRenderRows = 100;
    public const int MaxRenderCols = 40;

    [GeneratedRegex(@"<tr[^>]*>(.*?)</tr>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex RowRegex();

    [GeneratedRegex(@"<t[dh][^>]*>(.*?)</t[dh]>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex CellRegex();

    [GeneratedRegex(@"<table[\s>]", RegexOptions.IgnoreCase)]
    private static partial Regex TableOpenRegex();

    [GeneratedRegex(@"</table[\s>]", RegexOptions.IgnoreCase)]
    private static partial Regex TableCloseRegex();

    [GeneratedRegex(@"<[^>]+>")]
    private static partial Regex TagRegex();

    [GeneratedRegex(@"&#(x?[0-9a-fA-F]+);", RegexOptions.IgnoreCase)]
    private static partial Regex NumericEntityRegex();

    // MARK: - HTML 解析

    public static string[][]? ParseHtml(string html)
    {
        if (string.IsNullOrEmpty(html) || html.Length > MaxHtmlInputChars)
            return null;

        var block = FirstTableBlock(html);
        if (block is null)
            return null;

        var rows = new List<string[]>();
        foreach (Match rowMatch in RowRegex().Matches(block))
        {
            var rowStr = rowMatch.Groups[1].Value;
            var cells = new List<string>();
            foreach (Match cellMatch in CellRegex().Matches(rowStr))
            {
                var cell = cellMatch.Groups[1].Value;
                cell = CollapseWhitespace(DecodeEntities(StripTags(cell)));
                if (cell.Length > MaxCellChars)
                    cell = cell[..MaxCellChars];
                cells.Add(cell);
            }
            if (cells.Count > 0)
                rows.Add(cells.ToArray());
        }

        return Normalized(rows.ToArray());
    }

    /// <summary>
    /// 取第一个（最外层）&lt;table&gt;…&lt;/table&gt; 块；用事件扫描处理嵌套表
    /// </summary>
    private static string? FirstTableBlock(string html)
    {
        var events = new List<(int Loc, bool IsOpen)>();
        foreach (Match m in TableOpenRegex().Matches(html))
            events.Add((m.Index, true));
        foreach (Match m in TableCloseRegex().Matches(html))
            events.Add((m.Index, false));

        if (events.Count == 0)
            return null;

        events.Sort((a, b) => a.Loc.CompareTo(b.Loc));
        var firstOpenIdx = events.FindIndex(e => e.IsOpen);
        if (firstOpenIdx < 0)
            return null;

        var firstOpen = events[firstOpenIdx].Loc;
        var depth = 0;
        for (int i = firstOpenIdx; i < events.Count; i++)
        {
            if (events[i].IsOpen)
            {
                depth++;
            }
            else
            {
                depth--;
                if (depth == 0)
                {
                    var end = Math.Min(events[i].Loc + 8, html.Length); // "</table>" 长度
                    return html[firstOpen..end];
                }
            }
        }
        return null;
    }

    private static string StripTags(string s) => TagRegex().Replace(s, " ");

    public static string DecodeEntities(string s)
    {
        if (string.IsNullOrEmpty(s))
            return string.Empty;

        var r = s
            .Replace("&amp;", "&")
            .Replace("&lt;", "<")
            .Replace("&gt;", ">")
            .Replace("&quot;", "\"")
            .Replace("&#39;", "'")
            .Replace("&apos;", "'")
            .Replace("&nbsp;", " ");

        return NumericEntityRegex().Replace(r, match =>
        {
            var body = match.Groups[1].Value;
            uint scalar;
            bool ok;
            if (body.StartsWith('x') || body.StartsWith('X'))
                ok = uint.TryParse(body.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out scalar);
            else
                ok = uint.TryParse(body, NumberStyles.Integer, CultureInfo.InvariantCulture, out scalar);

            if (ok && scalar <= 0x10FFFF && !(scalar >= 0xD800 && scalar <= 0xDFFF))
                return char.ConvertFromUtf32((int)scalar);

            return match.Value;
        });
    }

    private static string CollapseWhitespace(string s)
    {
        if (string.IsNullOrWhiteSpace(s))
            return string.Empty;

        var parts = s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return string.Join(' ', parts);
    }

    // MARK: - TSV 解析（Excel / Google Sheets / 飞书导出等）

    public static string[][]? ParseTsv(string text)
    {
        if (string.IsNullOrEmpty(text) || text.Length > MaxTsvChars)
            return null;

        var normalizedText = text.Replace("\r\n", "\n").Replace("\r", "\n");
        var rows = new List<string[]>();
        foreach (var line in normalizedText.Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(line) && !line.Contains('\t'))
                continue;

            var rawCells = line.Split('\t');
            for (int i = 0; i < rawCells.Length; i++)
            {
                if (rawCells[i].Length > MaxCellChars)
                    rawCells[i] = rawCells[i][..MaxCellChars];
            }
            rows.Add(rawCells);
        }

        return Normalized(rows.ToArray());
    }

    /// <summary>
    /// TSV 表格启发式判定：≥2 行、每行含 tab、列数众数占比 ≥80%、
    /// 首列全空行占比 ≤50%（排除缩进代码）、至少一行有 ≥2 个非空单元格
    /// </summary>
    public static bool LooksLikeTsv(string text)
    {
        if (string.IsNullOrEmpty(text) || text.Length > MaxTsvChars || !text.Contains('\t'))
            return false;

        var lines = text
            .Replace("\r\n", "\n")
            .Replace("\r", "\n")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries);

        if (lines.Length < 2 || !lines.All(l => l.Contains('\t')))
            return false;

        var colCounts = lines.Select(l => l.Split('\t').Length).ToArray();
        var maxColsSeen = colCounts.Max();
        if (maxColsSeen < 2 || maxColsSeen > MaxCols)
            return false;

        var freq = new Dictionary<int, int>();
        foreach (var c in colCounts)
            freq[c] = freq.GetValueOrDefault(c) + 1;

        var modeCount = freq.Values.Max();
        if ((double)modeCount / colCounts.Length < 0.8)
            return false;

        var emptyFirst = lines.Count(l =>
        {
            var idx = l.IndexOf('\t');
            var first = idx >= 0 ? l[..idx] : l;
            return string.IsNullOrWhiteSpace(first);
        });
        if ((double)emptyFirst / lines.Length > 0.5)
            return false;

        return lines.Any(l => l.Split('\t').Count(cell => !string.IsNullOrWhiteSpace(cell)) >= 2);
    }

    // MARK: - 规范化与序列化

    /// <summary>
    /// 去掉末尾全空行；按最大列数补齐为矩形
    /// </summary>
    public static string[][]? Normalized(string[][] rows)
    {
        var list = rows.ToList();
        while (list.Count > 0 && list[^1].All(string.IsNullOrWhiteSpace))
            list.RemoveAt(list.Count - 1);

        if (list.Count == 0)
            return null;

        var width = list.Max(r => r.Length);
        if (width < 1)
            return null;

        for (int i = 0; i < list.Count; i++)
        {
            if (list[i].Length < width)
            {
                var padded = new string[width];
                Array.Copy(list[i], padded, list[i].Length);
                for (int j = list[i].Length; j < width; j++)
                    padded[j] = string.Empty;
                list[i] = padded;
            }
        }
        return list.ToArray();
    }

    /// <summary>
    /// 应用尺寸上限（捕获时）
    /// </summary>
    public static string[][] Cap(string[][] rows)
    {
        return rows
            .Take(MaxRows)
            .Select(r => r.Take(MaxCols).ToArray())
            .ToArray();
    }

    /// <summary>
    /// 规范 TSV：行内 \t、行间 \n（同时作为去重 hash 的输入与剪贴板纯文本表示）
    /// </summary>
    public static string CanonicalTsv(IReadOnlyList<IReadOnlyList<string>> rows)
    {
        return string.Join("\n", rows.Select(r => string.Join("\t", r)));
    }

    /// <summary>
    /// 结构化 HTML（整表复制时写入剪贴板，富文本应用粘贴保持表格）
    /// </summary>
    public static string HtmlTable(IReadOnlyList<IReadOnlyList<string>> rows)
    {
        var sb = new StringBuilder("<table>");
        foreach (var row in rows)
        {
            sb.Append("<tr>");
            foreach (var cell in row)
            {
                sb.Append("<td>").Append(EscapeHtml(cell)).Append("</td>");
            }
            sb.Append("</tr>");
        }
        sb.Append("</table>");
        return sb.ToString();
    }

    public static string EscapeHtml(string s)
    {
        return s.Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;");
    }

    /// <summary>
    /// 列标：0→A, 1→B … 25→Z, 26→AA
    /// </summary>
    public static string ColumnLetter(int index)
    {
        var n = index + 1;
        var outStr = string.Empty;
        while (n > 0)
        {
            var rem = (n - 1) % 26;
            outStr = (char)('A' + rem) + outStr;
            n = (n - 1) / 26;
        }
        return outStr;
    }
}
