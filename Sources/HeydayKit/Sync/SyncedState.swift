import Foundation

/// What an account looks like in this app beyond what a mail server keeps: the
/// Screener's decisions, where Reply Later and Set Aside live, what to notify
/// about, and when Paper Trail and The Feed were last visited. Every device signed
/// in to the account reads and writes one copy of it, kept in the account itself.
public struct SyncedState: Codable, Equatable, Sendable {
    /// Each part is nil on a device that has not loaded its own yet, and in a copy
    /// written by a version of the app that did not have it.
    public var rules: SenderRules?
    public var folders: FolderAssignments?
    public var notifications: NotificationRules?
    public var visits: BoxVisits?
    public var bubbleUps: BubbleUpRules?

    public init(
        rules: SenderRules?,
        folders: FolderAssignments?,
        notifications: NotificationRules? = nil,
        visits: BoxVisits? = nil,
        bubbleUps: BubbleUpRules? = nil
    ) {
        self.rules = rules
        self.folders = folders
        self.notifications = notifications
        self.visits = visits
        self.bubbleUps = bubbleUps
    }
}

extension SyncedState: Mergeable {
    public func merged(with other: SyncedState) -> SyncedState {
        SyncedState(
            rules: Self.merge(rules, other.rules),
            folders: Self.merge(folders, other.folders),
            notifications: Self.merge(notifications, other.notifications),
            visits: Self.merge(visits, other.visits),
            bubbleUps: Self.merge(bubbleUps, other.bubbleUps)
        )
    }

    private static func merge<Value: Mergeable>(_ ours: Value?, _ theirs: Value?) -> Value? {
        guard let ours else { return theirs }
        return theirs.map(ours.merged) ?? ours
    }
}

extension Date {
    /// The same moment without its fraction of a second. Times that are compared
    /// between Macs are kept this way, since that is how they are written down.
    var toTheSecond: Date {
        Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down))
    }
}
