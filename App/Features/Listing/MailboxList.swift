import HeydayKit
import SwiftUI

/// The middle column for one of the sidebar's lists: its conversations, or the
/// senders waiting in the Screener, with loading, failure and empty states.
struct MailboxList: View {
    let listing: Listing
    let workspace: Workspace

    private var store: Store<MailboxFeature> { workspace.mailbox(workspace.mailboxPath(for: listing)) }
    private var presentation: ListingPresentation { ListingPresentation(listing, directory: workspace.directory) }

    /// Lists drawn from the inbox need the Screener's decisions before they can sort it.
    private var isWaitingForRules: Bool {
        switch listing {
        case .box, .screener, .screenedOut: workspace.rules.state.rules == nil
        case .appFolder, .mailbox: false
        }
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
            } else {
                ConversationList(
                    sections: sections,
                    workspace: workspace,
                    showsRecipient: workspace.mailboxPath(for: listing) == workspace.directory.path(for: .sent)
                ) {
                    pagingRow(loaded, older)
                }
                .refreshable { await workspace.refresh(listing) }
            }
        }
    }

    private var sections: [ConversationSection] {
        guard listing == .box(.mebox) else {
            return [.init(title: nil, conversations: workspace.conversations(for: listing))]
        }
        let mebox = workspace.meboxSections
        return [
            .init(title: "New for You", conversations: mebox.new, emptyNote: "You’re all caught up."),
            .init(title: "Previously Seen", conversations: mebox.seen),
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
