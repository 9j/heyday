import HeydayKit
import SwiftUI

/// The connected window, laid out the way Mac mail apps are: the lists in a sidebar,
/// the chosen list's conversations beside it, and the open conversation on the right.
struct MainView: View {
    let workspace: Workspace

    @State private var searchText = ""
    @State private var undoEntries = UndoEntries()
    @FocusState private var isSearchFocused: Bool
    @Environment(\.compose) private var compose
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.undoManager) private var undoManager

    private var navigation: Store<NavigationFeature> { workspace.navigation }

    /// The Feed fills the whole window beside the sidebar while browsing its cards,
    /// and restores the 3-column split when opening a full thread or leaving The Feed.
    private var isFeedStream: Bool {
        navigation.state.search == nil
            && navigation.state.listing == .box(.feed)
            && navigation.state.selection.isEmpty
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            ConversationColumn(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: isFeedStream ? nil : 520)
                .collapsesMacDetailColumn(isFeedStream)
                .toolbar { composeToolbar }
        } detail: {
            DetailColumn(workspace: workspace)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search All Mail")
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) {
            navigation.send(.searched(searchText))
        }
        .onChange(of: searchText) {
            // Emptying the field is how a search is left.
            if searchText.isEmpty { navigation.send(.searchDismissed) }
        }
        .onChange(of: navigation.state.search) { _, search in
            if search == nil { searchText = "" }
        }
        .focusedSceneValue(\.mailWindow, MailWindow(
            workspace: workspace,
            selection: workspace.selectedConversations,
            compose: compose,
            focusSearch: { isSearchFocused = true }
        ))
        .overlay(alignment: .bottom) {
            RecentActionToast(workspace: workspace) { notice, action in
                // Taken back here, it is no longer the Edit menu's to take back.
                undoEntries.withdraw(notice, from: undoManager)
                workspace.recentAction.send(.undoRequested(action))
            }
            .padding(.bottom, toastClearance)
        }
        // What can be taken back from the notice can be taken back with Undo too,
        // and for longer: the Edit menu keeps it after the notice has gone.
        .onChange(of: workspace.recentAction.state.notice) { _, notice in
            guard let notice, case .done(let action) = notice.kind, action.canBeTakenBack else { return }
            let recentAction = workspace.recentAction
            undoEntries.register(notice, named: workspace.presentation(of: action).undoName, with: undoManager) {
                recentAction.send(.undoRequested(action))
            }
        }
        .onDisappear {
            undoEntries.withdrawAll(from: undoManager)
        }
        .announcesNewMail(unseen: workspace.unseenMeboxConversations?.count, toAnnounce: workspace.unseenToAnnounce)
        .alert(
            "Heyday Couldn’t Store Your Choices",
            isPresented: Binding(get: { workspace.storageProblem != nil }, set: { if !$0 { workspace.dismissStorageProblem() } }),
            presenting: workspace.storageProblem
        ) { _ in
            Button("OK") {}
        } message: { problem in
            Text(problem)
        }
        // Coming back to the app is when another device's changes are wanted.
        .onReceive(NotificationCenter.default.publisher(for: .appBecameActive)) { _ in
            workspace.cameToTheFront()
        }
        .sheet(item: Binding(
            get: { workspace.appFolders.state.choice },
            set: { choice in
                // Dismissed some other way than its buttons: leave the mail where it is.
                if choice == nil, let open = workspace.appFolders.state.choice {
                    workspace.appFolders.send(.choiceCancelled(open.folder))
                }
            }
        )) { choice in
            FolderChoiceSheet(choice: choice, workspace: workspace)
        }
    }
}

extension MainView {
    /// Where a new email is started. On a phone that is at the bottom of the list,
    /// beside the search field, where the system's own Mail has it and a thumb
    /// reaches; elsewhere, at the top of the list's column.
    @ToolbarContentBuilder
    fileprivate var composeToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) { composeButton }
        #else
        if #available(iOS 26.0, *), widthClass == .compact {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { composeButton }
        } else {
            ToolbarItem(placement: .primaryAction) { composeButton }
        }
        #endif
    }

    /// How far above the window's bottom edge the notice floats: on a phone, clear
    /// of the bar of buttons that floats there too.
    fileprivate var toastClearance: CGFloat {
        #if os(macOS)
        18
        #else
        widthClass == .compact ? 62 : 18
        #endif
    }

    private var composeButton: some View {
        Button("New Message", systemImage: "square.and.pencil") {
            compose(.newMessage)
        }
        .help("Write a new email (⌘N)")
    }
}

/// The middle column: search results while a search is on, the sidebar's list otherwise.
private struct ConversationColumn: View {
    let workspace: Workspace

    var body: some View {
        if let query = workspace.navigation.state.search {
            SearchResultsList(query: query, workspace: workspace)
        } else {
            MailboxList(listing: workspace.navigation.state.listing, workspace: workspace)
                // A different list is a different screen, with its own scroll position.
                .id(workspace.navigation.state.listing)
        }
    }
}

/// The right-hand column: the selected conversation, or what to say when there is
/// not exactly one.
private struct DetailColumn: View {
    let workspace: Workspace

    @Environment(\.horizontalSizeClass) private var widthClass

    private var isScreening: Bool {
        workspace.navigation.state.search == nil && workspace.navigation.state.listing == .screener
    }

    private var isFeed: Bool {
        workspace.navigation.state.search == nil && workspace.navigation.state.listing == .box(.feed)
    }

    var body: some View {
        let selected = workspace.selectedConversations
        let isCollapsedFeed = isFeed && selected.isEmpty
        Group {
            if selected.count > 1 {
                ContentUnavailableView("\(selected.count) Conversations Selected", systemImage: "square.stack")
            } else if let conversation = selected.first {
                // Mail still in the Screener stays unread, so it arrives as new if
                // its sender is let in.
                ThreadView(conversation: conversation, workspace: workspace, marksSeen: !isScreening)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if isScreening, let sender = conversation.latest.from {
                            ScreenerBanner(sender: sender) { workspace.decide($0, for: sender) }
                        }
                    }
                    .id(ThreadRef(conversation))
            } else if isFeed, showsFeedInDetail {
                FeedView(workspace: workspace) {}
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "envelope.open")
            }
        }
        .toolbar {
            #if os(macOS)
            if isFeed && !selected.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Button("Back to The Feed", systemImage: "chevron.left") {
                        workspace.navigation.send(.selectionChanged([]))
                    }
                    .help("Back to The Feed")
                }
            }
            if !isCollapsedFeed {
                ConversationToolbar(workspace: workspace, conversations: selected)
            }
            #else
            if !(isFeed && selected.isEmpty) {
                ConversationToolbar(workspace: workspace, conversations: selected)
            }
            #endif
        }
    }

    private var showsFeedInDetail: Bool {
        #if os(macOS)
        false
        #else
        widthClass == .regular
        #endif
    }
}
