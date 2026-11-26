import Foundation

/// One attribute of a start tag. A bare attribute, such as `hidden`, has an empty value.
struct HTMLAttribute: Equatable, Sendable {
    /// Lowercased.
    let name: String
    /// As meant, with character references such as `&amp;` decoded.
    var value: String
}

/// One start tag found in an HTML document.
struct HTMLTag: Equatable, Sendable {
    /// Lowercased.
    let name: String
    var attributes: [HTMLAttribute]

    subscript(name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    /// Sets an attribute, adding it if the tag has none of that name; nil removes it.
    mutating func set(_ name: String, to value: String?) {
        guard let value else {
            attributes.removeAll { $0.name == name }
            return
        }
        if let index = attributes.firstIndex(where: { $0.name == name }) {
            attributes[index].value = value
        } else {
            attributes.append(HTMLAttribute(name: name, value: value))
        }
    }

    /// The tag written out again.
    var html: String {
        "<\(name)" + attributes.map { " \($0.name)=\"\(HTMLText.escapeAttribute($0.value))\"" }.joined() + ">"
    }
}

/// A reader of HTML as it is found in email: it looks only at start tags, and takes
/// whatever it is given without complaint.
enum HTMLTags {
    /// Rewrites a document tag by tag. `replace` is asked about every start tag
    /// outside comments, scripts and style sheets, and returns the text to put in
    /// the tag's place, or nil to leave it as written.
    static func rewrite(_ html: String, _ replace: (HTMLTag) -> String?) -> String {
        let bytes = Array(html.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var copiedUpTo = 0
        var index = 0

        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            if starts(bytes, at: index, with: "<!--") {
                index = find("-->", in: bytes, from: index + 4).map { $0 + 3 } ?? bytes.count
                continue
            }
            guard let (tag, end) = startTag(in: bytes, at: index) else {
                index += 1
                continue
            }
            if let replacement = replace(tag) {
                output.append(contentsOf: bytes[copiedUpTo..<index])
                output.append(contentsOf: replacement.utf8)
                copiedUpTo = end
            }
            index = end
            // What is inside these is not markup, whatever it looks like.
            if tag.name == "script" || tag.name == "style" {
                index = find("</\(tag.name)", in: bytes, from: index) ?? bytes.count
            }
        }
        output.append(contentsOf: bytes[copiedUpTo...])
        return String(decoding: output, as: UTF8.self)
    }

    /// The start tag beginning at `start`, and the index just past its `>`. Nil if
    /// what begins there is not a start tag, or the document ends inside it.
    private static func startTag(in bytes: [UInt8], at start: Int) -> (HTMLTag, end: Int)? {
        var index = start + 1
        guard index < bytes.count, isLetter(bytes[index]) else { return nil }
        let nameStart = index
        while index < bytes.count, isNameCharacter(bytes[index]) { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
        var attributes: [HTMLAttribute] = []

        while true {
            while index < bytes.count, isSpace(bytes[index]) || bytes[index] == UInt8(ascii: "/") { index += 1 }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ">") {
                return (HTMLTag(name: name, attributes: attributes), index + 1)
            }
            let attributeStart = index
            while index < bytes.count, !isSpace(bytes[index]), !"=>/".utf8.contains(bytes[index]) { index += 1 }
            guard index > attributeStart else {
                // A stray `=`: step over it rather than stand still.
                index += 1
                continue
            }
            let attributeName = String(decoding: bytes[attributeStart..<index], as: UTF8.self).lowercased()
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            var value: ArraySlice<UInt8> = []
            if index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                while index < bytes.count, isSpace(bytes[index]) { index += 1 }
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    let valueStart = index + 1
                    guard let close = bytes[valueStart...].firstIndex(of: quote) else { return nil }
                    value = bytes[valueStart..<close]
                    index = close + 1
                } else {
                    let valueStart = index
                    while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") { index += 1 }
                    value = bytes[valueStart..<index]
                }
            }
            attributes.append(HTMLAttribute(
                name: attributeName,
                value: HTMLText.decodeCharacterReferences(String(decoding: value, as: UTF8.self))
            ))
        }
    }

    private static func starts(_ bytes: [UInt8], at index: Int, with text: String) -> Bool {
        bytes[index...].starts(with: text.utf8)
    }

    /// Where `text` next occurs, letters compared without regard to case.
    private static func find(_ text: String, in bytes: [UInt8], from start: Int) -> Int? {
        let needle = Array(text.lowercased().utf8)
        guard start <= bytes.count - needle.count else { return nil }
        return (start...(bytes.count - needle.count)).first { offset in
            needle.indices.allSatisfy { lowercased(bytes[offset + $0]) == needle[$0] }
        }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lowercased(byte))
    }

    private static func isNameCharacter(_ byte: UInt8) -> Bool {
        isLetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }
}

extension HTMLText {
    /// Text made safe to sit inside a double-quoted attribute.
    static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Turns `&amp;`, `&#38;`, `&#x26;` and the other references an address can
    /// carry back into the characters they stand for.
    static func decodeCharacterReferences(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[xX][0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/) { match in
            let reference = match.1
            switch reference {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            case "nbsp": return "\u{A0}"
            default:
                let digits = reference.dropFirst()
                let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
            }
        }
    }
}
