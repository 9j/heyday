import HeydayKit
import SwiftUI

/// The main window's content: switches cleanly between any configured account,
/// full-window onboarding when none exist, and a modal Add Account sheet.
struct RootView: View {
    let services: AppServices

    private var activeSlot: AccountSlot? { services.activeSlot }

    var body: some View {
        Group {
            if !services.hasRestored {
                WaitingIndicator()
            } else if let slot = activeSlot {
                activeSlotView(slot)
            } else if let onboarding = services.onboardingSession {
                AccountSetupFlowView(store: onboarding, services: services, showsCancel: false)
            } else {
                WaitingIndicator()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motion(Motion.layout, value: stage)
        .task {
            services.restoreIfNeeded()
        }
        // Coming back to the app refreshes and syncs every connected account.
        .onReceive(NotificationCenter.default.publisher(for: .appBecameActive)) { _ in
            services.cameToTheFront()
        }
        .announcesNewMail(
            unseen: services.totalUnseenMeboxCount,
            byAccount: services.unseenToAnnounceByAccount,
            accountEmails: Dictionary(uniqueKeysWithValues: services.slots.map { ($0.id, $0.account.sender.address) })
        )
        .sheet(isPresented: Binding(
            get: { services.addingSession != nil },
            set: { if !$0 { services.dismissAddingAccount() } }
        )) {
            if let adding = services.addingSession {
                AddAccountSheet(store: adding, services: services)
            }
        }
    }

    @ViewBuilder
    private func activeSlotView(_ slot: AccountSlot) -> some View {
        switch slot.session.state {
        case .restoring:
            statusScreen(slot: slot) {
                WaitingIndicator(label: "Opening \(slot.account.sender.address)…")
            }
        case .settingUp(let setup, let problem):
            AccountSetupView(
                setup: setup,
                problem: problem,
                onChange: { slot.session.send(.setupChanged($0)) },
                onAutoconfig: { domain in slot.session.send(.autoconfigRequested(domain: domain)) },
                onConnect: { slot.session.send(.connectRequested) }
            )
        case .authorizing(let account, _):
            statusScreen(slot: slot) {
                VStack(spacing: 14) {
                    WaitingIndicator(label: Self.authorizingLabel(for: account))
                    Button("Cancel") {
                        services.cancelOAuthSignIn(for: slot.session)
                    }
                    .controlSize(.regular)
                }
            }
        case .connecting(let account, _):
            statusScreen(slot: slot) {
                WaitingIndicator(label: "Connecting to \(account.imap.host)…")
            }
        case .unavailable(let account, let error):
            statusScreen(slot: slot) {
                ContentUnavailableView {
                    Label("Can’t Connect", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error.userMessage)
                    Text("\(account.sender.address) on \(account.imap.host):\(String(account.imap.port))")
                } actions: {
                    if account.authMethod.isOAuth2, error.kind == .loginRefused {
                        Button("Sign In Again") { slot.session.send(.reauthorizeRequested) }
                            .buttonStyle(.borderedProminent)
                        Button("Try Again") { slot.session.send(.retryRequested) }
                    } else {
                        Button("Try Again") { slot.session.send(.retryRequested) }
                            .buttonStyle(.borderedProminent)
                        if account.authMethod.isOAuth2 {
                            Button("Sign In Again") { slot.session.send(.reauthorizeRequested) }
                        }
                    }
                    Button(services.slots.count > 1 ? "Remove Account" : "Use a Different Account", role: .destructive) {
                        services.removeAccount(slot.id)
                    }
                }
            }
        case .ready:
            if let workspace = slot.workspace {
                MainView(workspace: workspace, services: services)
                    .id(slot.id)
                    .transition(.opacity)
            } else {
                WaitingIndicator()
            }
        }
    }

    /// Keeps a quick account switcher accessible when one of several accounts is
    /// offline, connecting, or awaiting re-authentication.
    @ViewBuilder
    private func statusScreen<Content: View>(slot: AccountSlot, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topTrailing) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if services.slots.count > 1 {
                Menu {
                    ForEach(services.slots) { candidate in
                        Button {
                            services.selectAccount(candidate.id)
                        } label: {
                            HStack {
                                Text(candidate.account.sender.address)
                                if candidate.id == slot.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Add Account…", systemImage: "plus") {
                        services.beginAddingAccount()
                    }
                } label: {
                    Label(slot.account.sender.address, systemImage: "person.crop.circle")
                        .font(.subheadline)
                }
                .padding(16)
            }
        }
        .transition(.opacity)
    }

    static func authorizingLabel(for account: MailAccount) -> String {
        let providerName = account.authMethod.oauthConfig?.provider.displayName ?? "your provider"
        return "Finish signing in to \(providerName) in your browser…"
    }

    private var stage: String {
        guard services.hasRestored else { return "restoring" }
        guard let slot = activeSlot else { return "onboarding" }
        let phase = switch slot.session.state {
        case .restoring: "restoring"
        case .settingUp: "setup"
        case .authorizing: "authorizing"
        case .connecting: "connecting"
        case .unavailable: "unavailable"
        case .ready: slot.workspace == nil ? "opening" : "ready"
        }
        return "\(slot.id):\(phase)"
    }
}

/// Modal sheet for adding a second (or subsequent) account without disturbing the active one.
private struct AddAccountSheet: View {
    let store: Store<AccountFeature>
    let services: AppServices

    var body: some View {
        NavigationStack {
            AccountSetupFlowView(store: store, services: services, showsCancel: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            services.dismissAddingAccount()
                        }
                    }
                }
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 580, minHeight: 540, idealHeight: 620)
        #endif
    }
}

/// Drives a standalone `AccountFeature` store (first-run onboarding or Add Account sheet)
/// and promotes the newly verified account into `AppServices` once ready.
private struct AccountSetupFlowView: View {
    let store: Store<AccountFeature>
    let services: AppServices
    let showsCancel: Bool

    var body: some View {
        Group {
            switch store.state {
            case .restoring:
                WaitingIndicator()
            case .settingUp(let setup, let problem):
                AccountSetupView(
                    setup: setup,
                    problem: problem,
                    onChange: { store.send(.setupChanged($0)) },
                    onAutoconfig: { domain in store.send(.autoconfigRequested(domain: domain)) },
                    onConnect: { store.send(.connectRequested) }
                )
            case .authorizing(let account, _):
                VStack(spacing: 14) {
                    WaitingIndicator(label: RootView.authorizingLabel(for: account))
                    Button("Cancel") {
                        services.cancelOAuthSignIn(for: store)
                    }
                    .controlSize(.regular)
                }
            case .connecting(let account, _):
                WaitingIndicator(label: "Connecting to \(account.imap.host)…")
            case .unavailable(_, let error):
                ContentUnavailableView("Can’t Connect", systemImage: "wifi.exclamationmark", description: Text(error.userMessage))
            case .ready(let account, let directory):
                WaitingIndicator(label: "Opening \(account.sender.address)…")
                    .task(id: account.id) {
                        await services.promoteDraftAccount(account, directory: directory)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
