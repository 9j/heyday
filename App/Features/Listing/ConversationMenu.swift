import HeydayKit
import SwiftUI

/// Everything that can be done to the given conversations, as menu items. Used for
/// the right-click menu in a list and for the toolbar's More menu.
struct ConversationMenu: View {
    let workspace: Workspace
    let conversations: [Conversation]

    @Environment(\.compose) private var compose

    private var single: Conversation? { conversations.count == 1 ? conversations.first : nil }

    var body: some View {
        if let single {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(.reply(to: single.latest.id)) }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { compose(.forward(single.latest.id)) }
            Divider()
        }

        let allSeen = conversations.allSatisfy(\.isSeen)
        Button(allSeen ? "Mark as Unseen" : "Mark as Seen", systemImage: allSeen ? "envelope.badge" : "envelope.open") {
            workspace.setSeen(!allSeen, conversations)
        }

        Divider()

        Button("Reply Later", systemImage: "clock") { workspace.move(conversations, to: .appFolder(.replyLater)) }
            .disabled(!workspace.canMove(conversations, to: .appFolder(.replyLater)))
        Button("Set Aside", systemImage: "pin") { workspace.move(conversations, to: .appFolder(.setAside)) }
            .disabled(!workspace.canMove(conversations, to: .appFolder(.setAside)))
        Menu("Move to", systemImage: "folder") {
            Button("Inbox", systemImage: "tray") { workspace.move(conversations, to: .inbox) }
                .disabled(!workspace.canMove(conversations, to: .inbox))
            if workspace.path(for: .role(.archive)) != nil {
                Button("Archive", systemImage: "archivebox") { workspace.move(conversations, to: .role(.archive)) }
                    .disabled(!workspace.canMove(conversations, to: .role(.archive)))
            }
            if !workspace.userFolders.isEmpty {
                Divider()
                ForEach(workspace.userFolders) { folder in
                    // The full path: a folder and a label can share a name.
                    Button(folder.displayPath, systemImage: "folder") { workspace.move(conversations, to: .folder(path: folder.path)) }
                }
            }
        }

        if let sender = single?.latest.from {
            Divider()
            Menu("Deliver \(sender.displayName) to", systemImage: "tray.and.arrow.down") {
                DeliveryChoices(sender: sender, workspace: workspace)
            }
        }

        if let single {
            Divider()
            NotificationChoices(conversation: single, workspace: workspace)
        }

        Divider()

        if workspace.canMove(conversations, to: .role(.spam)) {
            Button("Mark as Spam", systemImage: "xmark.bin") { workspace.move(conversations, to: .role(.spam)) }
        }
        if workspace.canMove(conversations, to: .role(.trash)) {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { workspace.move(conversations, to: .role(.trash)) }
        }
    }
}

/// The Screener's four answers about one sender. They apply to everything the
/// sender has sent, old mail included.
struct DeliveryChoices: View {
    let sender: EmailAddress
    let workspace: Workspace

    var body: some View {
        Button("Mebox", systemImage: "tray.full") { workspace.decide(.approved(.mebox), for: sender) }
        Button("The Feed", systemImage: "newspaper") { workspace.decide(.approved(.feed), for: sender) }
        Button("Paper Trail", systemImage: "scroll") { workspace.decide(.approved(.paperTrail), for: sender) }
        Divider()
        Button("Screen Out", systemImage: "hand.thumbsdown") { workspace.decide(.screenedOut, for: sender) }
    }
}

/// Whether to be told about one conversation, and about everything its sender
/// writes. Mail is quiet unless one of these is on.
struct NotificationChoices: View {
    let conversation: Conversation
    let workspace: Workspace

    var body: some View {
        Toggle("Notify Me About This Conversation", isOn: Binding(
            get: { workspace.notifies(about: conversation) },
            set: { workspace.setNotifying($0, about: conversation) }
        ))
        if let sender = conversation.latest.from {
            Toggle("Notify Me When \(sender.displayName) Writes", isOn: Binding(
                get: { workspace.notifies(about: sender) },
                set: { workspace.setNotifying($0, about: sender) }
            ))
        }
    }
}
