import Foundation

/// A list of conversations the sidebar can show.
public enum Listing: Hashable, Sendable {
    /// Mebox, The Feed or Paper Trail: the inbox messages whose sender is routed there.
    case box(Destination)
    /// Inbox messages from senders nobody has decided about yet.
    case screener
    /// Inbox messages from senders who were told no.
    case screenedOut
    /// Reply Later or Set Aside: a folder this app keeps on the server.
    case appFolder(MailboxDirectory.AppFolder)
    /// Any other server mailbox, by path: Sent, Trash, a label, a folder.
    case mailbox(path: String)
}

/// What the window's three columns are showing: the list chosen in the sidebar, a
/// search laid over it, and the conversations picked in the list.
public struct NavigationFeature: Feature {
    /// The previous-visit watermark captured when opening Paper Trail or The Feed.
    /// Held steady for the whole visit so the "New Since You Last Visited" divider
    /// never jumps while the person is reading.
    public enum VisitCutoff: Equatable, Sendable {
        case pending
        case captured(Date?)
    }

    public struct State: Equatable, Sendable {
        public fileprivate(set) var listing: Listing = .box(.mebox)
        /// The search on screen. It covers `listing` until it is dismissed.
        public fileprivate(set) var search: String?
        public fileprivate(set) var selection: Set<Conversation.ID> = []
        /// Conversations opened since the list came on screen. Mebox keeps them
        /// under "New for You" until you leave, so a row does not jump away from
        /// under the pointer the moment it is read.
        public fileprivate(set) var readThisVisit: Set<Conversation.ID> = []
        /// The previous-visit timestamp captured when this listing opened.
        public fileprivate(set) var visitCutoff: VisitCutoff = .pending

        public init() {}
    }

    public enum Event: Sendable {
        case listingChosen(Listing)
        case searched(String)
        case searchDismissed
        case selectionChanged(Set<Conversation.ID>)
        /// A conversation was opened and so marked seen.
        case conversationRead(Conversation.ID)
        /// The previous visit timestamp for the current box was read. Ignored once
        /// already captured for this visit.
        case visitCutoffCaptured(Date?)
        /// Something the person did took conversations out of the list on screen.
        /// Both lists are in the order shown.
        case conversationsLeft(listBefore: [Conversation.ID], listAfter: [Conversation.ID])
    }

    public typealias Effect = Never

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Never] {
        switch event {
        case .listingChosen(let listing):
            guard listing != state.listing || state.search != nil else { break }
            state = State()
            state.listing = listing

        case .searched(let text):
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return reduce(&state, .searchDismissed) }
            guard query != state.search else { break }
            state.search = query
            state.selection = []

        case .searchDismissed:
            guard state.search != nil else { break }
            state.search = nil
            state.selection = []

        case .selectionChanged(let selection):
            state.selection = selection

        case .conversationRead(let id):
            state.readThisVisit.insert(id)

        case .visitCutoffCaptured(let date):
            if state.visitCutoff == .pending {
                state.visitCutoff = .captured(date)
            }

        case .conversationsLeft(let before, let after):
            let remaining = Set(after)
            let stillSelected = state.selection.intersection(remaining)
            guard stillSelected != state.selection else { break }
            if !stillSelected.isEmpty {
                state.selection = stillSelected
            } else {
                state.selection = Self.neighbour(ofSelection: state.selection, in: before, remaining: remaining).map { [$0] } ?? []
            }
        }
        return []
    }

    /// The row that takes over when every selected row has gone: the first survivor
    /// below the selection, or failing that the nearest one above it.
    private static func neighbour(
        ofSelection selection: Set<Conversation.ID>,
        in list: [Conversation.ID],
        remaining: Set<Conversation.ID>
    ) -> Conversation.ID? {
        guard let last = list.lastIndex(where: selection.contains) else { return nil }
        return list[last...].first(where: remaining.contains) ?? list[..<last].last(where: remaining.contains)
    }
}

/// Mebox's parts: active Bubbled Up mail at the very top, then what is new, then what
/// has already been seen.
public struct MeboxSections: Equatable, Sendable {
    public let bubbledUp: [Conversation]
    public let new: [Conversation]
    public let seen: [Conversation]

    /// - Parameters:
    ///   - readThisVisit: conversations to keep under "new" although read.
    ///   - bubbledUp: conversations currently bubbled up to the top of Mebox.
    public init(
        _ conversations: [Conversation],
        readThisVisit: Set<Conversation.ID>,
        bubbledUp: [Conversation] = []
    ) {
        self.bubbledUp = bubbledUp
        let bubbledIDs = Set(bubbledUp.map(\.id))
        let rest = conversations.filter { !bubbledIDs.contains($0.id) }
        new = rest.filter { !$0.isSeen || readThisVisit.contains($0.id) }
        seen = rest.filter { $0.isSeen && !readThisVisit.contains($0.id) }
    }

    /// Every conversation, in the order the sections are shown.
    public var all: [Conversation] { bubbledUp + new + seen }
}

/// Paper Trail and The Feed's two parts: what arrived after the previous visit, and
/// what was already there then.
public struct VisitedBoxSections: Equatable, Sendable {
    public let new: [Conversation]
    public let earlier: [Conversation]

    /// - Parameter lastVisited: when the box was last visited before this visit.
    ///   Nil on the first visit ever, when nothing is separated as new yet.
    public init(_ conversations: [Conversation], lastVisited: Date?) {
        guard let cutoff = lastVisited?.toTheSecond else {
            new = []
            earlier = conversations
            return
        }
        new = conversations.filter { Self.arrival(of: $0).map { $0.toTheSecond > cutoff } ?? false }
        earlier = conversations.filter { Self.arrival(of: $0).map { $0.toTheSecond <= cutoff } ?? true }
    }

    /// Every conversation, in the order the two parts are shown.
    public var all: [Conversation] { new + earlier }

    /// When a conversation's newest mail arrived on the server (falling back to the
    /// Date header when a server did not supply `INTERNALDATE`).
    public static func arrival(of conversation: Conversation) -> Date? {
        conversation.latest.received ?? conversation.latest.date
    }

    /// The watermark to record for a visit: at least `now`, and at least the newest
    /// arrival already on screen so slight clock skew never marks it new again.
    public static func watermark(for conversations: [Conversation], now: Date) -> Date {
        let newest = conversations.compactMap(arrival(of:)).max()
        return newest.map { max(now, $0) } ?? now
    }
}

/// How a conversation's time is written in a list, the way Mail does: the clock time
/// today, the weekday for the past week, then the date.
public enum ThreadTimestamp {
    public static func text(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        let startOfToday = calendar.startOfDay(for: now)
        if date < startOfToday, let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return date.formatted(style.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style.month(.abbreviated).day())
        }
        return date.formatted(style.year().month(.abbreviated).day())
    }
}
