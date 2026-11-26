import Foundation

/// Everything the app asks of a mail account. The state machines talk to this, so
/// tests can stand in for a server without a socket.
public protocol MailService: Sendable {
    func directory() async throws(MailError) -> MailboxDirectory
    /// The newest `limit` messages in a mailbox, or the next `limit` older than a UID.
    func summaries(in mailbox: String, olderThan uid: UInt32?, limit: Int) async throws(MailError) -> SummaryPage
    /// Whole messages, bodies included, in the order asked for.
    func messages(_ ids: [MessageSummary.ID]) async throws(MailError) -> [FullMessage]
    func setSeen(_ seen: Bool, for ids: [MessageSummary.ID]) async throws(MailError)
    func createMailbox(_ path: String) async throws(MailError)
    /// Moves messages to another mailbox, which must exist.
    func move(_ ids: [MessageSummary.ID], to mailbox: String) async throws(MailError)
    func search(_ query: String, in mailbox: String, limit: Int) async throws(MailError) -> [MessageSummary]
    /// Where in a mailbox the messages with these Message-IDs are, for those that
    /// are there: every copy of each, oldest arrival first. A move gives a message
    /// a new number, so this is how moved mail is found again.
    func find(messageIDs: [String], in mailbox: String) async throws(MailError) -> [String: [MessageSummary.ID]]
    func send(_ mail: OutgoingMail) async throws(MailError)
    /// Puts a message into a mailbox, which must exist, as one already read.
    func append(_ message: Data, to mailbox: String) async throws(MailError)
    /// Removes messages from the mailbox they are in. Whether that removes them from
    /// the account is the server's own affair: most drop them, Proton and Gmail keep
    /// them under All Mail unless the mailbox was the trash.
    func delete(_ ids: [MessageSummary.ID]) async throws(MailError)
    /// Returns when something in the mailbox changes. Throws when the wait cannot continue.
    func waitForChange(in mailbox: String) async throws(MailError)
}

/// Where an account's password is kept.
public protocol PasswordStore: Sendable {
    func password(for account: MailAccount) throws(StorageError) -> String?
    func save(_ password: String, for account: MailAccount) throws(StorageError)
    func delete(for account: MailAccount) throws(StorageError)
}

/// Passwords in the login keychain, one generic-password item per account.
public struct KeychainPasswordStore: PasswordStore {
    private let service: String

    public init(service: String = "app.heyday.mac.mail") {
        self.service = service
    }

    public func password(for account: MailAccount) throws(StorageError) -> String? {
        try item(for: account).read()
    }

    public func save(_ password: String, for account: MailAccount) throws(StorageError) {
        try item(for: account).save(password)
    }

    public func delete(for account: MailAccount) throws(StorageError) {
        try item(for: account).delete()
    }

    private func item(for account: MailAccount) -> KeychainItem {
        KeychainItem(
            service: service,
            account: "\(account.username)@\(account.imap.host):\(account.imap.port)",
            label: "Heyday mail password",
            noun: "password"
        )
    }
}

/// `MailService` over IMAP and SMTP.
///
/// One connection carries the app's commands and is redialled when it drops; a second
/// is opened only to wait for changes, since a connection that is idling cannot be
/// asked anything else.
///
/// Requests take turns on the shared connection. IMAP is a single conversation in
/// which a mailbox is selected and the commands after it act on that mailbox, so two
/// requests running at once would select different mailboxes under each other and
/// read each other's replies. Being an actor does not prevent that: an actor lets a
/// second call in whenever the first is waiting on the network.
public actor IMAPMailService: MailService {
    /// The headers a list needs, plus the start of the body for the preview line.
    private static let summaryItems =
        "BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.2048>"
    /// IMAP servers drop an idle connection after half an hour; ask again before that.
    private static let idlePatience: TimeInterval = 25 * 60

    private let account: MailAccount
    private let password: String
    private let connector: any ByteStreamConnector
    private let now: @Sendable () -> Date
    private var session: IMAPSession?
    /// Whether a request has the shared connection, and the requests queued behind it.
    private var isConnectionTaken = false
    private var waitingForConnection: [CheckedContinuation<Void, Never>] = []

    public init(
        account: MailAccount,
        password: String,
        connector: any ByteStreamConnector,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.password = password
        self.connector = connector
        self.now = now
    }

    // MARK: Reading

    public func directory() async throws(MailError) -> MailboxDirectory {
        let listed = try await withSession { session throws(MailError) in try await session.mailboxes() }
        return MailboxDirectory(
            mailboxes: listed.map(Self.mailbox),
            delimiter: listed.compactMap(\.delimiter).first ?? "/"
        )
    }

    public func summaries(in mailbox: String, olderThan uid: UInt32?, limit: Int) async throws(MailError) -> SummaryPage {
        try await withSession { session throws(MailError) in
            try await session.select(mailbox, readOnly: true)
            var uids = try await session.search([.text("ALL")])
            if let uid { uids.removeAll { $0 >= uid } }
            let page = Array(uids.suffix(limit))
            let fetched = try await session.fetch(page, items: Self.summaryItems)
            return SummaryPage(
                messages: fetched.map { Self.summary($0, in: mailbox) }.sorted { $0.id.uid > $1.id.uid },
                hasMore: uids.count > page.count
            )
        }
    }

    public func messages(_ ids: [MessageSummary.ID]) async throws(MailError) -> [FullMessage] {
        var loaded: [MessageSummary.ID: FullMessage] = [:]
        for (mailbox, group) in Dictionary(grouping: ids, by: \.mailbox) {
            let fetched = try await withSession { session throws(MailError) in
                try await session.select(mailbox, readOnly: true)
                return try await session.fetch(group.map(\.uid), items: "BODY.PEEK[]")
            }
            for message in fetched {
                guard let raw = message.full else { continue }
                let parsed = MIMEMessage(raw)
                let id = MessageSummary.ID(mailbox: mailbox, uid: message.uid)
                loaded[id] = FullMessage(
                    summary: MessageSummary(id: id, flags: message.flags, received: message.received, headers: parsed.headers, partialBody: Data()),
                    html: parsed.html,
                    attachments: parsed.attachments,
                    references: parsed.headers.messageIDs("references")
                )
            }
        }
        return ids.compactMap { loaded[$0] }
    }

    public func find(messageIDs: [String], in mailbox: String) async throws(MailError) -> [String: [MessageSummary.ID]] {
        guard !messageIDs.isEmpty else { return [:] }
        return try await withSession { session throws(MailError) in
            try await session.select(mailbox, readOnly: true)
            var found: [String: [MessageSummary.ID]] = [:]
            // Each id is asked about once, however many moved messages share it.
            for messageID in messageIDs where found[messageID] == nil {
                let uids = try await session.search([.text("HEADER Message-ID "), .string(messageID)])
                if !uids.isEmpty {
                    found[messageID] = uids.map { MessageSummary.ID(mailbox: mailbox, uid: $0) }
                }
            }
            return found
        }
    }

    public func search(_ query: String, in mailbox: String, limit: Int) async throws(MailError) -> [MessageSummary] {
        try await withSession { session throws(MailError) in
            try await session.select(mailbox, readOnly: true)
            // Naming the charset is required for anything but ASCII, and harmless for ASCII.
            let uids = try await session.search([.text("CHARSET UTF-8 TEXT "), .string(query)])
            let fetched = try await session.fetch(Array(uids.suffix(limit)), items: Self.summaryItems)
            return fetched.map { Self.summary($0, in: mailbox) }.sorted { $0.id.uid > $1.id.uid }
        }
    }

    // MARK: Changing

    public func setSeen(_ seen: Bool, for ids: [MessageSummary.ID]) async throws(MailError) {
        for (mailbox, group) in Dictionary(grouping: ids, by: \.mailbox) {
            try await withSession { session throws(MailError) in
                try await session.select(mailbox, readOnly: false)
                try await session.store(group.map(\.uid), flag: "\\Seen", set: seen)
            }
        }
    }

    public func createMailbox(_ path: String) async throws(MailError) {
        try await withSession { session throws(MailError) in try await session.create(path) }
    }

    public func move(_ ids: [MessageSummary.ID], to mailbox: String) async throws(MailError) {
        for (source, group) in Dictionary(grouping: ids, by: \.mailbox) where source != mailbox {
            try await withSession { session throws(MailError) in
                try await session.select(source, readOnly: false)
                try await session.move(group.map(\.uid), to: mailbox)
            }
        }
    }

    public func append(_ message: Data, to mailbox: String) async throws(MailError) {
        try await withSession { session throws(MailError) in
            try await session.append(message, to: mailbox, flags: "\\Seen")
        }
    }

    public func delete(_ ids: [MessageSummary.ID]) async throws(MailError) {
        for (mailbox, group) in Dictionary(grouping: ids, by: \.mailbox) {
            try await withSession { session throws(MailError) in
                try await session.select(mailbox, readOnly: false)
                try await session.delete(group.map(\.uid))
            }
        }
    }

    public func send(_ mail: OutgoingMail) async throws(MailError) {
        let message = mail.rfc5322(messageID: OutgoingMail.newMessageID(for: mail.from), date: now())
        try await SMTPClient.send(
            message,
            from: mail.from.address,
            to: mail.recipients.map(\.address),
            via: account.smtp,
            username: account.username,
            password: password,
            using: connector
        )
        guard !account.serverSavesSentMail else { return }
        let directory = try await self.directory()
        if let sent = directory.path(for: .sent) {
            try await append(message, to: sent)
        }
    }

    public func waitForChange(in mailbox: String) async throws(MailError) {
        let idle = try await IMAPSession.open(account.imap, username: account.username, password: password, using: connector)
        do {
            try await idle.select(mailbox, readOnly: true)
            try await idle.waitForChange(patience: Self.idlePatience)
            await idle.close()
        } catch {
            await idle.close()
            throw error
        }
    }

    // MARK: Connection

    /// Runs commands on the shared connection, dialling it if needed, once every
    /// request ahead of this one has finished. A connection that turns out to be dead
    /// is replaced and the commands run once more.
    private func withSession<Value: Sendable>(
        _ commands: (IMAPSession) async throws(MailError) -> Value
    ) async throws(MailError) -> Value {
        await takeConnection()
        defer { releaseConnection() }
        if let session {
            do {
                return try await commands(session)
            } catch {
                guard error.kind == .unreachable else { throw error }
                await session.close()
                self.session = nil
            }
        }
        let fresh = try await IMAPSession.open(account.imap, username: account.username, password: password, using: connector)
        session = fresh
        return try await commands(fresh)
    }

    private func takeConnection() async {
        guard isConnectionTaken else {
            isConnectionTaken = true
            return
        }
        await withCheckedContinuation { waitingForConnection.append($0) }
    }

    /// Hands the connection straight to the next request in line, if there is one.
    private func releaseConnection() {
        if waitingForConnection.isEmpty {
            isConnectionTaken = false
        } else {
            waitingForConnection.removeFirst().resume()
        }
    }

    // MARK: Mapping

    private static func summary(_ message: IMAPSession.Message, in mailbox: String) -> MessageSummary {
        MessageSummary(
            id: .init(mailbox: mailbox, uid: message.uid),
            flags: message.flags,
            received: message.received,
            headers: MIMEHeaders(message.header ?? Data()),
            partialBody: message.text ?? Data()
        )
    }

    static func mailbox(_ listed: IMAPSession.Mailbox) -> Mailbox {
        let readable = IMAPMailboxName.decode(listed.name)
        let leaf = listed.delimiter.flatMap { readable.components(separatedBy: $0).last } ?? readable
        return Mailbox(
            path: listed.name,
            displayPath: readable,
            name: leaf,
            role: role(of: listed),
            isSelectable: !listed.attributes.contains("\\noselect")
        )
    }

    /// The server's own special-use flag where it gives one, and otherwise the names
    /// servers conventionally use.
    private static func role(of listed: IMAPSession.Mailbox) -> Mailbox.Role? {
        if listed.name.uppercased() == "INBOX" { return .inbox }
        let flagged: [(String, Mailbox.Role)] = [
            ("\\sent", .sent), ("\\drafts", .drafts), ("\\trash", .trash),
            ("\\junk", .spam), ("\\archive", .archive), ("\\all", .all),
        ]
        if let match = flagged.first(where: { listed.attributes.contains($0.0) }) { return match.1 }
        switch listed.name.lowercased() {
        case "sent", "sent mail", "sent messages", "sent items": return .sent
        case "drafts": return .drafts
        case "trash", "deleted messages", "deleted items": return .trash
        case "spam", "junk", "junk mail": return .spam
        case "archive": return .archive
        case "all mail": return .all
        default: return nil
        }
    }
}
