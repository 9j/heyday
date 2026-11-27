import Foundation

/// The three places Heyday delivers mail you have agreed to receive.
public enum Destination: String, Codable, Hashable, Sendable, CaseIterable {
    /// Mail from people: the primary box.
    case mebox
    /// Newsletters and other casual reading.
    case feed
    /// Receipts and other transactional mail.
    case paperTrail

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "mebox", "meBox", "imbox": self = .mebox
        case "feed": self = .feed
        case "paperTrail": self = .paperTrail
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown destination: \(raw)")
        }
    }
}

/// What you decided about a sender in the Screener.
public enum SenderDecision: Codable, Hashable, Sendable {
    case approved(Destination)
    case screenedOut

    /// Whether giving a sender this answer keeps their mail read on the server,
    /// so it never adds to an unread count in Heyday or another mail client.
    public var marksMailRead: Bool {
        switch self {
        case .approved(.feed), .approved(.paperTrail), .screenedOut: true
        case .approved(.mebox): false
        }
    }
}

/// Where a message belongs, given who sent it.
public enum Placement: Hashable, Sendable {
    case box(Destination)
    /// Nobody has said yet whether this sender may email you.
    case screener
    case screenedOut

    /// Whether mail placed here is kept read on the server: The Feed, Paper Trail,
    /// and Screened Out never count as unread; Mebox and the Screener do.
    public var isKeptRead: Bool {
        switch self {
        case .box(.feed), .box(.paperTrail), .screenedOut: true
        case .box(.mebox), .screener: false
        }
    }
}

/// A sender waiting in the Screener, with what they have sent since it started.
public struct WaitingSender: Identifiable, Equatable, Sendable {
    public let sender: EmailAddress
    /// Their waiting mail as conversations, newest first. Never empty.
    public let conversations: [Conversation]

    public var id: String { sender.key }
    public var latest: Conversation { conversations[0] }
}

/// HEY's Screener: one decision per sender, applied to everything they send. IMAP
/// has no such idea, so nothing here moves mail on the server; it only decides which
/// of the app's boxes an inbox message is shown in. The decisions are kept on this
/// Mac and, so that every Mac shows the same, in the account itself (`SyncedState`).
public struct SenderRules: Codable, Equatable, Sendable {
    /// Keyed by lowercased address.
    public private(set) var decisions: [String: SenderDecision]
    /// When each decision was made, by the same key. Two Macs that decided
    /// differently about a sender go by the later decision. One made before times
    /// were kept has none, and counts as the oldest. A time with no decision is a
    /// decision taken back: the sender is undecided again, as of then.
    public private(set) var decidedAt: [String: Date]
    /// When the Screener started work on this account. Mail the server already had
    /// by then is let in without asking; only what arrives afterwards is screened.
    public private(set) var screeningSince: Date

    /// Times are kept to the second, which is how they are written down: a copy
    /// read back from a file or from the account then equals the one in memory.
    public init(screeningSince: Date, decisions: [String: SenderDecision] = [:], decidedAt: [String: Date] = [:]) {
        self.screeningSince = screeningSince.toTheSecond
        self.decisions = decisions
        self.decidedAt = decidedAt.mapValues(\.toTheSecond)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisions = try container.decode([String: SenderDecision].self, forKey: .decisions)
        decidedAt = try container.decodeIfPresent([String: Date].self, forKey: .decidedAt) ?? [:]
        screeningSince = try container.decode(Date.self, forKey: .screeningSince)
    }

    public func placement(for message: MessageSummary) -> Placement {
        // Mail with no usable From line cannot be screened by sender; let it through.
        guard let sender = message.from else { return .box(.mebox) }
        switch decisions[sender.key] {
        case .approved(let destination): return .box(destination)
        case .screenedOut: return .screenedOut
        case nil:
            // A server that does not say when a message arrived gets the benefit of the doubt.
            guard let received = message.received, received >= screeningSince else { return .box(.mebox) }
            return .screener
        }
    }

    public func decision(for sender: EmailAddress) -> SenderDecision? {
        decisions[sender.key]
    }

    public mutating func decide(_ decision: SenderDecision, for sender: EmailAddress, at time: Date) {
        decisions[sender.key] = decision
        stamp(sender, at: time)
    }

    /// Takes back the decision about a sender, who is then as nobody had answered.
    /// The moment is kept, so that on another Mac the taking back counts as the
    /// later word against the decision it undoes.
    public mutating func withdrawDecision(for sender: EmailAddress, at time: Date) {
        decisions[sender.key] = nil
        stamp(sender, at: time)
    }

    /// Notes when the latest word about a sender was said. Times are kept to the
    /// second, and two words in one second would be told apart by what they say
    /// rather than by which came last; so a word is never stamped at or before the
    /// one it follows here.
    private mutating func stamp(_ sender: EmailAddress, at time: Date) {
        let second = time.toTheSecond
        if let last = decidedAt[sender.key], second <= last {
            decidedAt[sender.key] = last.addingTimeInterval(1)
        } else {
            decidedAt[sender.key] = second
        }
    }

    /// The inbox messages that belong in one place, as conversations.
    public func conversations(in messages: [MessageSummary], placed placement: Placement) -> [Conversation] {
        Conversation.group(messages.filter { self.placement(for: $0) == placement })
    }

    /// Unread mail in boxes that are kept read on the server (The Feed, Paper Trail,
    /// and Screened Out), so every mail program sees them as read too.
    public func unreadKeptRead(in messages: [MessageSummary]) -> [MessageSummary.ID] {
        messages.filter { !$0.isSeen && placement(for: $0).isKeptRead }.map(\.id)
    }

    /// Everyone waiting in the Screener, the most recent to write first.
    public func waitingSenders(in messages: [MessageSummary]) -> [WaitingSender] {
        let waiting = messages.filter { placement(for: $0) == .screener }
        return Dictionary(grouping: waiting) { $0.from?.key ?? "" }
            .values
            .compactMap { theirs in
                theirs[0].from.map { WaitingSender(sender: $0, conversations: Conversation.group(theirs)) }
            }
            .sorted { $0.latest.latest.id.uid > $1.latest.latest.id.uid }
    }
}

extension SenderRules: Mergeable {
    /// Every sender either Mac has said something about, with the later word where
    /// they differ (an answer, or the taking back of one), and the earlier start of
    /// screening: the Mac the account was first added on set which mail was already
    /// there.
    public func merged(with other: SenderRules) -> SenderRules {
        var merged = self
        merged.screeningSince = min(screeningSince, other.screeningSince)
        for sender in Set(other.decisions.keys).union(other.decidedAt.keys) {
            let theirs = other.decisions[sender]
            let theirTime = other.decidedAt[sender] ?? .distantPast
            if decisions[sender] != nil || decidedAt[sender] != nil {
                let ourTime = decidedAt[sender] ?? .distantPast
                // Words said in the same second go by an order both Macs compute alike.
                guard theirTime > ourTime || (theirTime == ourTime && Self.rank(theirs) > Self.rank(decisions[sender])) else { continue }
            }
            merged.decisions[sender] = theirs
            merged.decidedAt[sender] = other.decidedAt[sender]
        }
        return merged
    }

    private static func rank(_ decision: SenderDecision?) -> Int {
        switch decision {
        case nil: -1
        case .approved(let destination): Destination.allCases.firstIndex(of: destination) ?? 0
        case .screenedOut: Destination.allCases.count
        }
    }
}

/// A value two Macs can each change and still agree on: merging in either order,
/// any number of times, gives the same result.
public protocol Mergeable {
    func merged(with other: Self) -> Self
}

public struct StorageError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Keeps one `Codable` value in a JSON file, written atomically. Dates are written
/// as ISO 8601, to the second.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The stored value, or nil if nothing has been saved yet.
    public func load() throws(StorageError) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw StorageError("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func save(_ value: Value) throws(StorageError) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw StorageError("Could not save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func delete() throws(StorageError) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw StorageError("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
