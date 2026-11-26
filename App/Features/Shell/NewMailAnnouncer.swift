import HeydayKit
import os
import SwiftUI
import UserNotifications

extension View {
    /// Keeps the app's badge at the number of unread Mebox conversations, and posts
    /// a notification for each conversation the person asked to be told about that
    /// turns up unread while the app is running.
    /// - Parameters:
    ///   - unseen: how many Mebox conversations are unread. Nil before that is known.
    ///   - toAnnounce: the unread conversations notifications are on for. Nil
    ///     before that is known.
    func announcesNewMail(unseen: Int?, toAnnounce: [Conversation]?) -> some View {
        modifier(NewMailAnnouncer(unseen: unseen, toAnnounce: toAnnounce))
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
    let toAnnounce: [Conversation]?

    /// What was waiting to be announced the last time it was looked at. Nil before
    /// the first look, so mail that was already there at launch is not announced
    /// as new.
    @State private var knownIDs: Set<String>?

    func body(content: Content) -> some View {
        content
            .onChange(of: unseen, initial: true) {
                if let unseen { Self.showBadge(unseen) }
            }
            .onChange(of: toAnnounce, initial: true) {
                guard let toAnnounce else { return }
                if let knownIDs {
                    Self.notify(about: toAnnounce.filter { !knownIDs.contains($0.id) })
                }
                knownIDs = Set(toAnnounce.map(\.id))
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

    private static func notify(about arrivals: [Conversation]) {
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
                content.subtitle = conversation.subject
                content.body = conversation.latest.preview
                content.sound = .default
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: conversation.id, content: content, trigger: nil))
            }
        }
    }
}
