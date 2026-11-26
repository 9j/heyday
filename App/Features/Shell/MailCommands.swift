import HeydayKit
import SwiftUI

/// What the menu bar can act on: the mail window in front and what is selected in it.
struct MailWindow {
    let workspace: Workspace
    let selection: [Conversation]
    let compose: ComposeAction
    let focusSearch: () -> Void
}

/// The translation of the conversation open in the window in front.
struct ConversationTranslation {
    /// Whether any open message shows its translation.
    let isShown: Bool
    /// Translates the open messages, or shows them as written again.
    let toggle: () -> Void
}

extension FocusedValues {
    @Entry var mailWindow: MailWindow?
    @Entry var conversationTranslation: ConversationTranslation?
}

/// The app's own menus, with Mail's shortcuts where Mail has one.
struct MailCommands: Commands {
    @FocusedValue(\.mailWindow) private var window
    @FocusedValue(\.conversationTranslation) private var translation

    /// The lists reachable with ⌘1 to ⌘6.
    private static let numberedListings: [Listing] = [
        .box(.mebox), .box(.feed), .box(.paperTrail), .screener, .appFolder(.replyLater), .appFolder(.setAside),
    ]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { window?.compose(.newMessage) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(window == nil)
            Button("Get New Mail") {
                guard let workspace = window?.workspace else { return }
                Task { await workspace.refresh(workspace.navigation.state.listing) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(window == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Search Mail") { window?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(window == nil)
        }

        CommandMenu("Go") {
            ForEach(Array(Self.numberedListings.enumerated()), id: \.element) { index, listing in
                // These six are the app's own lists; none takes its name from a server folder.
                Button(ListingPresentation(listing, directory: MailboxDirectory(mailboxes: [])).title) {
                    window?.workspace.navigation.send(.listingChosen(listing))
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            .disabled(window == nil)
        }

        CommandMenu("Message") {
            let selection = window?.selection ?? []
            let single = selection.count == 1 ? selection.first : nil

            Button("Reply") {
                if let single { window?.compose(.reply(to: single.latest.id)) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(single == nil)

            Button("Forward") {
                if let single { window?.compose(.forward(single.latest.id)) }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(single == nil)

            Divider()

            Button(selection.allSatisfy(\.isSeen) ? "Mark as Unseen" : "Mark as Seen") {
                window?.workspace.setSeen(!selection.allSatisfy(\.isSeen), selection)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(selection.isEmpty)

            Button(translation?.isShown == true ? "Show Original" : "Translate") { translation?.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(translation == nil)

            Divider()

            Button("Reply Later") { window?.workspace.move(selection, to: .appFolder(.replyLater)) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(window?.workspace.canMove(selection, to: .appFolder(.replyLater)) != true)
            Button("Set Aside") { window?.workspace.move(selection, to: .appFolder(.setAside)) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(window?.workspace.canMove(selection, to: .appFolder(.setAside)) != true)
            Button("Archive") { window?.workspace.move(selection, to: .role(.archive)) }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(window?.workspace.canMove(selection, to: .role(.archive)) != true)
            Button("Move to Trash") { window?.workspace.move(selection, to: .role(.trash)) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(window?.workspace.canMove(selection, to: .role(.trash)) != true)

            Divider()

            Menu("Deliver Sender to") {
                if let window, let sender = single?.latest.from {
                    DeliveryChoices(sender: sender, workspace: window.workspace)
                }
            }
            .disabled(single?.latest.from == nil)

            if let window, let single {
                Divider()
                NotificationChoices(conversation: single, workspace: window.workspace)
            }
        }
    }
}
