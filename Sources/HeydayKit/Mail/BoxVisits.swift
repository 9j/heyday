import Foundation

/// When the person last visited each box whose mail is marked read on arrival
/// (Paper Trail and The Feed). Keeping the watermark lets Heyday draw a
/// "New Since You Last Visited" divider on the next visit without relying on
/// IMAP's `\Seen` flag. Kept on this Mac and synced across devices (`SyncedState`).
public struct BoxVisits: Codable, Equatable, Sendable {
    /// Keyed by `Destination.rawValue`. Stored to the second so a copy read back
    /// from disk or the account equals the one in memory.
    private var visitedAt: [String: Date] = [:]

    public init() {}

    public func lastVisited(_ destination: Destination) -> Date? {
        visitedAt[destination.rawValue]
    }

    /// Advances the visit watermark for `destination`. Never moves backward.
    public mutating func markVisited(_ destination: Destination, at time: Date) {
        let second = time.toTheSecond
        let key = destination.rawValue
        if let existing = visitedAt[key], second <= existing { return }
        visitedAt[key] = second
    }
}

extension BoxVisits: Mergeable {
    /// Each box's watermark is whichever device visited it most recently.
    public func merged(with other: BoxVisits) -> BoxVisits {
        var merged = self
        merged.visitedAt.merge(other.visitedAt) { ours, theirs in
            max(ours, theirs)
        }
        return merged
    }
}
