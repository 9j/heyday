import HeydayKit
import SwiftUI

/// Starts a draft. On a Mac each draft is a window of its own; on iPhone and iPad it
/// is a sheet over what is on screen.
struct ComposeAction {
    fileprivate let start: (ComposeIntent) -> Void

    func callAsFunction(_ intent: ComposeIntent) {
        start(intent)
    }
}

/// Shows the app's settings: the Settings window on a Mac, a sheet elsewhere.
struct ShowSettingsAction {
    fileprivate let show: () -> Void

    func callAsFunction() {
        show()
    }
}

extension EnvironmentValues {
    /// Does nothing outside a view that `presentsDraftsAndSettings`.
    @Entry var compose = ComposeAction { _ in }
    @Entry var showSettings = ShowSettingsAction {}
}

extension View {
    /// Gives the views inside the two actions above, each done the way the platform does it.
    func presentsDraftsAndSettings(services: AppServices) -> some View {
        modifier(DraftAndSettingsPresenter(services: services))
    }
}

#if os(macOS)
private struct DraftAndSettingsPresenter: ViewModifier {
    let services: AppServices

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .environment(\.compose, ComposeAction { openWindow(value: ComposeRequest($0, accountID: services.activeAccountID)) })
            .environment(\.showSettings, ShowSettingsAction { openSettings() })
    }
}
#else
private struct DraftAndSettingsPresenter: ViewModifier {
    let services: AppServices

    @State private var draft: ComposeRequest?
    @State private var showsSettings = false

    func body(content: Content) -> some View {
        content
            .environment(\.compose, ComposeAction { draft = ComposeRequest($0, accountID: services.activeAccountID) })
            .environment(\.showSettings, ShowSettingsAction { showsSettings = true })
            .sheet(item: $draft) { request in
                NavigationStack {
                    ComposeWindow(request: request, services: services)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView(services: services)
            }
    }
}
#endif
