import HeydayKit
import SwiftUI

@main
struct HeydayApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        #if os(macOS)
        Window("Heyday", id: "main") {
            RootView(services: services)
                .frame(minWidth: 880, minHeight: 520)
                .presentsDraftsAndSettings(services: services)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            SidebarCommands()
            MailCommands()
        }

        WindowGroup("New Message", for: ComposeRequest.self) { $request in
            if let request {
                ComposeWindow(request: request, services: services)
            }
        }
        .defaultSize(width: 640, height: 560)
        // A draft lives only in its window; reopening an empty one at launch helps nobody.
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(services: services)
        }
        #else
        // One window: a draft and the settings are sheets over it.
        WindowGroup {
            RootView(services: services)
                .presentsDraftsAndSettings(services: services)
        }
        .commands {
            // For a keyboard attached to an iPad.
            MailCommands()
        }
        #endif
    }
}

/// One draft. Each request is its own, so two can be open at once on a Mac, and
/// remembers which account it was started from.
struct ComposeRequest: Hashable, Codable, Identifiable {
    var id = UUID()
    let intent: ComposeIntent
    let accountID: MailAccount.ID?

    init(_ intent: ComposeIntent, accountID: MailAccount.ID? = nil) {
        self.intent = intent
        self.accountID = accountID
    }
}
