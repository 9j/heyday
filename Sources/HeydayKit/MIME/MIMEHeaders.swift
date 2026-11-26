import Foundation

/// A name and address as they appear in a From or To header.
public struct EmailAddress: Hashable, Sendable, Codable {
    public let name: String
    public let address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    /// What to call this correspondent in a list.
    public var displayName: String { name.isEmpty ? address : name }
    /// The form of the address that identifies a sender: case does not matter in practice.
    public var key: String { address.lowercased() }
    /// `Jane Doe <jane@example.com>`, for a header or a recipient field.
    public var formatted: String { name.isEmpty ? address : "\(name) <\(address)>" }
}

/// A message's (or a MIME part's) header block, decoded for reading.
public struct MIMEHeaders: Sendable, Equatable {
    /// Field names lowercased; a field that appears twice keeps both values in order.
    private var fields: [String: [String]] = [:]

    public init(_ block: Data) {
        // Unfold: a line that starts with whitespace continues the previous one.
        var lines: [String] = []
        for raw in String(decoding: block, as: UTF8.self).components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name, default: []].append(value)
        }
    }

    /// The field as written, still carrying any `=?utf-8?B?…?=` encoding.
    public func raw(_ name: String) -> String? {
        fields[name.lowercased()]?.first
    }

    /// The field with encoded words turned back into text.
    public func text(_ name: String) -> String? {
        raw(name).map(EncodedWord.decode)
    }

    public func addresses(_ name: String) -> [EmailAddress] {
        (fields[name.lowercased()] ?? []).flatMap(AddressList.parse)
    }

    /// Every `<id>` in the field, for Message-ID, In-Reply-To and References.
    public func messageIDs(_ name: String) -> [String] {
        guard let value = raw(name) else { return [] }
        return value.matches(of: /<[^<>\s]+>/).map { String($0.0) }
    }

    public var date: Date? {
        raw("date").flatMap(MailDate.parse)
    }

    public var contentType: ContentType {
        ContentType(raw("content-type") ?? "text/plain")
    }

    public var transferEncoding: String {
        (raw("content-transfer-encoding") ?? "7bit").lowercased()
    }
}

/// A `type/subtype; key=value` header value, as used by Content-Type and Content-Disposition.
public struct ContentType: Sendable, Equatable {
    /// Lowercased, e.g. `text/html`.
    public let type: String
    public let parameters: [String: String]

    public init(_ value: String) {
        var pieces = Self.split(value)
        type = pieces.isEmpty ? "" : pieces.removeFirst().lowercased()
        var parameters: [String: String] = [:]
        for piece in pieces {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var text = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            // RFC 2231: `filename*=UTF-8''na%C3%AFve.pdf`.
            if key.hasSuffix("*") {
                key.removeLast()
                let parts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    text = String(parts[2]).removingPercentEncoding ?? String(parts[2])
                }
            }
            parameters[key] = EncodedWord.decode(text)
        }
        self.parameters = parameters
    }

    public var isMultipart: Bool { type.hasPrefix("multipart/") }

    /// Splits on semicolons that are not inside a quoted string.
    private static func split(_ value: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" { inQuotes.toggle() }
            if character == ";", !inQuotes {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current.trimmingCharacters(in: .whitespaces))
        return pieces.filter { !$0.isEmpty }
    }
}

/// RFC 2047 "encoded words": how non-ASCII text travels in headers.
enum EncodedWord {
    static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        // Whitespace between two adjacent encoded words is not part of the text.
        let joined = value.replacing(/\?=\s+=\?/, with: "?==?")
        return joined.replacing(/=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?=/) { match in
            let payload = String(match.3)
            let data: Data? = switch match.2.lowercased() {
            case "b": Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
            default: TransferEncoding.decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            return data.map { Charset.string(from: $0, named: String(match.1)) } ?? String(match.0)
        }
    }

    /// Encodes a header value for sending, leaving plain ASCII untouched.
    static func encode(_ value: String) -> String {
        guard !value.allSatisfy(\.isASCII) else { return value }
        // Split so no encoded word passes 75 characters, on character boundaries.
        var words: [String] = []
        var chunk = ""
        for character in value {
            if (chunk + String(character)).utf8.count > 39 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        words.append(chunk)
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: " ")
    }
}

/// Turns bytes in a named character set into text. Korean mail still arrives in
/// EUC-KR and ISO-2022-KR, so the IANA name is honoured rather than assuming UTF-8.
enum Charset {
    static func string(from data: Data, named name: String?) -> String {
        if let name, !name.isEmpty {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        // Unknown or mislabelled: UTF-8, with replacement characters for what is not.
        return String(decoding: data, as: UTF8.self)
    }
}

/// Splits an address header into its correspondents.
enum AddressList {
    static func parse(_ value: String) -> [EmailAddress] {
        split(value).compactMap(parseOne)
    }

    private static func parseOne(_ entry: String) -> EmailAddress? {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return nil }
        if let open = entry.lastIndex(of: "<"), let close = entry.lastIndex(of: ">"), open < close {
            let address = entry[entry.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = entry[..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            return address.isEmpty ? nil : EmailAddress(name: EncodedWord.decode(name), address: address)
        }
        return entry.contains("@") ? EmailAddress(address: entry) : nil
    }

    /// Splits on commas that are outside quotes and angle brackets.
    private static func split(_ value: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var depth = 0
        var previous: Character?
        for character in value {
            if character == "\"", previous != "\\" { inQuotes.toggle() }
            if !inQuotes {
                if character == "<" { depth += 1 }
                if character == ">" { depth = max(0, depth - 1) }
            }
            if character == ",", !inQuotes, depth == 0 {
                entries.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        entries.append(current)
        return entries
    }
}

/// RFC 5322 dates: `Wed, 25 Nov 2026 16:32:37 +0900 (KST)`.
enum MailDate {
    static func parse(_ value: String) -> Date? {
        // A trailing comment names the zone a second time; the offset is what counts.
        let trimmed = value.replacing(/\s*\([^)]*\)\s*$/, with: "").trimmingCharacters(in: .whitespaces)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// IMAP's own date form, as in `INTERNALDATE " 7-Jul-2026 02:44:25 +0900"`.
    static func parseInternal(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
    ]
}
