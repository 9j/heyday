import HeydayKit
import os
import SwiftUI
import UserNotifications

extension View {
    /// Keeps the app's badge at the total unread Mebox conversations across all
    /// connected accounts, and posts a notification for each newly arrived
    /// conversation the person asked to be told about.
    func announcesNewMail(
        unseen: Int?,
        byAccount: [MailAccount.ID: [Conversation]],
        accountEmails: [MailAccount.ID: String]
    ) -> some View {
        modifier(NewMailAnnouncer(unseen: unseen, byAccount: byAccount, accountEmails: accountEmails))
    }
}

/// The app's dealings with the system's notifications.
enum NewMail {
    /// Asks the system for leave to notify. The system asks the person the first
    /// time and remembers the answer; declining is a choice, not an error.
    @discardableResult
    static func askToNotify() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true
    }
}

private struct NewMailAnnouncer: ViewModifier {
    let unseen: Int?
    let byAccount: [MailAccount.ID: [Conversation]]
    let accountEmails: [MailAccount.ID: String]

    /// Conversations already known per account, so mail already present at launch
    /// is never announced as new.
    @State private var knownIDsByAccount: [MailAccount.ID: Set<String>] = [:]

    func body(content: Content) -> some View {
        content
            .onChange(of: unseen, initial: true) {
                if let unseen { Self.showBadge(unseen) }
            }
            .onChange(of: byAccount, initial: true) {
                let showsAccountLabel = accountEmails.count > 1
                // Drop tracking for removed accounts.
                knownIDsByAccount = knownIDsByAccount.filter { byAccount[$0.key] != nil }
                for (accountID, conversations) in byAccount {
                    if let known = knownIDsByAccount[accountID] {
                        let arrivals = conversations.filter { !known.contains($0.id) }
                        if !arrivals.isEmpty {
                            let label = showsAccountLabel ? accountEmails[accountID] : nil
                            Self.notify(about: arrivals, accountID: accountID, accountEmail: label)
                        }
                    }
                    knownIDsByAccount[accountID] = Set(conversations.map(\.id))
                }
            }
    }

    /// The count on the Dock icon, or on the Home Screen icon where the person
    /// allows notifications to put one there.
    private static func showBadge(_ count: Int) {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        #else
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
        #endif
    }

    /// Says when something was announced, and whether the system let it through.
    /// Never says what or from whom.
    private static let log = Logger(subsystem: "app.heyday.mac", category: "notifications")

    private static func notify(about arrivals: [Conversation], accountID: MailAccount.ID, accountEmail: String?) {
        guard !arrivals.isEmpty else { return }
        Task {
            guard await NewMail.askToNotify() else {
                log.info("\(arrivals.count, privacy: .public) to announce, but notifications are not allowed for Heyday")
                return
            }
            log.info("Announcing \(arrivals.count, privacy: .public)")
            for conversation in arrivals {
                let content = UNMutableNotificationContent()
                content.title = conversation.latest.from?.displayName ?? "New email"
                if let accountEmail {
                    content.subtitle = "\(conversation.subject) — \(accountEmail)"
                } else {
                    content.subtitle = conversation.subject
                }
                content.body = conversation.latest.preview
                content.sound = .default
                let identifier = "\(accountID)|\(conversation.id)"
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            }
        }
    }
}
