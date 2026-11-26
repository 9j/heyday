import Foundation

/// An email ready to be sent.
public struct OutgoingMail: Equatable, Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var textBody: String
    public var htmlBody: String
    /// The message this one answers, and the conversation before it, so mail clients
    /// keep the reply in its thread.
    public var inReplyTo: String?
    public var references: [String]

    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        textBody: String,
        htmlBody: String,
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// Everyone the SMTP server must deliver to, blind copies included.
    public var recipients: [EmailAddress] { to + cc + bcc }

    /// The message as it goes over the wire: headers, then the body as both plain
    /// text and HTML. Blind-copy recipients are deliberately absent from the headers.
    public func rfc5322(messageID: String, date: Date) -> Data {
        let boundary = "heyday-\(messageID.filter { $0.isLetter || $0.isNumber }.prefix(24))"
        var headers = [
            "From: \(Self.header(from))",
            "To: \(to.map(Self.header).joined(separator: ", "))",
        ]
        if !cc.isEmpty { headers.append("Cc: \(cc.map(Self.header).joined(separator: ", "))") }
        headers += [
            "Subject: \(EncodedWord.encode(subject))",
            "Date: \(MailDate.format(date))",
            "Message-ID: \(messageID)",
        ]
        if let inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        if !references.isEmpty { headers.append("References: \(references.joined(separator: " "))") }
        headers += [
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
        ]

        func part(_ type: String, _ content: String) -> String {
            """
            --\(boundary)\r
            Content-Type: \(type); charset=utf-8\r
            Content-Transfer-Encoding: base64\r
            \r
            \(TransferEncoding.encodeBase64(Data(content.utf8)))\r

            """
        }
        let body = part("text/plain", textBody) + part("text/html", htmlBody) + "--\(boundary)--\r\n"
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    /// `<random@sender-domain>`, unique to one message.
    public static func newMessageID(for sender: EmailAddress, uuid: UUID = UUID()) -> String {
        let domain = sender.address.split(separator: "@").last.map(String.init) ?? "localhost"
        return "<\(uuid.uuidString.lowercased())@\(domain)>"
    }

    private static func header(_ address: EmailAddress) -> String {
        guard !address.name.isEmpty else { return address.address }
        let name = address.name.allSatisfy(\.isASCII)
            ? "\"\(address.name.replacingOccurrences(of: "\"", with: "\\\""))\""
            : EncodedWord.encode(address.name)
        return "\(name) <\(address.address)>"
    }
}

/// Sends one message through an SMTP server.
enum SMTPClient {
    static func send(
        _ message: Data,
        from sender: String,
        to recipients: [String],
        via endpoint: ServerEndpoint,
        username: String,
        password: String,
        using connector: any ByteStreamConnector
    ) async throws(MailError) {
        let stream: any ByteStream
        do {
            stream = try await connector.connect(to: endpoint)
        } catch {
            throw MailError(.unreachable, error.message)
        }
        defer { stream.close() }
        let reader = BufferedReader(stream: stream)

        func expect(_ accepted: Set<Int>, afterSending command: String?) async throws(MailError) {
            do {
                if let command {
                    try await stream.write(Data("\(command)\r\n".utf8))
                }
                // A reply is one or more lines; the last has a space after the code.
                var line: String
                repeat {
                    line = String(decoding: try await reader.line(timeout: 60), as: UTF8.self)
                } while line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == "-"
                guard let code = Int(line.prefix(3)) else { throw MailError(.garbled, line) }
                guard accepted.contains(code) else { throw MailError(.refused, line) }
            } catch let error as StreamError {
                throw MailError(.unreachable, error.message)
            } catch let error as MailError {
                throw error
            } catch {
                throw MailError(.garbled, String(describing: error))
            }
        }

        try await expect([220], afterSending: nil)
        try await expect([250], afterSending: "EHLO localhost")
        if endpoint.security == .startTLS {
            try await expect([220], afterSending: "STARTTLS")
            do {
                try await stream.startTLS()
            } catch {
                throw MailError(.unreachable, error.message)
            }
            await reader.discardBuffer()
            try await expect([250], afterSending: "EHLO localhost")
        }
        let credentials = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
        do {
            try await expect([235], afterSending: "AUTH PLAIN \(credentials)")
        } catch {
            // Servers disagree on the code for a bad login (535, 534, 454…); whatever
            // refusal answers AUTH is one.
            throw error.kind == .refused ? MailError(.loginRefused, error.detail) : error
        }
        try await expect([250], afterSending: "MAIL FROM:<\(sender)>")
        for recipient in recipients {
            try await expect([250, 251], afterSending: "RCPT TO:<\(recipient)>")
        }
        try await expect([354], afterSending: "DATA")
        do {
            try await stream.write(dotStuffed(message) + Data("\r\n.\r\n".utf8))
        } catch {
            throw MailError(.unreachable, error.message)
        }
        try await expect([250], afterSending: nil)
        // The message is accepted; a failed goodbye changes nothing.
        try? await expect([221], afterSending: "QUIT")
    }

    /// A line that is a lone "." ends the message, so lines that start with one get a second.
    static func dotStuffed(_ message: Data) -> Data {
        let text = String(decoding: message, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }
        var stuffed = lines.joined(separator: "\r\n")
        // The caller adds the terminating line; "\r\n" is a single Character in Swift.
        while stuffed.hasSuffix("\r\n") { stuffed.removeLast() }
        return Data(stuffed.utf8)
    }
}
