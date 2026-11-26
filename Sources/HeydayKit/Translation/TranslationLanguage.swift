import Foundation

/// A language a person can have mail translated into.
public struct TranslationLanguage: Hashable, Identifiable, Sendable {
    /// BCP 47 code, in the spelling Google Translate takes.
    public let code: String
    /// Its name in the language itself, for pickers.
    public let nativeName: String
    /// Its English name, for prompts.
    public let englishName: String

    public var id: String { code }
}

public enum TranslationLanguages {
    /// The language to fall back on when a locale's own is not listed.
    private static let fallbackCode = "en"

    /// The more widely read languages first, then the rest by their English names.
    public static let all: [TranslationLanguage] = [
        TranslationLanguage(code: "ko", nativeName: "한국어", englishName: "Korean"),
        TranslationLanguage(code: "en", nativeName: "English", englishName: "English"),
        TranslationLanguage(code: "ja", nativeName: "日本語", englishName: "Japanese"),
        TranslationLanguage(code: "zh-CN", nativeName: "简体中文", englishName: "Simplified Chinese"),
        TranslationLanguage(code: "zh-TW", nativeName: "繁體中文", englishName: "Traditional Chinese"),
        TranslationLanguage(code: "es", nativeName: "Español", englishName: "Spanish"),
        TranslationLanguage(code: "fr", nativeName: "Français", englishName: "French"),
        TranslationLanguage(code: "de", nativeName: "Deutsch", englishName: "German"),
        TranslationLanguage(code: "pt", nativeName: "Português", englishName: "Portuguese"),
        TranslationLanguage(code: "it", nativeName: "Italiano", englishName: "Italian"),
        TranslationLanguage(code: "ru", nativeName: "Русский", englishName: "Russian"),
        TranslationLanguage(code: "uk", nativeName: "Українська", englishName: "Ukrainian"),
        TranslationLanguage(code: "vi", nativeName: "Tiếng Việt", englishName: "Vietnamese"),
        TranslationLanguage(code: "th", nativeName: "ไทย", englishName: "Thai"),
        TranslationLanguage(code: "id", nativeName: "Bahasa Indonesia", englishName: "Indonesian"),
        TranslationLanguage(code: "tr", nativeName: "Türkçe", englishName: "Turkish"),
        TranslationLanguage(code: "pl", nativeName: "Polski", englishName: "Polish"),
        TranslationLanguage(code: "nl", nativeName: "Nederlands", englishName: "Dutch"),
        TranslationLanguage(code: "ar", nativeName: "العربية", englishName: "Arabic"),
        TranslationLanguage(code: "hi", nativeName: "हिन्दी", englishName: "Hindi"),
        TranslationLanguage(code: "af", nativeName: "Afrikaans", englishName: "Afrikaans"),
        TranslationLanguage(code: "sq", nativeName: "Shqip", englishName: "Albanian"),
        TranslationLanguage(code: "am", nativeName: "አማርኛ", englishName: "Amharic"),
        TranslationLanguage(code: "hy", nativeName: "Հայերեն", englishName: "Armenian"),
        TranslationLanguage(code: "as", nativeName: "অসমীয়া", englishName: "Assamese"),
        TranslationLanguage(code: "az", nativeName: "Azərbaycanca", englishName: "Azerbaijani"),
        TranslationLanguage(code: "eu", nativeName: "Euskara", englishName: "Basque"),
        TranslationLanguage(code: "be", nativeName: "Беларуская", englishName: "Belarusian"),
        TranslationLanguage(code: "bn", nativeName: "বাংলা", englishName: "Bengali"),
        TranslationLanguage(code: "bs", nativeName: "Bosanski", englishName: "Bosnian"),
        TranslationLanguage(code: "bg", nativeName: "Български", englishName: "Bulgarian"),
        TranslationLanguage(code: "my", nativeName: "မြန်မာ", englishName: "Burmese"),
        TranslationLanguage(code: "yue", nativeName: "粵語", englishName: "Cantonese"),
        TranslationLanguage(code: "ca", nativeName: "Català", englishName: "Catalan"),
        TranslationLanguage(code: "ceb", nativeName: "Cebuano", englishName: "Cebuano"),
        TranslationLanguage(code: "hr", nativeName: "Hrvatski", englishName: "Croatian"),
        TranslationLanguage(code: "cs", nativeName: "Čeština", englishName: "Czech"),
        TranslationLanguage(code: "da", nativeName: "Dansk", englishName: "Danish"),
        TranslationLanguage(code: "eo", nativeName: "Esperanto", englishName: "Esperanto"),
        TranslationLanguage(code: "et", nativeName: "Eesti", englishName: "Estonian"),
        TranslationLanguage(code: "fil", nativeName: "Filipino", englishName: "Filipino"),
        TranslationLanguage(code: "fi", nativeName: "Suomi", englishName: "Finnish"),
        TranslationLanguage(code: "gl", nativeName: "Galego", englishName: "Galician"),
        TranslationLanguage(code: "ka", nativeName: "ქართული", englishName: "Georgian"),
        TranslationLanguage(code: "el", nativeName: "Ελληνικά", englishName: "Greek"),
        TranslationLanguage(code: "gu", nativeName: "ગુજરાતી", englishName: "Gujarati"),
        TranslationLanguage(code: "ht", nativeName: "Kreyòl ayisyen", englishName: "Haitian Creole"),
        TranslationLanguage(code: "ha", nativeName: "Hausa", englishName: "Hausa"),
        TranslationLanguage(code: "he", nativeName: "עברית", englishName: "Hebrew"),
        TranslationLanguage(code: "hu", nativeName: "Magyar", englishName: "Hungarian"),
        TranslationLanguage(code: "is", nativeName: "Íslenska", englishName: "Icelandic"),
        TranslationLanguage(code: "ig", nativeName: "Igbo", englishName: "Igbo"),
        TranslationLanguage(code: "ga", nativeName: "Gaeilge", englishName: "Irish"),
        TranslationLanguage(code: "jv", nativeName: "Basa Jawa", englishName: "Javanese"),
        TranslationLanguage(code: "kn", nativeName: "ಕನ್ನಡ", englishName: "Kannada"),
        TranslationLanguage(code: "kk", nativeName: "Қазақша", englishName: "Kazakh"),
        TranslationLanguage(code: "km", nativeName: "ខ្មែរ", englishName: "Khmer"),
        TranslationLanguage(code: "ku", nativeName: "Kurdî", englishName: "Kurdish (Kurmanji)"),
        TranslationLanguage(code: "ckb", nativeName: "کوردیی ناوەندی", englishName: "Kurdish (Sorani)"),
        TranslationLanguage(code: "ky", nativeName: "Кыргызча", englishName: "Kyrgyz"),
        TranslationLanguage(code: "lo", nativeName: "ລາວ", englishName: "Lao"),
        TranslationLanguage(code: "la", nativeName: "Latina", englishName: "Latin"),
        TranslationLanguage(code: "lv", nativeName: "Latviešu", englishName: "Latvian"),
        TranslationLanguage(code: "lt", nativeName: "Lietuvių", englishName: "Lithuanian"),
        TranslationLanguage(code: "lb", nativeName: "Lëtzebuergesch", englishName: "Luxembourgish"),
        TranslationLanguage(code: "mk", nativeName: "Македонски", englishName: "Macedonian"),
        TranslationLanguage(code: "mg", nativeName: "Malagasy", englishName: "Malagasy"),
        TranslationLanguage(code: "ms", nativeName: "Bahasa Melayu", englishName: "Malay"),
        TranslationLanguage(code: "ml", nativeName: "മലയാളം", englishName: "Malayalam"),
        TranslationLanguage(code: "mt", nativeName: "Malti", englishName: "Maltese"),
        TranslationLanguage(code: "mi", nativeName: "Māori", englishName: "Maori"),
        TranslationLanguage(code: "mr", nativeName: "मराठी", englishName: "Marathi"),
        TranslationLanguage(code: "mn", nativeName: "Монгол", englishName: "Mongolian"),
        TranslationLanguage(code: "ne", nativeName: "नेपाली", englishName: "Nepali"),
        TranslationLanguage(code: "no", nativeName: "Norsk", englishName: "Norwegian"),
        TranslationLanguage(code: "or", nativeName: "ଓଡ଼ିଆ", englishName: "Odia"),
        TranslationLanguage(code: "ps", nativeName: "پښتو", englishName: "Pashto"),
        TranslationLanguage(code: "fa", nativeName: "فارسی", englishName: "Persian"),
        TranslationLanguage(code: "pa", nativeName: "ਪੰਜਾਬੀ", englishName: "Punjabi"),
        TranslationLanguage(code: "ro", nativeName: "Română", englishName: "Romanian"),
        TranslationLanguage(code: "gd", nativeName: "Gàidhlig", englishName: "Scottish Gaelic"),
        TranslationLanguage(code: "sr", nativeName: "Српски", englishName: "Serbian"),
        TranslationLanguage(code: "si", nativeName: "සිංහල", englishName: "Sinhala"),
        TranslationLanguage(code: "sk", nativeName: "Slovenčina", englishName: "Slovak"),
        TranslationLanguage(code: "sl", nativeName: "Slovenščina", englishName: "Slovenian"),
        TranslationLanguage(code: "so", nativeName: "Soomaali", englishName: "Somali"),
        TranslationLanguage(code: "su", nativeName: "Basa Sunda", englishName: "Sundanese"),
        TranslationLanguage(code: "sw", nativeName: "Kiswahili", englishName: "Swahili"),
        TranslationLanguage(code: "sv", nativeName: "Svenska", englishName: "Swedish"),
        TranslationLanguage(code: "tg", nativeName: "Тоҷикӣ", englishName: "Tajik"),
        TranslationLanguage(code: "ta", nativeName: "தமிழ்", englishName: "Tamil"),
        TranslationLanguage(code: "tt", nativeName: "Татарча", englishName: "Tatar"),
        TranslationLanguage(code: "te", nativeName: "తెలుగు", englishName: "Telugu"),
        TranslationLanguage(code: "tk", nativeName: "Türkmençe", englishName: "Turkmen"),
        TranslationLanguage(code: "ur", nativeName: "اردو", englishName: "Urdu"),
        TranslationLanguage(code: "ug", nativeName: "ئۇيغۇرچە", englishName: "Uyghur"),
        TranslationLanguage(code: "uz", nativeName: "Oʻzbekcha", englishName: "Uzbek"),
        TranslationLanguage(code: "cy", nativeName: "Cymraeg", englishName: "Welsh"),
        TranslationLanguage(code: "fy", nativeName: "Frysk", englishName: "Western Frisian"),
        TranslationLanguage(code: "xh", nativeName: "isiXhosa", englishName: "Xhosa"),
        TranslationLanguage(code: "yi", nativeName: "ייִדיש", englishName: "Yiddish"),
        TranslationLanguage(code: "yo", nativeName: "Yorùbá", englishName: "Yoruba"),
        TranslationLanguage(code: "zu", nativeName: "isiZulu", englishName: "Zulu"),
    ]

    public static func language(code: String) -> TranslationLanguage? {
        all.first { $0.code == code }
    }

    /// The listed language a locale such as "ko-KR" or "zh-Hant-TW" stands for:
    /// the one to start with on a Mac set to that locale.
    public static func code(forLocale locale: String) -> String {
        if let exact = language(code: locale) { return exact.code }

        let subtags = locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.lowercased() }
        guard let base = subtags.first else { return fallbackCode }
        if base == "zh" {
            let isTraditional = subtags.dropFirst().contains { ["hant", "tw", "hk", "mo"].contains($0) }
            return isTraditional ? "zh-TW" : "zh-CN"
        }
        return language(code: base)?.code ?? fallbackCode
    }
}
