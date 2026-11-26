import HeydayKit
import SwiftUI

/// The sidebar: HEY's boxes first, then the account's own mailboxes and folders,
/// under the names the server gives them.
struct SidebarView: View {
    let workspace: Workspace

    #if !os(macOS)
    @Environment(\.showSettings) private var showSettings
    /// The row shown as chosen. Not simply the list on show: on a phone this
    /// screen is left for that list, and coming back clears the choice, which is
    /// what lets the same row be tapped again.
    @State private var chosen: Listing?

    init(workspace: Workspace) {
        self.workspace = workspace
        _chosen = State(initialValue: workspace.navigation.state.listing)
    }
    #endif

    /// The standard mailboxes worth a row, in the order Mail lists them.
    private static let standardRoles: [Mailbox.Role] = [.sent, .drafts, .archive, .spam, .trash, .all]

    var body: some View {
        List(selection: selection) {
            Section {
                row(.box(.mebox))
                row(.box(.feed))
                row(.box(.paperTrail))
            }
            Section("Screener") {
                row(.screener)
                row(.screenedOut)
            }
            Section("For Later") {
                row(.appFolder(.replyLater))
                row(.appFolder(.setAside))
            }
            let groups = workspace.userFolderGroups
            // The standard mailboxes, then whatever else sits beside them on the server.
            let topLevel = standardMailboxes + groups.filter { $0.title == nil }.flatMap(\.mailboxes)
            if !topLevel.isEmpty {
                Section("Mailboxes") {
                    ForEach(topLevel) { serverRow($0) }
                }
            }
            ForEach(groups.filter { $0.title != nil }) { group in
                Section(group.title ?? "") {
                    ForEach(group.mailboxes) { serverRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        #if !os(macOS)
        .navigationTitle("Heyday")
        // A list chosen some other way (a keyboard shortcut) is the chosen row too.
        .onChange(of: workspace.navigation.state.listing) { _, listing in
            chosen = listing
        }
        // A Mac has Settings in the app menu. Here it needs a button.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showSettings() }
            }
        }
        #endif
        // Reply Later and Set Aside show how much is waiting in them, which means
        // reading them before either is opened, and again if one is moved elsewhere.
        // One that was never used has no mailbox yet, and nothing to read.
        .task(id: settledFolderPaths) {
            for path in settledFolderPaths {
                workspace.mailbox(path).send(.refreshRequested)
            }
        }
    }

    private func row(_ listing: Listing) -> some View {
        let presentation = ListingPresentation(listing, directory: workspace.directory)
        return Label {
            Text(presentation.title)
        } icon: {
            Image(systemName: presentation.symbol)
                .foregroundStyle(.tint)
        }
        .badge(workspace.badge(for: listing))
        .tag(listing)
    }

    /// A mailbox as the server has it. Two can share a name (a folder and a label,
    /// say), so the tooltip gives the full path.
    private func serverRow(_ mailbox: Mailbox) -> some View {
        row(.mailbox(path: mailbox.path))
            .help(mailbox.displayPath)
    }

    private var settledFolderPaths: [String] {
        MailboxDirectory.AppFolder.allCases.filter(workspace.isSetUp).map(workspace.folderPath)
    }

    private var standardMailboxes: [Mailbox] {
        Self.standardRoles.compactMap { role in
            workspace.directory.mailboxes.first { $0.role == role && $0.isSelectable }
        }
    }

    #if os(macOS)
    /// Nothing in the sidebar is selected while a search covers the list.
    private var selection: Binding<Listing?> {
        Binding(
            get: { workspace.navigation.state.search == nil ? workspace.navigation.state.listing : nil },
            set: { listing in
                if let listing { workspace.navigation.send(.listingChosen(listing)) }
            }
        )
    }
    #else
    private var selection: Binding<Listing?> {
        Binding(
            get: { chosen },
            set: { listing in
                chosen = listing
                if let listing { workspace.navigation.send(.listingChosen(listing)) }
            }
        )
    }
    #endif
}
