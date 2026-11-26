import HeydayKit
import SwiftUI

/// The toolbar over an open conversation. It acts on whatever is selected in the
/// list, so it also works on several conversations at once.
///
/// Its buttons stand in groups by what they do: answering, putting off, putting
/// away. On a Mac they are in the window's toolbar. On iPhone and iPad they run
/// along the bottom of the screen, where a thumb reaches them, with replying at the
/// end and forwarding under a long press of it.
struct ConversationToolbar: ToolbarContent {
    let workspace: Workspace
    let conversations: [Conversation]

    @Environment(\.compose) private var compose

    private var single: Conversation? { conversations.count == 1 ? conversations.first : nil }

    private static var placement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .bottomBar
        #endif
    }

    var body: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: Self.placement) {
            replyButton
            forwardButton
        }
        gap
        putOffGroup
        gap
        putAwayGroup
        gap
        moreMenu
        #else
        putAwayGroup
        gap
        putOffGroup
        gap
        moreMenu
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: Self.placement)
        } else {
            ToolbarItem(placement: Self.placement) { Spacer() }
        }
        ToolbarItem(placement: Self.placement) {
            Menu {
                replyButton
                forwardButton
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            } primaryAction: {
                reply()
            }
            .disabled(single == nil)
        }
        #endif
    }

    /// A little room between two groups, where the system draws each group as a
    /// piece of glass of its own.
    @ToolbarContentBuilder
    private var gap: some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: Self.placement)
        }
    }

    private var putOffGroup: some ToolbarContent {
        ToolbarItemGroup(placement: Self.placement) {
            Button("Reply Later", systemImage: "clock") {
                workspace.move(conversations, to: .appFolder(.replyLater))
            }
            .help("Reply Later (⌘L)")
            .disabled(!workspace.canMove(conversations, to: .appFolder(.replyLater)))

            Button("Set Aside", systemImage: "pin") {
                workspace.move(conversations, to: .appFolder(.setAside))
            }
            .help("Set Aside (⇧⌘S)")
            .disabled(!workspace.canMove(conversations, to: .appFolder(.setAside)))
        }
    }

    private var putAwayGroup: some ToolbarContent {
        ToolbarItemGroup(placement: Self.placement) {
            if workspace.path(for: .role(.archive)) != nil {
                Button("Archive", systemImage: "archivebox") {
                    workspace.move(conversations, to: .role(.archive))
                }
                .help("Archive (⌃⌘A)")
                .disabled(!workspace.canMove(conversations, to: .role(.archive)))
            }
            if workspace.path(for: .role(.trash)) != nil {
                Button("Trash", systemImage: "trash") {
                    workspace.move(conversations, to: .role(.trash))
                }
                .help("Move to Trash (⌘⌫)")
                .disabled(!workspace.canMove(conversations, to: .role(.trash)))
            }
        }
    }

    private var moreMenu: some ToolbarContent {
        ToolbarItem(placement: Self.placement) {
            Menu("More", systemImage: "ellipsis") {
                ConversationMenu(workspace: workspace, conversations: conversations)
            }
            .help("More actions")
            .disabled(conversations.isEmpty)
        }
    }

    private var replyButton: some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
            .help("Reply (⌘R)")
            .disabled(single == nil)
    }

    private var forwardButton: some View {
        Button("Forward", systemImage: "arrowshape.turn.up.right") {
            if let single { compose(.forward(single.latest.id)) }
        }
        .help("Forward (⇧⌘F)")
        .disabled(single == nil)
    }

    private func reply() {
        if let single { compose(.reply(to: single.latest.id)) }
    }
}
