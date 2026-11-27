import HeydayKit
import SwiftUI

/// An open conversation: its subject, then one card per email, oldest first.
///
/// The cards are on screen at once, drawn from what the list knew about each
/// email; the emails themselves fill in when they arrive. A long run of folded
/// emails ahead of the open one is shown as its first and last with a count
/// between them.
struct ThreadView: View {
    let conversation: Conversation
    let workspace: Workspace
    /// Whether opening the conversation counts as reading it.
    let marksSeen: Bool

    @State private var store: Store<ThreadFeature>?
    @State private var translations: Store<TranslationFeature>?
    @State private var problem: String?
    /// Whether every folded email ahead of the open one is shown, however many.
    @State private var showsEarlierMessages = false
    /// Whether the subject has scrolled out of sight.
    @State private var subjectIsOffScreen = false
    @Environment(\.compose) private var compose
    @Environment(\.horizontalSizeClass) private var widthClass

    private var subject: String {
        conversation.subject.isEmpty ? "(No Subject)" : conversation.subject
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                    .padding(.bottom, 2)
                content
            }
            .padding(widthClass == .compact ? 12 : 20)
            .padding(.bottom, showsActionDock ? 72 : 0)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            .motion(Motion.layout, value: expanded)
            .motion(Motion.layout, value: showsEarlierMessages)
            .motion(Motion.layout, value: loaded != nil)
        }
        .background(Color.windowBackground)
        .overlay(alignment: .bottom) {
            if showsActionDock {
                ThreadActionDock(conversation: conversation, workspace: workspace)
                    .padding(.bottom, 16)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 40
        } action: { _, isOffScreen in
            subjectIsOffScreen = isOffScreen
        }
        .toolbar {
            #if !os(macOS)
            // The subject goes up into the bar once it has scrolled away under it.
            ToolbarItem(placement: .principal) {
                Text(subject)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(subjectIsOffScreen ? 1 : 0)
                    .motion(Motion.response, value: subjectIsOffScreen)
                    .accessibilityHidden(!subjectIsOffScreen)
            }
            #endif
            ToolbarItem(placement: Self.translatePlacement) {
                Button(isTranslationShown ? "Show Original" : "Translate", systemImage: "translate", action: toggleTranslation)
                    .symbolEffect(.pulse, isActive: isTranslating)
                    // Coloured while a translation is on screen, as a switch that is on.
                    .tint(isTranslationShown ? Color.accentColor : nil)
                    .help(isTranslationShown ? "Show the messages as written (⇧⌘T)" : "Translate the open messages (⇧⌘T)")
                    .disabled(openMessages.isEmpty)
            }
        }
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            let store = workspace.makeThread(ThreadRef(conversation))
            self.store = store
            translations = workspace.makeTranslations()
            store.send(.opened)
            if marksSeen { workspace.read(conversation) }
        }
        .focusedSceneValue(\.conversationTranslation, openMessages.isEmpty ? nil : ConversationTranslation(
            isShown: isTranslationShown,
            toggle: toggleTranslation
        ))
        .alert("Couldn’t Open the Attachment", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var showsActionDock: Bool {
        guard marksSeen else { return false }
        #if os(macOS)
        return true
        #else
        return widthClass == .regular
        #endif
    }

    private static var translatePlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if conversation.messages.count > 1 {
                Text("\(conversation.messages.count) messages")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: What is on screen

    private var loaded: ThreadFeature.Loaded? {
        if case .loaded(let loaded) = store?.state.content { loaded } else { nil }
    }

    /// The conversation's emails, oldest first: as the list knew them until they
    /// are fetched, and then the ones that were.
    private var summaries: [MessageSummary] {
        guard let loaded else { return conversation.messages }
        let fetched = Set(loaded.messages.map(\.id))
        return conversation.messages.filter { fetched.contains($0.id) }
    }

    /// The expanded emails. Before they are fetched, the newest, as it will be after.
    private var expanded: Set<MessageSummary.ID> {
        loaded?.expanded ?? Set(conversation.messages.last.map { [$0.id] } ?? [])
    }

    /// One thing in the column of cards.
    private enum Entry: Identifiable {
        case message(MessageSummary)
        /// Stands in for this many folded emails.
        case earlier(count: Int)

        enum ID: Hashable {
            case message(MessageSummary.ID)
            case earlier
        }

        var id: ID {
            switch self {
            case .message(let summary): .message(summary.id)
            case .earlier: .earlier
            }
        }
    }

    /// More folded emails than this ahead of the open one are not all shown.
    private static let foldedRunLimit = 3

    private var entries: [Entry] {
        let all = summaries
        let foldedRun = all.prefix { !expanded.contains($0.id) }.count
        guard !showsEarlierMessages, foldedRun > Self.foldedRunLimit else { return all.map(Entry.message) }
        // The first and the last of the run stay: how it began, and what the open
        // email answers.
        let hidden = foldedRun - 2
        return [.message(all[0]), .earlier(count: hidden)] + all[(hidden + 1)...].map(Entry.message)
    }

    @ViewBuilder
    private var content: some View {
        if case .unavailable(let error) = store?.state.content {
            ContentUnavailableView {
                Label("Can’t Load This Conversation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            } actions: {
                Button("Try Again") { store?.send(.opened) }
            }
        } else {
            ForEach(entries) { entry in
                switch entry {
                case .message(let summary):
                    card(for: summary)
                        .transition(.opacity)
                case .earlier(let count):
                    EarlierMessagesButton(count: count) { showsEarlierMessages = true }
                        .transition(.opacity)
                }
            }
        }
    }

    private func card(for summary: MessageSummary) -> some View {
        let id = summary.id
        return MessageCard(
            summary: summary,
            message: loaded?.messages.first { $0.id == id },
            content: loaded?.bodies[id],
            images: loaded?.images(in: id) ?? [:],
            translation: translations?.state.messages[id],
            translationReplacesOriginal: workspace.translation.state.settings.display == .translationOnly,
            isShownAsSent: loaded?.shownAsSent.contains(id) ?? false,
            isExpanded: expanded.contains(id),
            canFold: loaded != nil && summaries.count > 1,
            actions: MessageCard.Actions(
                toggle: { store?.send(.messageToggled(id)) },
                showImage: { store?.send(.imageRequested(ImageRef(message: id, index: $0))) },
                showAllImages: { store?.send(.allImagesRequested(id)) },
                loadAsSent: { store?.send(.asSentRequested(id)) },
                protect: { store?.send(.protectionRequested(id)) },
                translate: { translations?.send(.requested(id)) },
                showOriginal: { translations?.send(.originalRequested(id)) },
                chooseLanguage: { code in
                    // The language chosen here is the one translations go into from now on.
                    workspace.translate(into: code)
                    translations?.send(.retranslationRequested(id))
                },
                paragraphs: { translations?.send(.paragraphsRead(id, $0)) },
                reply: { compose(.reply(to: id)) },
                forward: { compose(.forward(id)) },
                problem: { problem = $0 }
            )
        )
    }

    // MARK: Translation

    /// The messages whose bodies are on screen: what Translate acts on.
    private var openMessages: [MessageSummary.ID] {
        guard let loaded else { return [] }
        return loaded.messages.map(\.id).filter(loaded.expanded.contains)
    }

    private var isTranslationShown: Bool {
        openMessages.contains { translations?.state.messages[$0]?.isShown == true }
    }

    /// Whether a translation that is to be shown is still being made.
    private var isTranslating: Bool {
        openMessages.contains { id in
            guard let translation = translations?.state.messages[id], translation.isShown else { return false }
            return translation.phase == .reading || translation.phase == .translating
        }
    }

    private func toggleTranslation() {
        let showOriginal = isTranslationShown
        for id in openMessages {
            translations?.send(showOriginal ? .originalRequested(id) : .requested(id))
        }
    }
}

/// Stands in a column of emails for the folded ones not shown, and shows them when
/// pressed: a count on a line, where they would be.
private struct EarlierMessagesButton: View {
    let count: Int
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 10) {
                line
                Label(String(count), systemImage: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                line
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Show \(count) more messages")
        .help("Show \(count) more messages")
    }

    private var line: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
    }
}

/// Floating action pill at the bottom of an open conversation: Reply, Reply Later,
/// Set Aside, Bubble Up, and More — matching HEY's signature reading dock.
private struct ThreadActionDock: View {
    let conversation: Conversation
    let workspace: Workspace

    @State private var showsBubbleUp = false
    @Environment(\.compose) private var compose

    private var activeBubbleUp: BubbleUp? { workspace.bubbleUp(for: conversation) }
    private var isInSetAside: Bool {
        workspace.isSetUp(.setAside)
            && conversation.messageIDs.allSatisfy { $0.mailbox == workspace.folderPath(.setAside) }
    }

    var body: some View {
        HStack(spacing: 2) {
            dockButton("Reply", systemImage: "arrowshape.turn.up.left") {
                compose(.reply(to: conversation.latest.id))
            }
            .help("Reply (⌘R)")

            dockButton("Reply Later", systemImage: "clock") {
                workspace.move([conversation], to: .appFolder(.replyLater))
            }
            .disabled(!workspace.canMove([conversation], to: .appFolder(.replyLater)))
            .help("Reply Later (⌘L)")

            if isInSetAside {
                dockButton("Put Back", systemImage: "pin.slash") {
                    workspace.move([conversation], to: .inbox)
                }
                .help("Return to Mebox")
            } else {
                dockButton("Set Aside", systemImage: "pin") {
                    workspace.move([conversation], to: .appFolder(.setAside))
                }
                .disabled(!workspace.canMove([conversation], to: .appFolder(.setAside)))
                .help("Set Aside (⇧⌘S)")
            }

            dockButton(
                "Bubble Up",
                systemImage: activeBubbleUp?.condition == .ifNoReply ? "hourglass" : "bubbles.and.sparkles",
                isActive: activeBubbleUp != nil
            ) {
                showsBubbleUp = true
            }
            .help("Bubble Up (⇧⌘B)")
            .popover(isPresented: $showsBubbleUp, arrowEdge: .top) {
                BubbleUpPopover(conversation: conversation, workspace: workspace) {
                    showsBubbleUp = false
                }
            }

            Menu {
                ConversationMenu(workspace: workspace, conversations: [conversation])
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .frame(height: 18)
                    Text("More")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .floatingSurface(in: Capsule())
    }

    private func dockButton(
        _ title: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
    }
}
