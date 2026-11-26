import Foundation

extension MessageSummary {
    /// Whether this is a message the app keeps its own data in, not mail. Such a
    /// message turns up wherever the server lists everything (All Mail, a search)
    /// and is left out of what the reader is shown.
    public var isAppData: Bool {
        messageID?.hasSuffix(MailDocumentStoreMarker.messageIDSuffix) ?? false
    }
}

/// How the app's own messages are told from mail.
enum MailDocumentStoreMarker {
    /// The end of their Message-IDs. `.invalid` is reserved: no real mail comes from it.
    static let messageIDSuffix = "@sync.heyday.invalid>"
}

/// Keeps a value in a mail account, so every Mac signed in to it reads the same one.
///
/// A mail server has no place for a client's settings, but it keeps messages and
/// gives them back unchanged. So the value travels as the JSON attachment of a
/// message, in a mailbox of the app's own. A message cannot be edited: saving adds
/// a new one and removes the earlier ones. Two Macs saving at the same moment can
/// each leave one behind, which is why loading reads every copy there and merges them.
///
/// Removing a message from a folder does not always remove it from the account:
/// Proton and Gmail keep it under All Mail. An earlier copy is therefore moved to
/// the trash and removed from there, which every server treats as gone for good.
public struct MailDocumentStore<Value: Codable & Mergeable & Sendable>: Sendable {
    /// The newest shape of the stored document this app reads and writes.
    private static var formatVersion: Int { 1 }
    /// More copies than this are never left behind; reading them all stays cheap.
    private static var listingLimit: Int { 50 }

    private struct Document: Codable {
        let version: Int
        let value: Value
    }

    private struct DocumentVersion: Decodable {
        let version: Int
    }

    private let service: any MailService
    /// The mailbox the messages are kept in. Made on the first save.
    public let mailbox: String
    private let name: String
    private let owner: EmailAddress
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    /// - Parameters:
    ///   - name: says which value this is, in the message's subject, its id and its
    ///     attachment. Letters only.
    ///   - owner: the account's own address, which the message is from and to.
    public init(
        service: any MailService,
        mailbox: String,
        name: String,
        owner: EmailAddress,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.service = service
        self.mailbox = mailbox
        self.name = name
        self.owner = owner
        self.now = now
        self.uuid = uuid
    }

    /// What the account holds: every copy there, merged. Nil when nothing readable
    /// has been saved.
    /// - Throws: also when a copy was written by a newer version of the app, so that
    ///   an older one does not go on to replace what it cannot read.
    public func load() async throws(MailError) -> Value? {
        let copies = try await copies()
        guard !copies.isEmpty else { return nil }

        var merged: Value?
        for message in try await service.messages(copies.map(\.id)) {
            guard let data = message.attachments.first(where: { $0.filename == attachmentName })?.data else { continue }
            if let written = try? Self.decoder.decode(DocumentVersion.self, from: data), written.version > Self.formatVersion {
                throw MailError(.garbled, "What Heyday keeps in this account was written by a newer version of Heyday. Update Heyday on this Mac.")
            }
            // A copy that cannot be read is passed over, and replaced by the next save.
            guard let document = try? Self.decoder.decode(Document.self, from: data) else { continue }
            merged = merged.map { $0.merged(with: document.value) } ?? document.value
        }
        return merged
    }

    /// Puts the value in the account in place of every copy there.
    public func save(_ value: Value) async throws(MailError) {
        let exists = try await mailboxExists()
        if !exists { try await service.createMailbox(mailbox) }
        let earlier = exists ? try await listedCopies() : []
        try await service.append(try message(holding: value), to: mailbox)
        try await remove(earlier)
    }

    // MARK: The copies in the mailbox

    private func copies() async throws(MailError) -> [MessageSummary] {
        try await mailboxExists() ? try await listedCopies() : []
    }

    private func listedCopies() async throws(MailError) -> [MessageSummary] {
        try await listedCopies(in: mailbox)
    }

    /// This value's copies among the newest messages of a mailbox.
    private func listedCopies(in mailbox: String) async throws(MailError) -> [MessageSummary] {
        try await service.summaries(in: mailbox, olderThan: nil, limit: Self.listingLimit).messages.filter { message in
            message.isAppData && (message.messageID?.hasPrefix("<\(name).") ?? false)
        }
    }

    /// Removes copies from the account for good.
    private func remove(_ copies: [MessageSummary]) async throws(MailError) {
        guard !copies.isEmpty else { return }
        guard let trash = try await service.directory().path(for: .trash), trash != mailbox else {
            // No trash to go through: removing them from their mailbox is all there is.
            try await service.delete(copies.map(\.id))
            return
        }
        try await service.move(copies.map(\.id), to: trash)
        // A moved message is numbered afresh, so the copies are found again in the
        // trash by what they are. That takes along any an earlier removal left there.
        try await service.delete(try await listedCopies(in: trash).map(\.id))
    }

    private func mailboxExists() async throws(MailError) -> Bool {
        try await service.directory().mailboxes.contains { $0.path == mailbox }
    }

    // MARK: The message

    private var attachmentName: String { "heyday-\(name).json" }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func message(holding value: Value) throws(MailError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json: Data
        do {
            json = try encoder.encode(Document(version: Self.formatVersion, value: value))
        } catch {
            throw MailError(.garbled, error.localizedDescription)
        }

        let id = uuid().uuidString.lowercased()
        let boundary = "heyday-\(id)"
        let explanation = """
        This message is how Heyday keeps what you have told it about this account: who the Screener lets in, and where \
        Reply Later and Set Aside are kept. Heyday on each of your Macs reads it, so they all show the same, and replaces \
        it when something changes.\r
        \r
        Deleting it does no harm. Each Mac keeps its own copy and writes this message again.
        """
        let lines = [
            "From: \(owner.address)",
            "To: \(owner.address)",
            "Subject: Heyday data (\(name))",
            "Date: \(MailDate.format(now()))",
            "Message-ID: <\(name).\(id)\(MailDocumentStoreMarker.messageIDSuffix)",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 7bit",
            "",
            explanation,
            "--\(boundary)",
            "Content-Type: application/json; name=\"\(attachmentName)\"",
            "Content-Disposition: attachment; filename=\"\(attachmentName)\"",
            "Content-Transfer-Encoding: base64",
            "",
            TransferEncoding.encodeBase64(json),
            "--\(boundary)--",
            "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
