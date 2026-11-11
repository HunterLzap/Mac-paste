import Foundation
import NaturalLanguage

/// 极轻量原生翻译服务：支持语言自动检测、中文/英文/日文/韩文等多国语言互译
final class TranslationService {
    static let shared = TranslationService()

    private init() {}

    /// 支持的目标语言选项
    struct TargetLanguage: Identifiable, Hashable {
        let id: String
        let code: String
        let name: String
    }

    static let commonTargetLanguages: [TargetLanguage] = [
        // 常用第一列：东亚、主流欧美、中东
        TargetLanguage(id: "zh-Hans", code: "zh-CN", name: "简体中文"),
        TargetLanguage(id: "zh-Hant", code: "zh-TW", name: "繁體中文"),
        TargetLanguage(id: "en", code: "en", name: "English"),
        TargetLanguage(id: "ja", code: "ja", name: "日本語"),
        TargetLanguage(id: "ko", code: "ko", name: "한국어"),
        TargetLanguage(id: "fr", code: "fr", name: "Français (法语)"),
        TargetLanguage(id: "es", code: "es", name: "Español (西班牙语)"),
        TargetLanguage(id: "de", code: "de", name: "Deutsch (德语)"),
        TargetLanguage(id: "ru", code: "ru", name: "Русский (俄语)"),
        TargetLanguage(id: "ar", code: "ar", name: "العربية (阿拉伯语)"),
        TargetLanguage(id: "it", code: "it", name: "Italiano (意大利语)"),
        TargetLanguage(id: "pt", code: "pt", name: "Português (葡萄牙语)"),

        // 常用第二列：东南亚、欧洲其他、南亚与中东
        TargetLanguage(id: "th", code: "th", name: "ภาษาไทย (泰语)"),
        TargetLanguage(id: "vi", code: "vi", name: "Tiếng Việt (越南语)"),
        TargetLanguage(id: "id", code: "id", name: "Bahasa Indonesia (印尼语)"),
        TargetLanguage(id: "ms", code: "ms", name: "Bahasa Melayu (马来语)"),
        TargetLanguage(id: "tr", code: "tr", name: "Türkçe (土耳其语)"),
        TargetLanguage(id: "uk", code: "uk", name: "Українська (乌克兰语)"),
        TargetLanguage(id: "pl", code: "pl", name: "Polski (波兰语)"),
        TargetLanguage(id: "nl", code: "nl", name: "Nederlands (荷兰语)"),
        TargetLanguage(id: "sv", code: "sv", name: "Svenska (瑞典语)"),
        TargetLanguage(id: "cs", code: "cs", name: "Čeština (捷克语)"),
        TargetLanguage(id: "hi", code: "hi", name: "हिन्दी (印地语)"),
        TargetLanguage(id: "fa", code: "fa", name: "فارسی (波斯语)"),
    ]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.5
        config.timeoutIntervalForResource = 4.5
        return URLSession(configuration: config)
    }()

    /// 自动检测文本的源语言并返回人类可读名称和代码
    func detectLanguage(for text: String) -> (code: String, name: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else {
            return ("auto", "自动检测")
        }
        let code = lang.rawValue
        switch code {
        case "zh-Hans", "zh-Hant", "zh": return ("zh", "中文")
        case "en": return ("en", "英语")
        case "ja": return ("ja", "日语")
        case "ko": return ("ko", "韩语")
        case "ar": return ("ar", "阿拉伯语")
        case "fr": return ("fr", "法语")
        case "de": return ("de", "德语")
        case "es": return ("es", "西班牙语")
        case "ru": return ("ru", "俄语")
        case "it": return ("it", "意大利语")
        case "pt": return ("pt", "葡萄牙语")
        case "th": return ("th", "泰语")
        case "vi": return ("vi", "越南语")
        case "id": return ("id", "印尼语")
        case "ms": return ("ms", "马来语")
        case "tr": return ("tr", "土耳其语")
        case "uk": return ("uk", "乌克兰语")
        case "pl": return ("pl", "波兰语")
        case "nl": return ("nl", "荷兰语")
        case "sv": return ("sv", "瑞典语")
        case "cs": return ("cs", "捷克语")
        case "hi": return ("hi", "印地语")
        case "fa": return ("fa", "波斯语")
        case "ro": return ("ro", "罗马尼亚语")
        case "el": return ("el", "希腊语")
        case "he": return ("he", "希伯来语")
        case "da": return ("da", "丹麦语")
        case "fi": return ("fi", "芬兰语")
        case "no", "nb", "nn": return ("no", "挪威语")
        case "hu": return ("hu", "匈牙利语")
        default: return (code, code.uppercased())
        }
    }

    /// 根据源语言智能建议默认目标语言：如果是中文则翻译为英文，其他所有语言默认翻译为简体中文
    func suggestedTargetLanguage(for text: String) -> TargetLanguage {
        let detected = detectLanguage(for: text)
        if detected.code.hasPrefix("zh") {
            return Self.commonTargetLanguages.first(where: { $0.id == "en" }) ?? Self.commonTargetLanguages[1]
        }
        return Self.commonTargetLanguages.first(where: { $0.id == "zh-Hans" }) ?? Self.commonTargetLanguages[0]
    }

    /// 异步翻译文本为指定目标语言
    func translate(
        text: String,
        sourceLang: String = "auto",
        targetCode: String = "zh-CN"
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&?#=")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=\(sourceLang)&tl=\(targetCode)&dt=t&q=\(encoded)") else {
            throw NSError(domain: "TranslationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的翻译请求参数"])
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw NSError(domain: "TranslationService", code: -2, userInfo: [NSLocalizedDescriptionKey: "翻译连接超时或网络异常"])
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "TranslationService", code: -3, userInfo: [NSLocalizedDescriptionKey: "翻译服务暂未响应"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = json.first as? [[Any]] else {
            throw NSError(domain: "TranslationService", code: -4, userInfo: [NSLocalizedDescriptionKey: "暂不支持该内容的翻译解析"])
        }

        let translated = sentences.compactMap { $0.first as? String }.joined()
        return translated.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
