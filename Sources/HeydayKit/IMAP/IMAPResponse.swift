import Foundation

/// One value in an IMAP response: a bare word, a string, or a parenthesised list.
indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    /// A quoted string or a literal. Kept as bytes: a literal can be a whole message.
    case string(Data)
    case list([IMAPValue])
    case null

    /// The value read as text, whichever way the server chose to write it.
    var text: String? {
        switch self {
        case .atom(let atom): atom
        case .string(let data): String(decoding: data, as: UTF8.self)
        case .list, .null: nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let atom): Data(atom.utf8)
        case .list, .null: nil
        }
    }

    var items: [IMAPValue] {
        if case .list(let items) = self { items } else { [] }
    }
}

struct IMAPSyntaxError: Error, Equatable {
    let message: String
}

/// Reads IMAP's value syntax from the bytes of one complete response, literals included.
struct IMAPValueParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    /// Every value up to the end of the response.
    mutating func values() throws(IMAPSyntaxError) -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            guard index < bytes.count else { return values }
            values.append(try value())
        }
    }

    private mutating func value() throws(IMAPSyntaxError) -> IMAPValue {
        switch bytes[index] {
        case UInt8(ascii: "("):
            index += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard index < bytes.count else { throw IMAPSyntaxError(message: "A list was never closed.") }
                if bytes[index] == UInt8(ascii: ")") {
                    index += 1
                    return .list(items)
                }
                items.append(try value())
            }
        case UInt8(ascii: "\""):
            index += 1
            var content: [UInt8] = []
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                if bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count { index += 1 }
                content.append(bytes[index])
                index += 1
            }
            guard index < bytes.count else { throw IMAPSyntaxError(message: "A quoted string was never closed.") }
            index += 1
            return .string(Data(content))
        case UInt8(ascii: "{"):
            return .string(try literal())
        default:
            return atom()
        }
    }

    /// `{n}CRLF` followed by exactly n bytes.
    private mutating func literal() throws(IMAPSyntaxError) -> Data {
        guard let close = bytes[index...].firstIndex(of: UInt8(ascii: "}")),
              let count = Int(String(decoding: bytes[(index + 1)..<close], as: UTF8.self).filter(\.isNumber))
        else { throw IMAPSyntaxError(message: "A literal has no length.") }
        var start = close + 1
        if start < bytes.count, bytes[start] == UInt8(ascii: "\r") { start += 1 }
        if start < bytes.count, bytes[start] == UInt8(ascii: "\n") { start += 1 }
        guard start + count <= bytes.count else { throw IMAPSyntaxError(message: "A literal is shorter than it claims.") }
        index = start + count
        return Data(bytes[start..<index])
    }

    /// A bare word. A bracketed section such as `BODY[HEADER.FIELDS (FROM TO)]` is one
    /// word even though it contains spaces and parentheses.
    private mutating func atom() -> IMAPValue {
        let start = index
        var bracketDepth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "[") { bracketDepth += 1 }
            if byte == UInt8(ascii: "]") { bracketDepth = max(0, bracketDepth - 1) }
            if bracketDepth == 0, byte == UInt8(ascii: " ") || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") { break }
            index += 1
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        return text.uppercased() == "NIL" ? .null : .atom(text)
    }

    private mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
    }
}

enum IMAPStatus: String, Sendable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
    case bye = "BYE"
    case preauth = "PREAUTH"
}

/// One response from the server, reduced to what this client acts on.
enum IMAPResponse: Equatable, Sendable {
    /// `+ …`: the server is ready for the rest of a command, or sends a SASL challenge.
    case continuation(String)
    case tagged(tag: String, status: IMAPStatus, text: String)
    /// An untagged status line, such as the greeting or `* OK [UIDNEXT 42]`.
    case status(IMAPStatus, text: String)
    case exists(Int)
    case expunge(Int)
    /// Keys are uppercased item names, with body sections normalised by `fetchKey`.
    case fetch([String: IMAPValue])
    case list(attributes: Set<String>, delimiter: String?, name: String)
    case search([UInt32])
    case capability(Set<String>)
    case other

    init(_ data: Data) throws(IMAPSyntaxError) {
        let (head, afterHead) = Self.word(data)
        if head == "+" {
            self = .continuation(String(decoding: afterHead, as: UTF8.self))
            return
        }
        guard head == "*" else {
            let (status, text) = Self.word(afterHead)
            guard let status = IMAPStatus(rawValue: status.uppercased()) else {
                throw IMAPSyntaxError(message: "A tagged response has no status.")
            }
            self = .tagged(tag: head, status: status, text: String(decoding: text, as: UTF8.self))
            return
        }

        let (keyword, rest) = Self.word(afterHead)
        if let number = Int(keyword) {
            let (kind, payload) = Self.word(rest)
            switch kind.uppercased() {
            case "EXISTS": self = .exists(number)
            case "EXPUNGE": self = .expunge(number)
            case "FETCH":
                var parser = IMAPValueParser(payload)
                let items = try parser.values().first?.items ?? []
                var fetched: [String: IMAPValue] = [:]
                for pair in stride(from: 0, to: items.count - 1, by: 2) {
                    if let key = items[pair].text {
                        fetched[Self.fetchKey(key)] = items[pair + 1]
                    }
                }
                self = .fetch(fetched)
            default: self = .other
            }
            return
        }

        switch keyword.uppercased() {
        case "OK", "NO", "BAD", "BYE", "PREAUTH":
            // Human-readable text follows; it is not written in value syntax.
            self = .status(IMAPStatus(rawValue: keyword.uppercased()) ?? .ok, text: String(decoding: rest, as: UTF8.self))
        case "CAPABILITY":
            self = .capability(Set(String(decoding: rest, as: UTF8.self).uppercased().split(separator: " ").map(String.init)))
        case "SEARCH":
            self = .search(String(decoding: rest, as: UTF8.self).split(separator: " ").compactMap { UInt32($0) })
        case "LIST", "LSUB":
            var parser = IMAPValueParser(rest)
            let values = try parser.values()
            guard values.count >= 3, let name = values[2].text else {
                throw IMAPSyntaxError(message: "A LIST response is incomplete.")
            }
            self = .list(
                attributes: Set(values[0].items.compactMap(\.text).map { $0.lowercased() }),
                delimiter: values[1].text,
                name: name
            )
        default:
            self = .other
        }
    }

    /// `BODY[HEADER.FIELDS (FROM TO)]` and `BODY[TEXT]<0>` come back spelled however
    /// the server likes; reduce them to `BODY[HEADER]`, `BODY[TEXT]` and `BODY[]`.
    static func fetchKey(_ key: String) -> String {
        let upper = key.uppercased()
        guard upper.hasPrefix("BODY[") else { return upper }
        if upper.hasPrefix("BODY[HEADER") { return "BODY[HEADER]" }
        if upper.hasPrefix("BODY[TEXT") { return "BODY[TEXT]" }
        return "BODY[]"
    }

    /// The first space-delimited word and what follows it.
    private static func word(_ data: Data) -> (String, Data) {
        guard let space = data.firstIndex(of: UInt8(ascii: " ")) else {
            return (String(decoding: data, as: UTF8.self), Data())
        }
        return (String(decoding: data[..<space], as: UTF8.self), Data(data[data.index(after: space)...]))
    }
}

/// IMAP writes non-ASCII mailbox names in "modified UTF-7". This turns one back into
/// text for display; the original spelling is still what commands must use.
enum IMAPMailboxName {
    static func decode(_ name: String) -> String {
        guard name.contains("&") else { return name }
        return name.replacing(/&([^-]*)-/) { match in
            guard !match.1.isEmpty else { return "&" }
            var base64 = match.1.replacingOccurrences(of: ",", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf16BigEndian) else {
                return String(match.0)
            }
            return text
        }
    }
}
