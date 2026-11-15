using System.Net.Http;
using System.Text.Json;

namespace WinPaste.Core.Translation;

/// <summary>
/// 极轻量原生翻译服务：支持语言自动检测、中文/英文/日文/韩文等多国语言互译（24 种语言）
/// </summary>
public sealed class TranslationService
{
    public static TranslationService Shared { get; } = new();

    public sealed record TargetLanguage(string Id, string Code, string Name);

    public static IReadOnlyList<TargetLanguage> CommonTargetLanguages { get; } =
    [
        // 常用第一列：东亚、主流欧美、中东
        new("zh-Hans", "zh-CN", "简体中文"),
        new("zh-Hant", "zh-TW", "繁體中文"),
        new("en", "en", "English"),
        new("ja", "ja", "日本語"),
        new("ko", "ko", "한국어"),
        new("fr", "fr", "Français (法语)"),
        new("es", "es", "Español (西班牙语)"),
        new("de", "de", "Deutsch (德语)"),
        new("ru", "ru", "Русский (俄语)"),
        new("ar", "ar", "العربية (阿拉伯语)"),
        new("it", "it", "Italiano (意大利语)"),
        new("pt", "pt", "Português (葡萄牙语)"),

        // 常用第二列：东南亚、欧洲其他、南亚与中东
        new("th", "th", "ภาษาไทย (泰语)"),
        new("vi", "vi", "Tiếng Việt (越南语)"),
        new("id", "id", "Bahasa Indonesia (印尼语)"),
        new("ms", "ms", "Bahasa Melayu (马来语)"),
        new("tr", "tr", "Türkçe (土耳其语)"),
        new("uk", "uk", "Українська (乌克兰语)"),
        new("pl", "pl", "Polski (波兰语)"),
        new("nl", "nl", "Nederlands (荷兰语)"),
        new("sv", "sv", "Svenska (瑞典语)"),
        new("cs", "cs", "Čeština (捷克语)"),
        new("hi", "hi", "हिन्दी (印地语)"),
        new("fa", "fa", "فارسی (波斯语)"),
    ];

    private readonly HttpClient _http;

    public TranslationService(HttpMessageHandler? handler = null)
    {
        _http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        _http.Timeout = TimeSpan.FromSeconds(4.5);
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
    }

    public (string Code, string Name) DetectLanguage(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return ("auto", "自动检测");

        int cjk = 0, kana = 0, hangul = 0, cyrillic = 0, arabic = 0, thai = 0, devanagari = 0, greek = 0, hebrew = 0, latin = 0;
        int ukrSpecific = 0;
        int vnSpecific = 0, frSpecific = 0, deSpecific = 0, esSpecific = 0, trSpecific = 0, plSpecific = 0, csSpecific = 0;

        foreach (var rune in text.EnumerateRunes())
        {
            int v = rune.Value;
            if ((v >= 0x3040 && v <= 0x309F) || (v >= 0x30A0 && v <= 0x30FF)) kana++;
            else if (v >= 0xAC00 && v <= 0xD7AF) hangul++;
            else if ((v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF)) cjk++;
            else if (v >= 0x0400 && v <= 0x04FF)
            {
                cyrillic++;
                if (v is 0x0404 or 0x0454 or 0x0406 or 0x0456 or 0x0407 or 0x0457 or 0x0490 or 0x0491)
                    ukrSpecific++;
            }
            else if (v >= 0x0600 && v <= 0x06FF) arabic++;
            else if (v >= 0x0E00 && v <= 0x0E7F) thai++;
            else if (v >= 0x0900 && v <= 0x097F) devanagari++;
            else if (v >= 0x0370 && v <= 0x03FF) greek++;
            else if (v >= 0x0590 && v <= 0x05FF) hebrew++;
            else if ((v >= 'A' && v <= 'Z') || (v >= 'a' && v <= 'z') || (v >= 0x00C0 && v <= 0x024F) || (v >= 0x1E00 && v <= 0x1EFF))
            {
                latin++;
                if (v >= 0x1EA0 && v <= 0x1EF9 || v is 0x0110 or 0x0111) vnSpecific++;
                if (v is 'é' or 'è' or 'ê' or 'à' or 'ç' or 'ù' or 'î' or 'ô' or 'œ') frSpecific++;
                if (v is 'ä' or 'ö' or 'ü' or 'ß' or 'Ä' or 'Ö' or 'Ü') deSpecific++;
                if (v is 'ñ' or '¿' or '¡' or 'á' or 'í' or 'ó' or 'ú') esSpecific++;
                if (v is 'ğ' or 'Ğ' or 'ş' or 'Ş' or 'ı' or 'İ') trSpecific++;
                if (v is 'ł' or 'Ł' or 'ą' or 'ę' or 'ś' or 'ź' or 'ż' or 'ć' or 'ń') plSpecific++;
                if (v is 'č' or 'ř' or 'š' or 'ž' or 'ě' or 'ů' or 'ý') csSpecific++;
            }
        }

        if (kana > 0) return ("ja", "日语");
        if (hangul > 0) return ("ko", "韩语");
        if (cjk > 0) return ("zh", "中文");
        if (thai > 0) return ("th", "泰语");
        if (devanagari > 0) return ("hi", "印地语");
        if (greek > 0) return ("el", "希腊语");
        if (hebrew > 0) return ("he", "希伯来语");
        if (arabic > 0)
        {
            if (text.Any(ch => ch is 'پ' or 'چ' or 'ژ' or 'گ' or 'ی' or 'ک'))
                return ("fa", "波斯语");
            return ("ar", "阿拉伯语");
        }
        if (cyrillic > 0) return ukrSpecific > 0 ? ("uk", "乌克兰语") : ("ru", "俄语");
        if (latin > 0)
        {
            if (vnSpecific > 0) return ("vi", "越南语");
            if (trSpecific > 0) return ("tr", "土耳其语");
            if (plSpecific > 0) return ("pl", "波兰语");
            if (csSpecific > 0) return ("cs", "捷克语");
            if (deSpecific > 0) return ("de", "德语");
            if (frSpecific > 0) return ("fr", "法语");
            if (esSpecific > 0) return ("es", "西班牙语");
            return ("en", "英语");
        }

        return ("auto", "自动检测");
    }

    public TargetLanguage SuggestedTargetLanguage(string text)
    {
        var (code, _) = DetectLanguage(text);
        if (code.StartsWith("zh", StringComparison.OrdinalIgnoreCase))
            return CommonTargetLanguages.FirstOrDefault(l => l.Id == "en") ?? CommonTargetLanguages[1];
        return CommonTargetLanguages.FirstOrDefault(l => l.Id == "zh-Hans") ?? CommonTargetLanguages[0];
    }

    public async Task<string> TranslateAsync(
        string text,
        string sourceLang = "auto",
        string targetCode = "zh-CN",
        CancellationToken cancellationToken = default)
    {
        var trimmed = text.Trim();
        if (string.IsNullOrEmpty(trimmed))
            return string.Empty;

        var encoded = Uri.EscapeDataString(trimmed);
        var url = $"https://translate.googleapis.com/translate_a/single?client=gtx&sl={Uri.EscapeDataString(sourceLang)}&tl={Uri.EscapeDataString(targetCode)}&dt=t&q={encoded}";

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromSeconds(4.5));

        HttpResponseMessage response;
        try
        {
            response = await _http.GetAsync(url, cts.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is TaskCanceledException or HttpRequestException)
        {
            throw new InvalidOperationException("翻译连接超时或网络异常", ex);
        }

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException("翻译服务暂未响应");

        var json = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
        return ParseGoogleTranslateResponse(json);
    }

    public static string ParseGoogleTranslateResponse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0)
                throw new InvalidOperationException("暂不支持该内容的翻译解析");

            var sentences = doc.RootElement[0];
            if (sentences.ValueKind != JsonValueKind.Array)
                throw new InvalidOperationException("暂不支持该内容的翻译解析");

            var parts = new List<string>();
            foreach (var item in sentences.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.Array && item.GetArrayLength() > 0 && item[0].ValueKind == JsonValueKind.String)
                    parts.Add(item[0].GetString() ?? string.Empty);
            }
            return string.Concat(parts).Trim();
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException("暂不支持该内容的翻译解析", ex);
        }
    }

    /// <summary>
    /// 批量保序翻译多个文本块：优先单次换行合并请求以降低延迟，若行数被改写则自动并发逐条保序回退
    /// </summary>
    public async Task<string[]> TranslateBatchAsync(
        IReadOnlyList<string> texts,
        string sourceLang = "auto",
        string targetCode = "zh-CN",
        CancellationToken cancellationToken = default)
    {
        if (texts.Count == 0)
            return Array.Empty<string>();

        if (texts.Count == 1)
        {
            var single = await TranslateAsync(texts[0], sourceLang, targetCode, cancellationToken).ConfigureAwait(false);
            return [single];
        }

        var sanitized = texts
            .Select(item => item
                .Replace("\r\n", " ")
                .Replace("\n", " ")
                .Replace("\r", " ")
                .Trim())
            .ToArray();

        if (sanitized.All(s => s.Length > 0))
        {
            var joined = string.Join("\n", sanitized);
            if (joined.Length <= 1800)
            {
                var batchResult = await TranslateAsync(joined, sourceLang, targetCode, cancellationToken).ConfigureAwait(false);
                var splitLines = batchResult
                    .Replace("\r\n", "\n")
                    .Replace("\r", "\n")
                    .Split('\n')
                    .Select(s => s.Trim())
                    .Where(s => s.Length > 0)
                    .ToArray();

                if (splitLines.Length == texts.Count)
                    return splitLines;
            }
        }

        var tasks = texts.Select(async (text, idx) =>
        {
            var trimmed = text.Trim();
            if (trimmed.Length == 0)
                return (idx, string.Empty);

            var translated = await TranslateAsync(trimmed, sourceLang, targetCode, cancellationToken).ConfigureAwait(false);
            return (idx, translated);
        });

        var pairs = await Task.WhenAll(tasks).ConfigureAwait(false);
        var results = new string[texts.Count];
        foreach (var (idx, translated) in pairs)
            results[idx] = translated;
        return results;
    }
}
