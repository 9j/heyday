import Foundation

/// What the person asked to be told about. As in HEY, mail arrives quietly: nothing
/// is announced unless it comes from a sender, or belongs to a conversation, that
/// notifications were turned on for. Kept on this Mac and, so that every device
/// agrees, in the account itself (`SyncedState`).
public struct NotificationRules: Codable, Equatable, Sendable {
    /// One switch and when it was last thrown. A switch that was turned off again is
    /// kept, so that another device that still has it on follows.
    private struct Switch: Codable, Equatable, Sendable {
        var isOn: Bool
        var changedAt: Date
    }

    /// Keyed by lowercased address.
    private var senders: [String: Switch] = [:]
    /// Keyed by the id of the message that started the conversation.
    private var conversations: [String: Switch] = [:]

    public init() {}

    public func notifies(about sender: EmailAddress) -> Bool {
        senders[sender.key]?.isOn ?? false
    }

    public func notifies(aboutConversation id: Conversation.ID) -> Bool {
        conversations[id]?.isOn ?? false
    }

    /// Whether an unread conversation is one to announce: notifications are on for
    /// it, or for whoever wrote something in it that has not been read.
    public func announces(_ conversation: Conversation) -> Bool {
        if notifies(aboutConversation: conversation.id) { return true }
        return conversation.messages.contains { message in
            !message.isSeen && (message.from.map(notifies(about:)) ?? false)
        }
    }

    /// The senders notifications are on for, by address, in alphabetical order.
    public var notifyingSenders: [String] {
        senders.filter(\.value.isOn).keys.sorted()
    }

    /// How many conversations notifications are on for.
    public var notifyingConversationCount: Int {
        conversations.count { $0.value.isOn }
    }

    public mutating func setNotifying(_ isOn: Bool, about sender: EmailAddress, at time: Date) {
        senders[sender.key] = Switch(isOn: isOn, changedAt: time.toTheSecond)
    }

    public mutating func setNotifying(_ isOn: Bool, aboutConversation id: Conversation.ID, at time: Date) {
        conversations[id] = Switch(isOn: isOn, changedAt: time.toTheSecond)
    }

    /// Turns notifications off for every conversation they are on for.
    public mutating func silenceConversations(at time: Date) {
        for id in conversations.filter(\.value.isOn).keys {
            conversations[id] = Switch(isOn: false, changedAt: time.toTheSecond)
        }
    }
}

extension NotificationRules: Mergeable {
    /// Each switch as whichever device threw it last left it.
    public func merged(with other: NotificationRules) -> NotificationRules {
        var merged = self
        merged.senders = Self.merge(senders, other.senders)
        merged.conversations = Self.merge(conversations, other.conversations)
        return merged
    }

    private static func merge(_ ours: [String: Switch], _ theirs: [String: Switch]) -> [String: Switch] {
        ours.merging(theirs) { mine, other in
            // Thrown in the same second: on wins, on both devices alike.
            if other.changedAt != mine.changedAt { return other.changedAt > mine.changedAt ? other : mine }
            return mine.isOn ? mine : other
        }
    }
}
