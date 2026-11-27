import HeydayKit
import SwiftUI

/// A run of conversations in a list. A list with one untitled section is a plain list.
struct ConversationSection: Identifiable {
    enum Header: Equatable {
        case title(String)
        case newSinceLastVisited
    }

    let header: Header?
    let conversations: [Conversation]
    /// Shown in place of the section when it has no conversations. Without one, an
    /// empty section is left out unless `showsHeaderWhenEmpty` is true.
    var emptyNote: String?
    /// Keeps a divider header visible even when no older conversations follow it.
    var showsHeaderWhenEmpty = false

    init(
        title: String? = nil,
        header: Header? = nil,
        conversations: [Conversation],
        emptyNote: String? = nil,
        showsHeaderWhenEmpty: Bool = false
    ) {
        self.header = header ?? title.map(Header.title)
        self.conversations = conversations
        self.emptyNote = emptyNote
        self.showsHeaderWhenEmpty = showsHeaderWhenEmpty
    }

    var id: String {
        switch header {
        case .title(let text): "title:\(text)"
        case .newSinceLastVisited: "newSinceLastVisited"
        case nil: ""
        }
    }
}

/// A selectable list of conversations. A row can be acted on without opening it:
/// by swiping it, from its menu, with the Delete key, and on a Mac from the buttons
/// that appear under the pointer.
struct ConversationList<Footer: View>: View {
    let sections: [ConversationSection]
    let workspace: Workspace
    /// In Sent the interesting party is who it went to, not who wrote it.
    var showsRecipient = false
    /// Quiet boxes (Paper Trail, Screened Out) are kept read automatically and omit
    /// the unread dot and bold unread styling.
    var showsUnreadIndicator = true
    @ViewBuilder var footer: Footer

    var body: some View {
        let rowIDs = sections.map { $0.conversations.map(\.id) }
        List(selection: workspace.listSelection) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let followedByDivider = sections.indices.contains(index + 1) && sections[index + 1].header == .newSinceLastVisited
                if section.conversations.isEmpty {
                    if let note = section.emptyNote {
                        EmptySectionNote(text: note)
                    } else if section.showsHeaderWhenEmpty, let header = section.header {
                        sectionHeader(header)
                    }
                } else {
                    if let header = section.header {
                        sectionHeader(header)
                    }
                    rows(section.conversations, hidesLastBottomSeparator: followedByDivider)
                }
            }
            footer
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        // A title or a note is a line of text, and takes a line's height.
        .environment(\.defaultMinListRowHeight, 1)
        #endif
        // Rows that come, go or change section travel to where they belong.
        .motion(Motion.layout, value: rowIDs)
        .keepsMacListRowHeights(when: rowIDs)
        .conversationActions(workspace: workspace)
    }

    @ViewBuilder
    private func sectionHeader(_ header: ConversationSection.Header) -> some View {
        switch header {
        case .title(let text):
            SectionTitle(text: text)
        case .newSinceLastVisited:
            NewSinceLastVisitedDivider()
                #if !os(macOS)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                #endif
                .listRowSeparator(.hidden)
                .selectionDisabled()
        }
    }

    private func rows(_ conversations: [Conversation], hidesLastBottomSeparator: Bool) -> some View {
        let lastID = hidesLastBottomSeparator ? conversations.last?.id : nil
        return ForEach(conversations) { conversation in
            ConversationRow(
                conversation: conversation,
                showsRecipient: showsRecipient,
                showsUnreadIndicator: showsUnreadIndicator,
                quickActions: QuickAction.all(for: conversation, in: workspace)
            )
            .listRowSeparator(conversation.id == lastID ? .hidden : .automatic, edges: .bottom)
            .swipeActions(edge: .trailing) {
                if workspace.canMove([conversation], to: .role(.archive)) {
                    Button("Archive", systemImage: "archivebox") { workspace.move([conversation], to: .role(.archive)) }
                        .tint(.purple)
                }
                if workspace.canMove([conversation], to: .role(.trash)) {
                    Button("Trash", systemImage: "trash") { workspace.move([conversation], to: .role(.trash)) }
                        .tint(.red)
                }
            }
            .swipeActions(edge: .leading) {
                Button(conversation.isSeen ? "Unseen" : "Seen", systemImage: conversation.isSeen ? "envelope.badge" : "envelope.open") {
                    workspace.setSeen(!conversation.isSeen, [conversation])
                }
                .tint(.blue)
                if workspace.canMove([conversation], to: .appFolder(.replyLater)) {
                    Button("Reply Later", systemImage: "clock") { workspace.move([conversation], to: .appFolder(.replyLater)) }
                        .tint(.orange)
                }
                if workspace.canMove([conversation], to: .appFolder(.setAside)) {
                    Button("Set Aside", systemImage: "pin") { workspace.move([conversation], to: .appFolder(.setAside)) }
                        .tint(.teal)
                }
            }
        }
    }
}

/// The name of a run of rows, as a row of its own above them. Not a section header:
/// those stand off from the rows around them by more than a list of mail wants.
private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            #if !os(macOS)
            // Close over the rows it names, where a row's own margins would set it adrift.
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            #endif
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityAddTraits(.isHeader)
    }
}

/// Marks the boundary between what arrived since the previous visit and what was
/// already in Paper Trail or The Feed then.
struct NewSinceLastVisitedDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            SquiggleWave()
                .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 48, height: 6)
                .accessibilityHidden(true)
            Text("NEW SINCE YOU LAST VISITED")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color.accentColor.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SquiggleWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let waves = 3.5
        let steps = 40
        let midY = rect.midY
        let amplitude = rect.height * 0.42
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let x = rect.minX + rect.width * progress
            let y = midY + sin(progress * waves * 2 * .pi) * amplitude
            if step == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

/// One quiet line where a section's rows would be: Mebox with nothing new.
private struct EmptySectionNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .accessibilityHidden(true)
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }
}

extension Workspace {
    #if os(macOS)
    /// The middle column's selection, for a `List` to read and write. A Mac list
    /// takes several rows at once, with Shift and Command.
    var listSelection: Binding<Set<Conversation.ID>> {
        Binding(
            get: { self.navigation.state.selection },
            set: { self.navigation.send(.selectionChanged($0)) }
        )
    }
    #else
    /// The middle column's selection, for a `List` to read and write. On iPhone
    /// and iPad a tap opens one conversation: a list there only takes several rows
    /// in its editing mode, and would open nothing on a tap.
    var listSelection: Binding<Conversation.ID?> {
        Binding(
            get: { self.navigation.state.selection.first },
            set: { self.navigation.send(.selectionChanged($0.map { [$0] } ?? [])) }
        )
    }
    #endif
}

extension View {
    /// What every list of conversations lets you do to its rows without opening them.
    func conversationActions(workspace: Workspace) -> some View {
        contextMenu(forSelectionType: Conversation.ID.self) { ids in
            ConversationMenu(workspace: workspace, conversations: workspace.visibleConversations.filter { ids.contains($0.id) })
        }
        #if os(macOS)
        .onDeleteCommand {
            workspace.move(workspace.selectedConversations, to: .role(.trash))
        }
        #endif
    }
}

/// Something a row offers under the pointer, on a Mac.
struct QuickAction: Identifiable {
    let title: String
    let symbol: String
    let perform: () -> Void

    var id: String { title }

    /// The actions for one conversation, most used first. Empty off the Mac, where
    /// there is no pointer to bring them out and a swipe does the same.
    @MainActor
    static func all(for conversation: Conversation, in workspace: Workspace) -> [QuickAction] {
        #if os(macOS)
        var actions: [QuickAction] = []
        if workspace.canMove([conversation], to: .role(.archive)) {
            actions.append(.init(title: "Archive", symbol: "archivebox") { workspace.move([conversation], to: .role(.archive)) })
        }
        if workspace.canMove([conversation], to: .role(.trash)) {
            actions.append(.init(title: "Move to Trash", symbol: "trash") { workspace.move([conversation], to: .role(.trash)) })
        }
        if workspace.canMove([conversation], to: .appFolder(.replyLater)) {
            actions.append(.init(title: "Reply Later", symbol: "clock") { workspace.move([conversation], to: .appFolder(.replyLater)) })
        }
        let isSeen = conversation.isSeen
        actions.append(.init(title: isSeen ? "Mark as Unseen" : "Mark as Seen", symbol: isSeen ? "envelope.badge" : "envelope.open") {
            workspace.setSeen(!isSeen, [conversation])
        })
        return actions
        #else
        []
        #endif
    }
}

/// One conversation in a list: who, when, about what, and how it starts. Unread, it
/// carries a dot and its sender and subject are heavier.
struct ConversationRow: View {
    let conversation: Conversation
    var showsRecipient = false
    var showsUnreadIndicator = true
    var quickActions: [QuickAction] = []

    @State private var isUnderPointer = false
    @ScaledMetric(relativeTo: .body) private var avatarSize = Self.avatarBaseSize

    private static var avatarBaseSize: CGFloat {
        #if os(macOS)
        32
        #else
        40
        #endif
    }

    private var isUnread: Bool { showsUnreadIndicator && !conversation.isSeen }
    private var showsQuickActions: Bool { isUnderPointer && !quickActions.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsUnreadIndicator {
                Circle()
                    .fill(.tint)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isUnread ? 1 : 0.4)
                    .opacity(isUnread ? 1 : 0)
                    .frame(height: avatarSize)
                    .accessibilityHidden(true)
            }
            AvatarView(address: correspondent, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(who)
                        .font(.headline)
                        .fontWeight(isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if conversation.messages.count > 1 {
                        Text(String(conversation.messages.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                            .contentTransition(.numericText())
                            .accessibilityLabel("\(conversation.messages.count) messages")
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        if conversation.hasAttachments {
                            Image(systemName: "paperclip")
                                .font(.caption)
                                .accessibilityLabel("Has attachments")
                        }
                        if let date = conversation.latest.date {
                            Text(ThreadTimestamp.text(for: date, now: .now, calendar: .current, locale: .current))
                                .font(.subheadline)
                        }
                    }
                    .foregroundStyle(.secondary)
                    // The quick actions take this corner while the pointer is on the row.
                    .opacity(showsQuickActions ? 0 : 1)
                }
                Text(conversation.subject.isEmpty ? "(No Subject)" : conversation.subject)
                    .font(.subheadline)
                    .fontWeight(isUnread ? .medium : .regular)
                    .lineLimit(1)
                Text(conversation.latest.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // The line between rows starts under the words, not under the picture.
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }
        }
        .padding(.vertical, 4)
        .motion(Motion.response, value: isUnread)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "Unread" : "")
        .overlay(alignment: .topTrailing) {
            if showsQuickActions {
                QuickActionBar(actions: quickActions)
                    .offset(y: -2)
                    .transition(.opacity)
            }
        }
        .onHover { isUnderPointer = $0 }
        .motion(Motion.response, value: showsQuickActions)
    }

    private var correspondent: EmailAddress? {
        showsRecipient ? conversation.latest.to.first : conversation.latest.from
    }

    /// Everyone who wrote, most recent first; in Sent, who the latest went to.
    private var who: String {
        if showsRecipient {
            return "To: " + (correspondent?.displayName ?? "")
        }
        let names = conversation.senders.map(\.displayName)
        return names.isEmpty ? "Unknown Sender" : names.joined(separator: ", ")
    }
}

/// A row's quick actions, as a strip of symbols floating over its corner.
private struct QuickActionBar: View {
    let actions: [QuickAction]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions) { action in
                Button(action.title, systemImage: action.symbol, action: action.perform)
                    .help(action.title)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .floatingSurface(in: Capsule())
    }
}

/// Rows of grey where a list's conversations will be, while they are fetched.
struct ConversationListPlaceholder: View {
    private static let nameWidths: [CGFloat] = [120, 150, 96, 136]
    private static let subjectWidths: [CGFloat] = [220, 170, 250, 190]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 8) {
                        PlaceholderBar(width: Self.nameWidths[index % Self.nameWidths.count], height: 11)
                        PlaceholderBar(width: Self.subjectWidths[index % Self.subjectWidths.count])
                        PlaceholderBar()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
        .shimmering()
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}
