import Foundation

/// A file carried by a message.
public struct Attachment: Identifiable, Hashable, Sendable {
    public let id: Int
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(id: Int, filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// A raw RFC 5322 message taken apart: its headers, the body to show, and its files.
public struct MIMEMessage: Sendable, Equatable {
    public let headers: MIMEHeaders
    /// The body as HTML, ready to display. A plain-text message is wrapped so its line
    /// breaks survive, and pictures embedded in the message (`cid:` references) are
    /// inlined as data URLs.
    public let html: String
    public let attachments: [Attachment]

    public init(_ raw: Data) {
        let (headerBlock, body) = Self.splitHeaders(raw)
        headers = MIMEHeaders(headerBlock)
        let leaves = Self.leaves(headers: headers, body: body)

        let htmlLeaf = leaves.first { $0.contentType.type == "text/html" && !$0.isAttachment }
        let textLeaf = leaves.first { $0.contentType.type == "text/plain" && !$0.isAttachment }
        var html: String
        if let htmlLeaf {
            html = htmlLeaf.text
        } else {
            html = HTMLText.wrapPlainText(textLeaf?.text ?? "")
        }

        var files: [Attachment] = []
        for leaf in leaves where leaf !== htmlLeaf && leaf !== textLeaf {
            // A part the body refers to by content id is drawn in place, not listed.
            if let contentID = leaf.contentID, html.contains("cid:\(contentID)") {
                let url = "data:\(leaf.contentType.type);base64,\(leaf.data.base64EncodedString())"
                html = html.replacingOccurrences(of: "cid:\(contentID)", with: url)
            } else {
                files.append(Attachment(
                    id: files.count,
                    filename: leaf.filename ?? "Attachment \(files.count + 1)",
                    mimeType: leaf.contentType.type,
                    data: leaf.data
                ))
            }
        }
        self.html = html
        attachments = files
    }

    /// A one-line preview from the start of a message whose body may be cut short.
    ///
    /// Lists fetch only the first kilobyte or two of each body, so this tolerates a
    /// missing closing boundary and a base64 or quoted-printable run that stops mid-way.
    public static func preview(headers: MIMEHeaders, partialBody: Data, limit: Int = 200) -> String {
        let leaves = leaves(headers: headers, body: partialBody)
        let leaf = leaves.first { $0.contentType.type == "text/plain" && !$0.isAttachment }
            ?? leaves.first { $0.contentType.type == "text/html" && !$0.isAttachment }
        guard let leaf else { return "" }
        let text = leaf.contentType.type == "text/html" ? HTMLText.plainText(fromHTML: leaf.text) : leaf.text
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    // MARK: Structure

    /// One non-multipart part, decoded.
    final class Leaf {
        let contentType: ContentType
        let data: Data
        let filename: String?
        let contentID: String?
        let isAttachment: Bool

        init(headers: MIMEHeaders, body: Data) {
            contentType = headers.contentType
            data = TransferEncoding.decode(body, as: headers.transferEncoding)
            let disposition = ContentType(headers.raw("content-disposition") ?? "")
            filename = disposition.parameters["filename"] ?? contentType.parameters["name"]
            contentID = headers.raw("content-id").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
            isAttachment = disposition.type == "attachment"
        }

        var text: String {
            Charset.string(from: data, named: contentType.parameters["charset"])
        }
    }

    static func leaves(headers: MIMEHeaders, body: Data) -> [Leaf] {
        let contentType = headers.contentType
        guard contentType.isMultipart, let boundary = contentType.parameters["boundary"] else {
            return [Leaf(headers: headers, body: body)]
        }
        return parts(of: body, boundary: boundary).flatMap { part in
            let (headerBlock, partBody) = splitHeaders(part)
            return leaves(headers: MIMEHeaders(headerBlock), body: partBody)
        }
    }

    /// The pieces between `--boundary` lines. A body that ends before the closing
    /// boundary still yields the pieces that are there.
    static func parts(of body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchStart = body.startIndex
        var partStart: Data.Index?
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            // Only a delimiter at the start of a line separates parts.
            let atLineStart = range.lowerBound == body.startIndex || body[body.index(before: range.lowerBound)] == UInt8(ascii: "\n")
            if atLineStart {
                if let start = partStart {
                    parts.append(trimmingLineBreak(body[start..<range.lowerBound]))
                }
                let isClosing = body[range.upperBound...].starts(with: Data("--".utf8))
                if isClosing {
                    partStart = nil
                    break
                }
                // The part begins after the rest of the delimiter line.
                if let lineEnd = body[range.upperBound...].firstIndex(of: UInt8(ascii: "\n")) {
                    partStart = body.index(after: lineEnd)
                } else {
                    partStart = nil
                    break
                }
            }
            searchStart = range.upperBound
        }
        if let start = partStart, start < body.endIndex {
            parts.append(Data(body[start...]))
        }
        return parts
    }

    /// Splits a message or part at the blank line after its headers.
    static func splitHeaders(_ data: Data) -> (headers: Data, body: Data) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = data.range(of: Data(separator.utf8)) {
                return (Data(data[..<range.lowerBound]), Data(data[range.upperBound...]))
            }
        }
        // No blank line: a part with no headers starts with one; otherwise it is all headers.
        if data.starts(with: Data("\r\n".utf8)) { return (Data(), Data(data.dropFirst(2))) }
        if data.starts(with: Data("\n".utf8)) { return (Data(), Data(data.dropFirst(1))) }
        return (data, Data())
    }

    /// The line break before a boundary belongs to the boundary, not to the part.
    private static func trimmingLineBreak(_ slice: Data) -> Data {
        var end = slice.endIndex
        if end > slice.startIndex, slice[slice.index(before: end)] == UInt8(ascii: "\n") { end = slice.index(before: end) }
        if end > slice.startIndex, slice[slice.index(before: end)] == UInt8(ascii: "\r") { end = slice.index(before: end) }
        return Data(slice[slice.startIndex..<end])
    }
}

/// Content-Transfer-Encoding: how a part's bytes were made safe for mail transport.
enum TransferEncoding {
    static func decode(_ data: Data, as encoding: String) -> Data {
        switch encoding {
        case "base64":
            // Drop anything past the last complete group, so a body cut short still decodes.
            let characters = data.filter { byte in
                switch byte {
                case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="):
                    true
                default:
                    false
                }
            }
            let whole = characters.prefix(characters.count - characters.count % 4)
            return Data(base64Encoded: Data(whole)) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var output = Data(capacity: data.count)
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index = data.index(after: index)
                continue
            }
            let rest = data[data.index(after: index)...]
            if rest.starts(with: Data("\r\n".utf8)) {
                index = data.index(index, offsetBy: 3) // soft line break
            } else if rest.first == UInt8(ascii: "\n") {
                index = data.index(index, offsetBy: 2)
            } else if rest.count >= 2, let value = UInt8(String(decoding: rest.prefix(2), as: UTF8.self), radix: 16) {
                output.append(value)
                index = data.index(index, offsetBy: 3)
            } else {
                output.append(byte) // a stray "=", or the text was cut off here
                index = data.index(after: index)
            }
        }
        return output
    }

    /// Base64 in 76-column lines, for a part being sent.
    static func encodeBase64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }
}

/// Conversions between plain text and the HTML the message view displays.
public enum HTMLText {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Plain text as HTML that keeps its line breaks and spacing.
    static func wrapPlainText(_ text: String) -> String {
        "<div style=\"white-space: pre-wrap\">\(escape(text))</div>"
    }

    /// Typed text as the HTML to send: one block per line.
    static func blocks(fromPlainText text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<div>\($0.isEmpty ? "<br>" : escape(String($0)))</div>" }
            .joined()
    }

    /// A rough reading of an HTML document's text, good enough for a preview line.
    static func plainText(fromHTML html: String) -> String {
        html.replacing(/(?is)<(style|script|head)\b.*?(<\/\1>|$)/, with: " ")
            .replacing(/(?s)<!--.*?(-->|$)/, with: " ")
            .replacing(/(?s)<[^>]*(>|$)/, with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&zwnj;", with: "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
