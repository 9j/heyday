import Foundation

/// Translates texts into a language.
///
/// A text may carry numbered tags, `<g0>…</g0>` and `<x1/>`, that stand for the
/// inline markup of the paragraph it came from. A translator keeps them where the
/// service lets it; whoever shows the translation checks that they still line up.
protocol Translator: Sendable {
    /// One translation per text, in the same order. Nil where the service gave
    /// nothing usable for a text.
    func translate(_ texts: [String], into language: TranslationLanguage) async throws(TranslationError) -> [String?]
}

// MARK: - Batches

struct BatchLimits: Equatable, Sendable {
    let maxItems: Int
    /// Soft cap, in characters: a single item larger than this still gets a batch of its own.
    let maxSize: Int
}

/// Groups consecutive items, given by their sizes, so each group stays within both limits.
func planBatches(sizes: [Int], limits: BatchLimits) -> [Range<Int>] {
    var batches: [Range<Int>] = []
    var start = 0
    var size = 0
    for (index, itemSize) in sizes.enumerated() {
        let count = index - start
        if count > 0, count >= limits.maxItems || size + itemSize > limits.maxSize {
            batches.append(start..<index)
            start = index
            size = 0
        }
        size += itemSize
    }
    if start < sizes.count { batches.append(start..<sizes.count) }
    return batches
}

// MARK: - Google Translate

/// Google Translate through the endpoint its own web widgets use. It takes no key
/// and promises nothing: Google may limit it or change it.
struct GoogleTranslator: Translator {
    static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/t")!

    let transport: any HTTPTransport

    func translate(_ texts: [String], into language: TranslationLanguage) async throws(TranslationError) -> [String?] {
        guard !texts.isEmpty else { return [] }
        let url = Self.endpoint.appending(queryItems: [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: language.code),
        ])
        let form = texts.map { "q=" + Self.formEncoded($0) }.joined(separator: "&")
        let data = try await transport.post(Data(form.utf8), as: "application/x-www-form-urlencoded;charset=utf-8", to: url, headers: [:])

        // One entry per text: `["translation", "detected language"]`, or the bare
        // translation when the source language was not left to Google.
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any], entries.count == texts.count else {
            throw TranslationError(.server, "Google Translate sent a reply that could not be read.")
        }
        return entries.map { entry in
            let text = entry as? String ?? (entry as? [Any])?.first as? String
            return text.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

// MARK: - DeepL

struct DeepLTranslator: Translator {
    private struct Request: Encodable {
        let text: [String]
        let targetLang: String
        /// The tags in a text are markup to keep in place, not words.
        let tagHandling = "xml"

        enum CodingKeys: String, CodingKey {
            case text
            case targetLang = "target_lang"
            case tagHandling = "tag_handling"
        }
    }

    private struct Reply: Decodable {
        struct Translation: Decodable {
            let text: String
        }

        let translations: [Translation]
    }

    let apiKey: String
    let transport: any HTTPTransport

    /// Keys of DeepL's free plan end in ":fx" and are served from a host of their own.
    static func endpoint(for apiKey: String) -> URL {
        URL(string: apiKey.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate")!
    }

    /// DeepL's name for a language, where it differs from the code in capitals: it
    /// wants a regional variant of English and Portuguese, and names the Chinese
    /// scripts rather than regions.
    static func targetCode(for language: TranslationLanguage) -> String {
        switch language.code {
        case "en": "EN-US"
        case "pt": "PT-BR"
        case "zh-CN": "ZH-HANS"
        case "zh-TW": "ZH-HANT"
        case "no": "NB"
        default: language.code.uppercased()
        }
    }

    func translate(_ texts: [String], into language: TranslationLanguage) async throws(TranslationError) -> [String?] {
        guard !texts.isEmpty else { return [] }
        let data = try await transport.postJSON(
            Request(text: texts.map(Self.asXML), targetLang: Self.targetCode(for: language)),
            to: Self.endpoint(for: apiKey),
            headers: ["Authorization": "DeepL-Auth-Key \(apiKey)"]
        )
        let reply = try decodeReply(Reply.self, from: data)
        guard reply.translations.count == texts.count else {
            throw TranslationError(.server, "DeepL sent a reply that could not be read.")
        }
        return reply.translations.map { $0.text.isEmpty ? nil : Self.fromXML($0.text) }
    }

    /// With tags handled as XML, everything else in a text has to be XML too. The
    /// numbered tags, `<g0>`, `</g0>` and `<x1/>`, pass as they are.
    static func asXML(_ text: String) -> String {
        var xml = ""
        var cursor = text.startIndex
        for tag in text.matches(of: /<\/?[gx]\d+\s*\/?>/) {
            xml += escaped(text[cursor..<tag.range.lowerBound]) + text[tag.range]
            cursor = tag.range.upperBound
        }
        return xml + escaped(text[cursor...])
    }

    static func fromXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escaped(_ text: Substring) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
