import Foundation

/// Why something could not be done with the mail server.
public struct MailError: Error, Equatable, Sendable {
    public enum Kind: Sendable {
        /// No connection, or it dropped.
        case unreachable
        /// The server would not accept the username and password.
        case loginRefused
        /// The server understood the request and said no.
        case refused
        /// The server said something this client could not make sense of.
        case garbled
        /// The account has not been set up, or its password is missing.
        case notConfigured
        /// The mail asked about is not where it was last put.
        case missing
    }

    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    /// One sentence a person can act on.
    public var userMessage: String {
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        return switch kind {
        case .unreachable: "Couldn’t reach the mail server.\(suffix)"
        case .loginRefused: "The mail server didn’t accept that username and password.\(suffix)"
        case .refused: "The mail server refused that.\(suffix)"
        case .garbled: "The mail server answered in a way this app doesn’t understand.\(suffix)"
        case .notConfigured: "This account isn’t set up yet."
        case .missing: "That mail is no longer where it was put.\(suffix)"
        }
    }
}

/// One authenticated IMAP connection.
///
/// IMAP is a strictly sequential conversation: a command is sent, its responses are
/// read to the tagged completion, and only then may the next go out. Being an actor
/// keeps this state safe but does not enforce that order, so whoever shares a session
/// between tasks must let one finish before the next begins, as `IMAPMailService` does.
actor IMAPSession {
    struct Mailbox: Equatable, Sendable {
        /// As the server spells it; this is what commands must use.
        let name: String
        let delimiter: String?
        /// Lowercased, e.g. `\sent`, `\noselect`.
        let attributes: Set<String>
    }

    struct Message: Equatable, Sendable {
        let uid: UInt32
        /// Lowercased, e.g. `\seen`.
        let flags: Set<String>
        /// When the server took delivery of the message.
        let received: Date?
        let header: Data?
        let text: Data?
        let full: Data?
    }

    /// A piece of a command.
    enum Part {
        case text(String)
        /// A string argument, sent quoted when it safely can be and as a literal otherwise.
        case string(String)
        case literal(Data)
    }

    private let stream: any ByteStream
    private let reader: BufferedReader
    private var nextTag = 1
    private var capabilities: Set<String> = []
    private var selected: (mailbox: String, readOnly: Bool)?

    private init(stream: any ByteStream) {
        self.stream = stream
        reader = BufferedReader(stream: stream)
    }

    /// Connects, secures the connection as the endpoint asks, and logs in.
    static func open(
        _ endpoint: ServerEndpoint,
        username: String,
        password: String,
        using connector: any ByteStreamConnector
    ) async throws(MailError) -> IMAPSession {
        try await open(endpoint, username: username, credential: .password(password), using: connector)
    }

    /// Connects, secures the connection as the endpoint asks, and authenticates using
    /// either a password (`LOGIN`) or an OAuth 2.0 access token (`AUTHENTICATE XOAUTH2`).
    static func open(
        _ endpoint: ServerEndpoint,
        username: String,
        credential: MailCredential,
        using connector: any ByteStreamConnector
    ) async throws(MailError) -> IMAPSession {
        let stream: any ByteStream
        do {
            stream = try await connector.connect(to: endpoint)
        } catch {
            throw MailError(.unreachable, error.message)
        }
        let session = IMAPSession(stream: stream)
        do {
            try await session.start(security: endpoint.security, username: username, credential: credential)
        } catch {
            stream.close()
            throw error
        }
        return session
    }

    private func start(security: ConnectionSecurity, username: String, credential: MailCredential) async throws(MailError) {
        guard case .status(let status, _) = try await readResponse(), status == .ok || status == .preauth else {
            throw MailError(.garbled, "no greeting")
        }
        if security == .startTLS {
            try await run([.text("STARTTLS")])
            do {
                try await stream.startTLS()
            } catch {
                throw MailError(.unreachable, error.message)
            }
            await reader.discardBuffer()
        }
        try await authenticate(username: username, credential: credential)
        for response in try await run([.text("CAPABILITY")]) {
            if case .capability(let advertised) = response { capabilities = advertised }
        }
    }

    private func authenticate(username: String, credential: MailCredential) async throws(MailError) {
        switch credential {
        case .password(let password):
            do {
                try await run([.text("LOGIN "), .string(username), .text(" "), .string(password)])
            } catch {
                throw error.kind == .refused ? MailError(.loginRefused, error.detail) : error
            }
        case .xoauth2:
            guard let initial = credential.xoauth2SASLResponse(username: username) else {
                throw MailError(.notConfigured, "Missing XOAUTH2 token")
            }
            let tag = takeTag()
            try await write(Data("\(tag) AUTHENTICATE XOAUTH2 \(initial)\r\n".utf8))
            var challengeDetail: String?
            while true {
                switch try await readResponse() {
                case .continuation(let challenge):
                    // Per Google/Microsoft XOAUTH2, a continuation after SASL-IR carries a
                    // base64 JSON error; replying with an empty line terminates the SASL exchange.
                    if let decoded = MailCredential.decodeXOAuth2ErrorChallenge(challenge) {
                        challengeDetail = decoded
                    }
                    try await write(Data("\r\n".utf8))
                case .tagged(let done, let status, let text) where done == tag:
                    if status == .ok { return }
                    let detail = [challengeDetail, text.isEmpty ? nil : text].compactMap { $0 }.joined(separator: " — ")
                    throw MailError(.loginRefused, detail)
                case .capability(let advertised):
                    capabilities = advertised
                default:
                    break
                }
            }
        }
    }

    func close() {
        stream.close()
    }

    // MARK: Commands

    func mailboxes() async throws(MailError) -> [Mailbox] {
        try await run([.text("LIST \"\" \"*\"")]).compactMap { response in
            if case .list(let attributes, let delimiter, let name) = response {
                Mailbox(name: name, delimiter: delimiter, attributes: attributes)
            } else {
                nil
            }
        }
    }

    /// Opens a mailbox for the commands that follow. Returns how many messages it holds.
    @discardableResult
    func select(_ mailbox: String, readOnly: Bool) async throws(MailError) -> Int {
        // Re-selecting is how IMAP reports new arrivals, so this always asks.
        selected = nil
        let responses = try await run([.text(readOnly ? "EXAMINE " : "SELECT "), .string(mailbox)])
        selected = (mailbox, readOnly)
        for response in responses {
            if case .exists(let count) = response { return count }
        }
        return 0
    }

    /// Every UID in the selected mailbox matching the criteria, ascending.
    func search(_ criteria: [Part]) async throws(MailError) -> [UInt32] {
        var uids: [UInt32] = []
        for response in try await run([.text("UID SEARCH ")] + criteria) {
            if case .search(let found) = response { uids += found }
        }
        return uids.sorted()
    }

    func fetch(_ uids: [UInt32], items: String) async throws(MailError) -> [Message] {
        guard !uids.isEmpty else { return [] }
        return try await run([.text("UID FETCH \(Self.sequenceSet(uids)) (UID FLAGS INTERNALDATE \(items))")], timeout: 180)
            .compactMap { response in
                guard case .fetch(let fields) = response, let uid = fields["UID"]?.text.flatMap(UInt32.init) else { return nil }
                return Message(
                    uid: uid,
                    flags: Set(fields["FLAGS"]?.items.compactMap(\.text).map { $0.lowercased() } ?? []),
                    received: fields["INTERNALDATE"]?.text.flatMap(MailDate.parseInternal),
                    header: fields["BODY[HEADER]"]?.data,
                    text: fields["BODY[TEXT]"]?.data,
                    full: fields["BODY[]"]?.data
                )
            }
    }

    func store(_ uids: [UInt32], flag: String, set: Bool) async throws(MailError) {
        guard !uids.isEmpty else { return }
        try await run([.text("UID STORE \(Self.sequenceSet(uids)) \(set ? "+" : "-")FLAGS.SILENT (\(flag))")])
    }

    func move(_ uids: [UInt32], to mailbox: String) async throws(MailError) {
        guard !uids.isEmpty else { return }
        let set = Self.sequenceSet(uids)
        if capabilities.contains("MOVE") {
            try await run([.text("UID MOVE \(set) "), .string(mailbox)])
        } else {
            // The pre-MOVE way: copy, then remove the originals.
            try await run([.text("UID COPY \(set) "), .string(mailbox)])
            try await delete(uids)
        }
    }

    /// Removes messages from the selected mailbox: marks them deleted, then purges
    /// them. A server without UIDPLUS purges everything marked deleted there.
    func delete(_ uids: [UInt32]) async throws(MailError) {
        guard !uids.isEmpty else { return }
        let set = Self.sequenceSet(uids)
        try await run([.text("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")])
        try await run([.text(capabilities.contains("UIDPLUS") ? "UID EXPUNGE \(set)" : "EXPUNGE")])
    }

    func create(_ mailbox: String) async throws(MailError) {
        try await run([.text("CREATE "), .string(mailbox)])
    }

    func append(_ message: Data, to mailbox: String, flags: String) async throws(MailError) {
        try await run([.text("APPEND "), .string(mailbox), .text(" (\(flags)) "), .literal(message)])
    }

    /// Waits in the selected mailbox until the server reports a change. Throws if the
    /// connection goes quiet for longer than `patience`, which is the cue to reconnect.
    func waitForChange(patience: TimeInterval) async throws(MailError) {
        let tag = takeTag()
        try await write(Data("\(tag) IDLE\r\n".utf8))
        var isIdling = false
        while true {
            switch try await readResponse(timeout: patience) {
            case .continuation:
                isIdling = true
            case .exists, .expunge, .fetch:
                guard isIdling else { continue }
                try await write(Data("DONE\r\n".utf8))
                while true {
                    if case .tagged(let done, _, _) = try await readResponse(), done == tag { return }
                }
            case .tagged(let done, let status, let text) where done == tag:
                throw MailError(.refused, status == .ok ? "IDLE ended early" : text)
            default:
                break
            }
        }
    }

    // MARK: Wire

    /// Sends one command and returns the untagged responses that preceded its `OK`.
    @discardableResult
    private func run(_ parts: [Part], timeout: TimeInterval = 60) async throws(MailError) -> [IMAPResponse] {
        let tag = takeTag()
        var untagged: [IMAPResponse] = []
        var pending = Data("\(tag) ".utf8)

        for part in parts {
            let literal: Data
            switch part {
            case .text(let text):
                pending.append(Data(text.utf8))
                continue
            case .string(let string) where Self.canQuote(string):
                let escaped = string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                pending.append(Data("\"\(escaped)\"".utf8))
                continue
            case .string(let string):
                literal = Data(string.utf8)
            case .literal(let data):
                literal = data
            }
            // A literal is announced, and sent only once the server says to go ahead.
            pending.append(Data("{\(literal.count)}\r\n".utf8))
            try await write(pending)
            pending = Data()
            awaitingGoAhead: while true {
                switch try await readResponse(timeout: timeout) {
                case .continuation: break awaitingGoAhead
                case .tagged(let done, _, let text) where done == tag: throw MailError(.refused, text)
                case let other: untagged.append(other)
                }
            }
            pending.append(literal)
        }

        pending.append(Data("\r\n".utf8))
        try await write(pending)
        while true {
            let response = try await readResponse(timeout: timeout)
            if case .tagged(let done, let status, let text) = response, done == tag {
                guard status == .ok else { throw MailError(.refused, text) }
                return untagged
            }
            untagged.append(response)
        }
    }

    /// One whole response: a line, plus any literals it announces and the text after them.
    private func readResponse(timeout: TimeInterval = 60) async throws(MailError) -> IMAPResponse {
        do {
            var data = try await reader.line(timeout: timeout)
            while let count = Self.announcedLiteralLength(data) {
                data.append(Data("\r\n".utf8))
                data.append(try await reader.bytes(count, timeout: timeout))
                data.append(try await reader.line(timeout: timeout))
            }
            let response = try IMAPResponse(data)
            if case .status(.bye, let text) = response {
                throw MailError(.unreachable, text)
            }
            return response
        } catch let error as StreamError {
            throw MailError(.unreachable, error.message)
        } catch let error as IMAPSyntaxError {
            throw MailError(.garbled, error.message)
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError(.garbled, String(describing: error))
        }
    }

    private func write(_ data: Data) async throws(MailError) {
        do {
            try await stream.write(data)
        } catch {
            throw MailError(.unreachable, error.message)
        }
    }

    private func takeTag() -> String {
        defer { nextTag += 1 }
        return "A\(nextTag)"
    }

    /// The `n` of a line ending in `{n}`, which promises n more bytes.
    static func announcedLiteralLength(_ line: Data) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        return Int(String(decoding: line[line.index(after: open)..<line.index(before: line.endIndex)], as: UTF8.self))
    }

    /// Whether a string can travel inside double quotes: printable ASCII, no line breaks.
    static func canQuote(_ string: String) -> Bool {
        string.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    /// `1,2,3,7` as `1:3,7`.
    static func sequenceSet(_ uids: [UInt32]) -> String {
        var ranges: [ClosedRange<UInt32>] = []
        for uid in Set(uids).sorted() {
            if let last = ranges.last, last.upperBound + 1 == uid {
                ranges[ranges.count - 1] = last.lowerBound...uid
            } else {
                ranges.append(uid...uid)
            }
        }
        return ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound):\($0.upperBound)" }
            .joined(separator: ",")
    }
}
