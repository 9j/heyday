import HeydayKit
import SwiftUI

/// The sidebar: HEY's boxes first, then the account's own mailboxes and folders,
/// under the names the server gives them. When more than one account is connected,
/// an account switcher sits cleanly at the bottom.
struct SidebarView: View {
    let workspace: Workspace
    let services: AppServices

    #if !os(macOS)
    @Environment(\.showSettings) private var showSettings
    /// The row shown as chosen. Not simply the list on show: on a phone this
    /// screen is left for that list, and coming back clears the choice, which is
    /// what lets the same row be tapped again.
    @State private var chosen: Listing?

    init(workspace: Workspace, services: AppServices) {
        self.workspace = workspace
        self.services = services
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if services.slots.count > 1 {
                AccountSwitcherFooter(activeAccount: workspace.account, services: services)
            }
        }
        #if !os(macOS)
        .navigationTitle(services.slots.count > 1 ? workspace.account.sender.displayName : "Heyday")
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
        let itemTint: ListItemTint = if let color = HeydayTheme.sidebarTint(for: listing) {
            .fixed(color)
        } else {
            .monochrome
        }
        return Label(presentation.title, systemImage: presentation.symbol)
            .listItemTint(itemTint)
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

/// Compact account switcher pinned to the bottom of the sidebar when 2+ accounts
/// are configured. Uses a native SwiftUI button + popover so custom avatar and
/// badge layouts render cleanly inside macOS Liquid Glass sidebars.
private struct AccountSwitcherFooter: View {
    let activeAccount: MailAccount
    let services: AppServices

    @State private var isPresented = false
    @State private var isHovering = false

    private var otherAccountsUnread: Int {
        services.slots
            .filter { $0.id != activeAccount.id }
            .compactMap { $0.workspace?.unseenMeboxConversations?.count }
            .reduce(0, +)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                AvatarView(address: activeAccount.sender, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeAccount.sender.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !activeAccount.sender.name.isEmpty {
                        Text(activeAccount.sender.address)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if otherAccountsUnread > 0 {
                    Text(String(otherAccountsUnread))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HeydayTheme.rose, in: Capsule())
                        .help("\(otherAccountsUnread) unread in other accounts")
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering || isPresented ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityLabel("Switch account, currently \(activeAccount.sender.address)")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AccountSwitcherPopover(activeAccountID: activeAccount.id, services: services) {
                isPresented = false
            }
        }
    }
}

private struct AccountSwitcherPopover: View {
    let activeAccountID: MailAccount.ID
    let services: AppServices
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(services.slots) { slot in
                AccountSwitcherRow(
                    slot: slot,
                    isActive: slot.id == activeAccountID
                ) {
                    onClose()
                    services.selectAccount(slot.id)
                }
            }

            Divider()
                .padding(.vertical, 4)

            Button {
                onClose()
                services.beginAddingAccount()
            } label: {
                Label("Add Account…", systemImage: "plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        #if os(macOS)
        .frame(width: 260)
        #else
        .frame(minWidth: 260, idealWidth: 280, maxWidth: .infinity)
        #endif
    }
}

private struct AccountSwitcherRow: View {
    let slot: AccountSlot
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                AvatarView(address: slot.account.sender, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.account.sender.displayName)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(slot.account.sender.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                trailingBadge
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HeydayTheme.rose)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        switch slot.session.state {
        case .ready:
            let unread = slot.workspace?.unseenMeboxConversations?.count ?? 0
            if unread > 0 {
                Text(String(unread))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        case .connecting, .restoring, .authorizing:
            ProgressView()
                .controlSize(.small)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .settingUp:
            EmptyView()
        }
    }
}
