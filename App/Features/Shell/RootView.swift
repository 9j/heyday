import HeydayKit
import SwiftUI

/// The main window's content, chosen by whether there is an account and whether its
/// server can be reached.
struct RootView: View {
    let services: AppServices

    private var session: Store<AccountFeature> { services.session }

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                WaitingIndicator()
            case .settingUp(let setup, let problem):
                AccountSetupView(
                    setup: setup,
                    problem: problem,
                    onChange: { session.send(.setupChanged($0)) },
                    onConnect: { session.send(.connectRequested) }
                )
            case .connecting(let account, _):
                WaitingIndicator(label: "Connecting to \(account.imap.host)…")
                    .transition(.opacity)
            case .unavailable(let account, let error):
                ContentUnavailableView {
                    Label("Can’t Connect", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error.userMessage)
                    Text("\(account.sender.address) on \(account.imap.host):\(String(account.imap.port))")
                } actions: {
                    Button("Try Again") { session.send(.retryRequested) }
                        .buttonStyle(.borderedProminent)
                    Button("Use a Different Account") { session.send(.signOutRequested) }
                }
                .transition(.opacity)
            case .ready(let account, let directory):
                if let workspace = services.activeWorkspace {
                    MainView(workspace: workspace)
                        .transition(.opacity)
                } else {
                    WaitingIndicator()
                        .task { await services.openWorkspace(for: account, directory: directory) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One stage gives way to the next without a hard cut.
        .motion(Motion.layout, value: stage)
        .task {
            session.send(.launched)
        }
        .onChange(of: isReady) {
            if !isReady { services.closeWorkspace() }
        }
    }

    private var isReady: Bool {
        if case .ready = session.state { true } else { false }
    }

    /// Which of the window's faces is showing, for the change between them to follow.
    private var stage: Int {
        switch session.state {
        case .restoring: 0
        case .settingUp: 1
        case .connecting: 2
        case .unavailable: 3
        case .ready: services.activeWorkspace == nil ? 4 : 5
        }
    }
}
