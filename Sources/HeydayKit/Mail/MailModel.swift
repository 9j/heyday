import Foundation

/// An email account: who you are and where your mail lives.
public struct MailAccount: Identifiable, Codable, Equatable, Sendable {
    public var sender: EmailAddress
    public var username: String
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    /// Proton Mail Bridge and Gmail file what you send into Sent themselves. Servers
    /// that do not need the client to put a copy there.
    public var serverSavesSentMail: Bool
    /// How this account signs in to IMAP and SMTP. Defaults to `.password` for
    /// accounts saved before OAuth 2.0 support was added.
    public var authMethod: MailAuthMethod

    /// Stable identifier distinguishing multiple accounts across addresses and servers.
    public var id: String {
        "\(sender.key)@\(imap.host.lowercased()):\(imap.port)"
    }

    public init(
        sender: EmailAddress,
        username: String,
        imap: ServerEndpoint,
        smtp: ServerEndpoint,
        serverSavesSentMail: Bool,
        authMethod: MailAuthMethod = .password
    ) {
        self.sender = sender
        self.username = username
        self.imap = imap
        self.smtp = smtp
        self.serverSavesSentMail = serverSavesSentMail
        self.authMethod = authMethod
    }

    private enum CodingKeys: String, CodingKey {
        case sender, username, imap, smtp, serverSavesSentMail, authMethod
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sender = try container.decode(EmailAddress.self, forKey: .sender)
        username = try container.decode(String.self, forKey: .username)
        imap = try container.decode(ServerEndpoint.self, forKey: .imap)
        smtp = try container.decode(ServerEndpoint.self, forKey: .smtp)
        serverSavesSentMail = try container.decode(Bool.self, forKey: .serverSavesSentMail)
        authMethod = try container.decodeIfPresent(MailAuthMethod.self, forKey: .authMethod) ?? .password
    }
}

/// A folder on the mail server.
public struct Mailbox: Identifiable, Hashable, Sendable {
    /// What the server uses a mailbox for, when it says so or its name makes it plain.
    public enum Role: String, Hashable, Sendable {
        case inbox, sent, drafts, trash, spam, archive, all
    }

    /// The server's own spelling of the full path. Commands must use this.
    public let path: String
    /// The full path, readable: `path` with any non-ASCII names decoded.
    public let displayPath: String
    /// The last path component, readable.
    public let name: String
    public let role: Role?
    public let isSelectable: Bool

    public var id: String { path }

    /// - Parameter displayPath: defaults to `path`, which is right for ASCII names.
    public init(path: String, displayPath: String? = nil, name: String, role: Role?, isSelectable: Bool = true) {
        self.path = path
        self.displayPath = displayPath ?? path
        self.name = name
        self.role = role
        self.isSelectable = isSelectable
    }
}

/// The account's folders, and where this app keeps the HEY-style ones it adds.
public struct MailboxDirectory: Equatable, Sendable {
    /// Folders this app creates to hold threads you have put somewhere on purpose.
    public enum AppFolder: String, Hashable, Sendable, CaseIterable {
        case replyLater = "Reply Later"
        case setAside = "Set Aside"
    }

    public let mailboxes: [Mailbox]
    private let delimiter: String

    public init(mailboxes: [Mailbox], delimiter: String = "/") {
        self.mailboxes = mailboxes
        self.delimiter = delimiter
    }

    public func path(for role: Mailbox.Role) -> String? {
        mailboxes.first { $0.role == role }?.path
    }

    public var inbox: String { path(for: .inbox) ?? "INBOX" }

    /// Where an app folder is when it goes by its own name, or where one would be made.
    public func path(for folder: AppFolder) -> String {
        let fresh = path(forNewFolderNamed: folder.rawValue)
        return mailboxes.first { $0.path == fresh || $0.path == folder.rawValue }?.path ?? fresh
    }

    /// The path a new folder of this name would have. Proton Mail Bridge only lets
    /// folders be made under its `Folders` container; other servers take them at the top.
    public func path(forNewFolderNamed name: String) -> String {
        let hasFoldersContainer = mailboxes.contains { $0.path == "Folders" || $0.path.hasPrefix("Folders\(delimiter)") }
        return hasFoldersContainer ? "Folders\(delimiter)\(name)" : name
    }

    /// The person's own folders and labels: every mailbox that holds mail and is not
    /// a standard one.
    /// - Parameter appFolderPaths: mailboxes the app uses for Reply Later and Set
    ///   Aside, which are shown under those names instead.
    public func userFolders(excluding appFolderPaths: Set<String> = []) -> [Mailbox] {
        mailboxes.filter { $0.isSelectable && $0.role == nil && !appFolderPaths.contains($0.path) }
    }

    /// `userFolders`, grouped the way the server groups them. Some servers keep them
    /// under top-level containers that hold no mail themselves (Proton's `Folders`
    /// and `Labels`): each of those is a group, named after the container. Folders
    /// under no such container form one group with no name, listed first.
    public func userFolderGroups(excluding appFolderPaths: Set<String> = []) -> [MailboxGroup] {
        let containers = mailboxes.filter { !$0.isSelectable && !$0.path.contains(delimiter) }
        func container(of mailbox: Mailbox) -> Mailbox? {
            containers.first { mailbox.path.hasPrefix($0.path + delimiter) }
        }
        let folders = userFolders(excluding: appFolderPaths)
        let loose = MailboxGroup(title: nil, mailboxes: folders.filter { container(of: $0) == nil })
        let contained = containers.map { holder in
            MailboxGroup(title: holder.name, mailboxes: folders.filter { container(of: $0) == holder })
        }
        return ([loose] + contained).filter { !$0.mailboxes.isEmpty }
    }
}

/// Folders that belong together in a list.
public struct MailboxGroup: Identifiable, Equatable, Sendable {
    /// Nil for folders that sit at the top level of the account.
    public let title: String?
    public let mailboxes: [Mailbox]

    public var id: String { title ?? "" }
}

/// What a list shows of one message: its headers and the start of its text.
public struct MessageSummary: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Codable, Sendable {
        public let mailbox: String
        public let uid: UInt32

        public init(mailbox: String, uid: UInt32) {
            self.mailbox = mailbox
            self.uid = uid
        }
    }

    public let id: ID
    public let messageID: String?
    /// The id of the message that started the conversation this one belongs to.
    public let threadRoot: String
    public let from: EmailAddress?
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let subject: String
    /// When the sender says it was written.
    public let date: Date?
    /// When the server took delivery of it. Unlike `date`, the sender cannot set this.
    public let received: Date?
    public var isSeen: Bool
    public let hasAttachments: Bool
    public let preview: String

    public init(
        id: ID,
        messageID: String? = nil,
        threadRoot: String? = nil,
        from: EmailAddress? = nil,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        subject: String = "",
        date: Date? = nil,
        received: Date? = nil,
        isSeen: Bool = true,
        hasAttachments: Bool = false,
        preview: String = ""
    ) {
        self.id = id
        self.messageID = messageID
        // A message nobody replied to, and which replies to nothing, is its own thread.
        self.threadRoot = threadRoot ?? messageID ?? "uid:\(id.mailbox):\(id.uid)"
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.received = received
        self.isSeen = isSeen
        self.hasAttachments = hasAttachments
        self.preview = preview
    }

    /// Builds a summary from what a list fetch returns: flags, arrival time, selected
    /// headers and the first bytes of the body.
    init(id: ID, flags: Set<String>, received: Date?, headers: MIMEHeaders, partialBody: Data) {
        let references = headers.messageIDs("references")
        let messageID = headers.messageIDs("message-id").first
        self.init(
            id: id,
            messageID: messageID,
            threadRoot: references.first ?? headers.messageIDs("in-reply-to").first ?? messageID,
            from: headers.addresses("from").first,
            to: headers.addresses("to"),
            cc: headers.addresses("cc"),
            subject: headers.text("subject") ?? "",
            date: headers.date,
            received: received,
            isSeen: flags.contains("\\seen"),
            hasAttachments: headers.contentType.type == "multipart/mixed",
            preview: MIMEMessage.preview(headers: headers, partialBody: partialBody)
        )
    }
}

/// One page of a mailbox, newest first.
public struct SummaryPage: Equatable, Sendable {
    public var messages: [MessageSummary]
    public var hasMore: Bool

    public init(messages: [MessageSummary], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }
}

/// A message with its body.
public struct FullMessage: Identifiable, Hashable, Sendable {
    public let summary: MessageSummary
    public let html: String
    public let attachments: [Attachment]
    /// Every earlier message id in the conversation, for threading a reply.
    public let references: [String]

    public var id: MessageSummary.ID { summary.id }

    public init(summary: MessageSummary, html: String, attachments: [Attachment] = [], references: [String] = []) {
        self.summary = summary
        self.html = html
        self.attachments = attachments
        self.references = references
    }
}

/// Messages that belong together, oldest first: HEY's "thread".
public struct Conversation: Identifiable, Hashable, Sendable {
    public let id: String
    public let messages: [MessageSummary]

    public var latest: MessageSummary { messages[messages.count - 1] }
    public var subject: String { messages[0].subject }
    public var isSeen: Bool { messages.allSatisfy(\.isSeen) }
    public var hasAttachments: Bool { messages.contains(where: \.hasAttachments) }
    public var messageIDs: [MessageSummary.ID] { messages.map(\.id) }

    /// Everyone who wrote in the conversation, most recent first, without repeats.
    public var senders: [EmailAddress] {
        var seen = Set<String>()
        return messages.reversed().compactMap(\.from).filter { seen.insert($0.key).inserted }
    }

    /// Groups messages by the conversation they belong to, newest conversation first.
    public static func group(_ messages: [MessageSummary]) -> [Conversation] {
        let byRoot = Dictionary(grouping: messages, by: \.threadRoot)
        return byRoot.map { root, members in
            Conversation(id: root, messages: members.sorted { Self.isOlder($0, than: $1) })
        }
        .sorted { Self.isOlder($1.latest, than: $0.latest) }
    }

    /// Arrival order: by date when both have one, by position in the mailbox otherwise.
    private static func isOlder(_ a: MessageSummary, than b: MessageSummary) -> Bool {
        if let first = a.date, let second = b.date, first != second { return first < second }
        return a.id.uid < b.id.uid
    }
}
