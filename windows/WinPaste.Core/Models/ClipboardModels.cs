using System.Security.Cryptography;
using System.Text;

namespace WinPaste.Core.Models;

/// <summary>
/// 条目分类：短文本 / 长文本 / 图片 / 表格（文件路径按内容长度落入文本类）
/// </summary>
public enum ClipboardKind
{
    ShortText = 0,
    LongText = 1,
    Image = 2,
    Table = 3
}

public static class ClipboardKindExtensions
{
    public static string TabTitle(this ClipboardKind kind) => kind switch
    {
        ClipboardKind.ShortText => "短文本",
        ClipboardKind.LongText => "长文本",
        ClipboardKind.Image => "图片",
        ClipboardKind.Table => "表格",
        _ => "短文本"
    };
}

public sealed record ClipboardItem
{
    public long Id { get; init; }
    public ClipboardKind Kind { get; init; }
    public string Content { get; init; } = string.Empty;
    public string? DataPath { get; init; }
    public string? ThumbPath { get; init; }
    public bool Pinned { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
    /// <summary>
    /// 表格条目专用：[[string]] 行列结构的 JSON（其他类型为 null）
    /// </summary>
    public string? TableJson { get; init; }
    /// <summary>
    /// 文本条目专用：按换行自动解析出的多段列表（不足 2 段时为空列表）
    /// </summary>
    public IReadOnlyList<string> Paragraphs { get; init; } = Array.Empty<string>();

    public ClipboardItem(
        long id,
        ClipboardKind kind,
        string content,
        string? dataPath,
        string? thumbPath,
        bool pinned,
        DateTimeOffset createdAt,
        string? tableJson)
    {
        Id = id;
        Kind = kind;
        Content = content;
        DataPath = dataPath;
        ThumbPath = thumbPath;
        Pinned = pinned;
        CreatedAt = createdAt;
        TableJson = tableJson;
        Paragraphs = (kind == ClipboardKind.ShortText || kind == ClipboardKind.LongText)
            ? ParagraphParser.Parse(content)
            : Array.Empty<string>();
    }
}

public static class ParagraphParser
{
    /// <summary>
    /// 自动分段：只要内容中间有换行，每一行（过滤空行后）就算一段；不足 2 段时返回空列表
    /// </summary>
    public static IReadOnlyList<string> Parse(string text)
    {
        if (string.IsNullOrEmpty(text))
            return Array.Empty<string>();

        var normalized = text
            .Replace("\r\n", "\n")
            .Replace("\r", "\n")
            .Replace("\u2028", "\n")
            .Replace("\u2029", "\n");

        if (!normalized.Contains('\n'))
            return Array.Empty<string>();

        var lines = normalized
            .Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToArray();

        return lines.Length >= 2 ? lines : Array.Empty<string>();
    }
}

public sealed class AppPaths
{
    public static AppPaths Default { get; } = new AppPaths(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinPaste"));

    public string SupportDir { get; }
    public string ImagesDir { get; }
    public string ThumbsDir { get; }
    public string DbPath { get; }
    public string SettingsPath { get; }
    public string OcrModelsDir { get; }

    public AppPaths(string supportDir)
    {
        SupportDir = supportDir;
        ImagesDir = Path.Combine(supportDir, "images");
        ThumbsDir = Path.Combine(supportDir, "thumbs");
        DbPath = Path.Combine(supportDir, "history.db");
        SettingsPath = Path.Combine(supportDir, "settings.json");
        OcrModelsDir = Path.Combine(supportDir, "ocr-models");
    }

    public void EnsureDirectories()
    {
        Directory.CreateDirectory(SupportDir);
        Directory.CreateDirectory(ImagesDir);
        Directory.CreateDirectory(ThumbsDir);
    }
}

public static class HashHelper
{
    public static string Sha256Hex(ReadOnlySpan<byte> data)
    {
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(data, hash);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public static string Sha256Hex(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        return Sha256Hex(bytes);
    }
}

public static class TimeFormatter
{
    public static string RelativeTimeShort(DateTimeOffset date, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        var seconds = (long)(current - date).TotalSeconds;
        if (seconds < 60) return "刚刚";
        if (seconds < 3600) return $"{seconds / 60} 分钟前";
        if (seconds < 86400) return $"{seconds / 3600} 小时前";
        if (seconds < 86400L * 30) return $"{seconds / 86400} 天前";
        return date.ToLocalTime().ToString("yyyy-MM-dd");
    }
}

public static class TextUtils
{
    public static string DisplayTruncate(string s, int limit = 300)
    {
        if (string.IsNullOrEmpty(s) || s.Length <= limit)
            return s ?? string.Empty;
        return s[..limit];
    }
}
