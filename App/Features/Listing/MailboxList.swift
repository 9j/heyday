import HeydayKit
import SwiftUI

/// The middle column for one of the sidebar's lists: its conversations, or the
/// senders waiting in the Screener, with loading, failure and empty states.
struct MailboxList: View {
    let listing: Listing
    let workspace: Workspace

    @Environment(\.horizontalSizeClass) private var widthClass

    private var store: Store<MailboxFeature> { workspace.mailbox(workspace.mailboxPath(for: listing)) }
    private var presentation: ListingPresentation { ListingPresentation(listing, directory: workspace.directory) }

    /// Lists drawn from the inbox need the Screener's decisions (and saved visit
    /// watermarks for Paper Trail and The Feed) before sorting it.
    private var isWaitingForRules: Bool {
        switch listing {
        case .box(.feed), .box(.paperTrail):
            workspace.rules.state.rules == nil || workspace.visits.state.visits == nil
        case .box(.mebox), .screener, .screenedOut:
            workspace.rules.state.rules == nil
        case .appFolder, .mailbox:
            false
        }
    }

    /// Whether this column itself renders the full newsfeed cards for The Feed.
    /// On macOS the detail column collapses to give this column the full width; on
    /// iPhone it is the sole column; on iPad regular width the detail column hosts
    /// the wide feed stream instead.
    private var showsFeedCardsHere: Bool {
        guard listing == .box(.feed) else { return false }
        #if os(macOS)
        return true
        #else
        return widthClass == .compact
        #endif
    }

    private var visitedDestination: Destination? {
        switch listing {
        case .box(.feed): .feed
        case .box(.paperTrail): .paperTrail
        default: nil
        }
    }

    /// Re-runs visit recording once saved visits, rules and inbox have loaded, and
    /// again if newer mail arrives while the box stays open.
    private var visitTrackingKey: VisitTrackingKey {
        let newestID = visitedDestination.flatMap { workspace.conversations(for: .box($0)).first?.latest.id }
        return VisitTrackingKey(
            destination: visitedDestination,
            isReady: visitedDestination != nil && !isWaitingForRules && isLoaded,
            newestMessageID: newestID
        )
    }

    private var isLoaded: Bool {
        if case .loaded = store.state.content { true } else { false }
    }

    var body: some View {
        content
            .navigationTitle(presentation.title)
            .subtitled(subtitle)
            .task {
                if workspace.hasMailbox(for: listing) {
                    store.send(.refreshRequested)
                }
            }
            .task(id: visitTrackingKey) {
                if let destination = visitTrackingKey.destination, visitTrackingKey.isReady {
                    workspace.noteVisited(destination)
                }
            }
            .alert(
                "The Mail Server Refused That",
                isPresented: Binding(get: { store.state.failedAction != nil }, set: { if !$0 { store.send(.failedActionDismissed) } }),
                presenting: store.state.failedAction
            ) { _ in
                Button("OK") {}
            } message: { failure in
                Text(failure.userMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state.content {
        case _ where !workspace.hasMailbox(for: listing):
            // Nothing has ever been put here, so there is no folder to read yet.
            ContentUnavailableView(presentation.emptyTitle, systemImage: presentation.symbol)
        case .loading:
            ConversationListPlaceholder()
        case .unavailable(let error):
            ContentUnavailableView {
                Label("Can’t Load This Mail", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            } actions: {
                Button("Try Again") { store.send(.refreshRequested) }
            }
        case .loaded where isWaitingForRules:
            ConversationListPlaceholder()
        case .loaded(let loaded):
            let older = olderMail(loaded)
            if workspace.conversations(for: listing).isEmpty, older != .onScroll {
                ContentUnavailableView {
                    Label(presentation.emptyTitle, systemImage: presentation.symbol)
                } actions: {
                    pagingRow(loaded, older)
                }
            } else if listing == .screener {
                ScreenerList(workspace: workspace) { pagingRow(loaded, older) }
                    .refreshable { await workspace.refresh(listing) }
            } else if showsFeedCardsHere {
                FeedView(workspace: workspace) { pagingRow(loaded, older) }
            } else {
                ConversationList(
                    sections: sections,
                    workspace: workspace,
                    showsRecipient: workspace.mailboxPath(for: listing) == workspace.directory.path(for: .sent),
                    showsUnreadIndicator: showsUnreadIndicator
                ) {
                    pagingRow(loaded, older)
                }
                .refreshable { await workspace.refresh(listing) }
            }
        }
    }

    private var showsUnreadIndicator: Bool {
        switch listing {
        case .box(.feed), .box(.paperTrail), .screenedOut: false
        case .box(.mebox), .screener, .appFolder, .mailbox: true
        }
    }

    private var sections: [ConversationSection] {
        switch listing {
        case .box(.mebox):
            let mebox = workspace.meboxSections
            return [
                .init(title: "New for You", conversations: mebox.new, emptyNote: "You’re all caught up."),
                .init(title: "Previously Seen", conversations: mebox.seen),
            ]
        case .box(.paperTrail):
            return visitedSections(for: .paperTrail)
        case .box(.feed):
            return visitedSections(for: .feed)
        default:
            return [.init(conversations: workspace.conversations(for: listing))]
        }
    }

    private func visitedSections(for destination: Destination) -> [ConversationSection] {
        let split = workspace.visitedBoxSections(for: destination)
        guard !split.new.isEmpty else {
            return [.init(conversations: split.earlier)]
        }
        return [
            .init(conversations: split.new),
            .init(header: .newSinceLastVisited, conversations: split.earlier, showsHeaderWhenEmpty: true),
        ]
    }

    private var subtitle: String {
        switch listing {
        case .box(.mebox):
            let unseen = workspace.badge(for: listing)
            return unseen == 0 ? "" : "\(unseen) unread"
        case .screener:
            let waiting = workspace.badge(for: listing)
            return waiting == 0 ? "" : "\(waiting) waiting"
        case .box, .screenedOut, .appFolder, .mailbox:
            return ""
        }
    }

    // MARK: Older mail

    /// How the rest of the mailbox, beyond what is loaded, is reached from this list.
    private enum OlderMail {
        case none
        /// Fetched when the end of the list scrolls into view.
        case onScroll
        /// Fetched when asked. For lists that pick a few senders out of the inbox:
        /// filling the screen on its own could mean reading the whole inbox.
        case onRequest
    }

    private func olderMail(_ loaded: MailboxFeature.Loaded) -> OlderMail {
        guard loaded.hasMore else { return .none }
        switch listing {
        case .box(.mebox), .appFolder, .mailbox:
            return .onScroll
        case .box(let destination):
            return hasSenders(placed: .approved(destination)) ? .onRequest : .none
        case .screenedOut:
            return hasSenders(placed: .screenedOut) ? .onRequest : .none
        case .screener:
            // Only mail that arrived after screening began can be waiting, so there
            // is nothing to find further back than that.
            guard let since = workspace.rules.state.rules?.screeningSince, let oldest = loaded.messages.last?.received else { return .none }
            return oldest >= since ? .onScroll : .none
        }
    }

    /// Whether any sender has been given this answer. With none, no amount of older
    /// mail could belong in the list.
    private func hasSenders(placed decision: SenderDecision) -> Bool {
        workspace.rules.state.rules?.decisions.values.contains(decision) ?? false
    }

    private func pagingRow(_ loaded: MailboxFeature.Loaded, _ older: OlderMail) -> PagingRow {
        PagingRow(paging: loaded.paging, loadsOnScroll: older == .onScroll, isShown: older != .none) {
            store.send(.moreRequested)
        }
    }
}

/// Identifies when a visited box (Paper Trail or The Feed) is ready to record its
/// visit watermark, and when a newer message arrives while it remains open.
private struct VisitTrackingKey: Equatable {
    let destination: Destination?
    let isReady: Bool
    let newestMessageID: MessageSummary.ID?
}

/// The last row of a list that has more on the server.
private struct PagingRow: View {
    let paging: MailboxFeature.Paging
    let loadsOnScroll: Bool
    let isShown: Bool
    let onLoad: () -> Void

    var body: some View {
        if isShown {
            Group {
                switch paging {
                case .idle where loadsOnScroll:
                    // Coming into view is the request for the next page.
                    ProgressView()
                        .controlSize(.small)
                        .onAppear(perform: onLoad)
                case .idle:
                    Button("Look in Older Mail", action: onLoad)
                        .linkStyled()
                case .loadingMore:
                    ProgressView()
                        .controlSize(.small)
                case .failed(let error):
                    VStack(spacing: 4) {
                        Text(error.userMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again", action: onLoad)
                            .linkStyled()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
        }
    }
}
