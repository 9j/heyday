import HeydayKit
import SwiftUI

/// The Feed: a magazine-style stream of open newsletter cards. Each card loads its
/// cleaned HTML body lazily as it scrolls into view, clips long newsletters behind
/// "See more…" so you can skim effortlessly, and unfolds in place when asked.
struct FeedView<Footer: View>: View {
    let workspace: Workspace
    @ViewBuilder var footer: Footer

    @Environment(\.horizontalSizeClass) private var widthClass

    var body: some View {
        let sections = workspace.visitedBoxSections(for: .feed)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                FeedHeader()

                if !sections.new.isEmpty {
                    ForEach(sections.new) { conversation in
                        FeedCard(conversation: conversation, workspace: workspace)
                    }
                    NewSinceLastVisitedDivider()
                        .padding(.horizontal, 4)
                }

                ForEach(sections.earlier) { conversation in
                    FeedCard(conversation: conversation, workspace: workspace)
                }

                footer
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, widthClass == .compact ? 12 : 28)
            .padding(.top, widthClass == .compact ? 12 : 20)
            .padding(.bottom, 40)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(Color.windowBackground)
        .refreshable { await workspace.refresh(.box(.feed)) }
    }
}

/// Editorial header at the top of The Feed stream.
private struct FeedHeader: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                hairline(reversed: true)
                Text("The Feed")
                    .font(.title2.weight(.bold))
                hairline(reversed: false)
            }
            Text("Your newsfeed for newsletters. New stuff at the top, older stuff flows down.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func hairline(reversed: Bool) -> some View {
        LinearGradient(
            colors: reversed
                ? [HeydayTheme.violet.opacity(0.08), HeydayTheme.rose.opacity(0.55), HeydayTheme.coral.opacity(0.55)]
                : [HeydayTheme.coral.opacity(0.55), HeydayTheme.rose.opacity(0.55), HeydayTheme.violet.opacity(0.08)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1.5)
        .clipShape(Capsule())
    }
}

/// One newsletter in The Feed: subject, sender header, lazily loaded HTML preview,
/// and "See more…" to unfold the full email right in place.
private struct FeedCard: View {
    let conversation: Conversation
    let workspace: Workspace

    /// Preview height before clipping behind a fade and "See more…".
    private static let previewLimit: CGFloat = 380

    @State private var thread: Store<ThreadFeature>?
    @State private var translations: Store<TranslationFeature>?
    @State private var isExpanded = false
    @State private var bodyHeight: CGFloat?
    @State private var trackedLink: TrackedLink?
    @State private var isConfirmingAsSent = false
    @State private var attachmentProblem: String?

    @Environment(\.compose) private var compose
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var widthClass

    private struct TrackedLink: Identifiable {
        let url: URL
        let tracker: MailTracker
        var id: URL { url }
    }

    private var latest: MessageSummary { conversation.latest }
    private var subject: String { conversation.subject.isEmpty ? "(No Subject)" : conversation.subject }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private var loaded: ThreadFeature.Loaded? {
        if case .loaded(let loaded) = thread?.state.content { loaded } else { nil }
    }

    private var fullMessage: FullMessage? {
        loaded?.messages.last
    }

    private var protectedBody: ProtectedBody? {
        guard let id = fullMessage?.id else { return nil }
        return loaded?.bodies[id]
    }

    private var isShownAsSent: Bool {
        guard let id = fullMessage?.id else { return false }
        return loaded?.shownAsSent.contains(id) ?? false
    }

    private var messageTranslation: MessageTranslation? {
        guard let id = fullMessage?.id else { return nil }
        return translations?.state.messages[id]
    }

    private var isClipped: Bool {
        !isExpanded && (bodyHeight ?? 0) > Self.previewLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader
            cardBody
            cardFooter
        }
        .padding(widthClass == .compact ? 16 : 22)
        .background(Color.textBackground, in: shape)
        .overlay(shape.strokeBorder(.separator.opacity(0.7)))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
        .contextMenu { ConversationMenu(workspace: workspace, conversations: [conversation]) }
        .motion(Motion.layout, value: isExpanded)
        .motion(Motion.layout, value: messageTranslation?.isShown)
        .motion(Motion.layout, value: isShownAsSent)
        .task(id: ThreadRef(conversation)) {
            thread = workspace.feedThread(for: conversation)
            if translations == nil {
                translations = workspace.makeTranslations()
            }
        }
        .confirmationDialog(
            "This Link Is Tracked",
            isPresented: Binding(get: { trackedLink != nil }, set: { if !$0 { trackedLink = nil } }),
            presenting: trackedLink
        ) { link in
            Button("Open Anyway") { openURL(link.url) }
            Button("Copy Link") { Clipboard.copy(link.url.absoluteString) }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            Text("\(link.tracker.name) records the click, then sends you on.")
        }
        .confirmationDialog("Load This Email as Sent?", isPresented: $isConfirmingAsSent, titleVisibility: .visible) {
            Button("Load as Sent") {
                if let id = fullMessage?.id { thread?.send(.asSentRequested(id)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The sender will see that you opened it, when, and from which network. Tracked links will open without asking.")
        }
        .alert("Couldn’t Open the Attachment", isPresented: Binding(get: { attachmentProblem != nil }, set: { if !$0 { attachmentProblem = nil } })) {
            Button("OK") {}
        } message: {
            Text(attachmentProblem ?? "")
        }
    }

    // MARK: Header

    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: openThread) {
                    Text(subject)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Open full conversation")

                if conversation.messages.count > 1 {
                    Text(String(conversation.messages.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("\(conversation.messages.count) messages")
                }
            }

            MessageHeader(summary: latest, isExpanded: true) {
                cardMenu
            }
        }
    }

    private var cardMenu: some View {
        Menu {
            Button("Open Conversation", systemImage: "rectangle.expand.vertical", action: openThread)
            if let id = fullMessage?.id {
                if messageTranslation?.isShown == true {
                    Button("Show Original", systemImage: "translate") { translations?.send(.originalRequested(id)) }
                } else {
                    Button("Translate", systemImage: "translate") {
                        isExpanded = true
                        translations?.send(.requested(id))
                    }
                }
                if isShownAsSent {
                    Button("Protect Again", systemImage: "eye.slash") { thread?.send(.protectionRequested(id)) }
                } else {
                    Button("Load as Sent…", systemImage: "eye") { requestLoadAsSent() }
                }
            }
            Divider()
            Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(.reply(to: latest.id)) }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { compose(.forward(latest.id)) }
            Divider()
            ConversationMenu(workspace: workspace, conversations: [conversation])
        } label: {
            Label("Options for This Newsletter", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .tint(.secondary)
        .fixedSize()
    }

    // MARK: Body

    @ViewBuilder
    private var cardBody: some View {
        if case .unavailable(let error) = thread?.state.content {
            VStack(alignment: .leading, spacing: 6) {
                Text(error.userMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try Again") { thread?.send(.opened) }
                    .linkStyled()
            }
            .padding(.vertical, 4)
        } else if let message = fullMessage, let content = protectedBody, let loaded {
            let id = message.id
            let images = loaded.images(in: id)

            if isExpanded {
                if isShownAsSent {
                    AsSentNotice { thread?.send(.protectionRequested(id)) }
                } else {
                    PrivacyNotice(
                        report: content.report,
                        heldBackImages: content.images.indices.count { images[$0] == nil },
                        onShowAllImages: { thread?.send(.allImagesRequested(id)) },
                        onLoadAsSent: requestLoadAsSent
                    )
                }
                if let translation = messageTranslation {
                    TranslationNotice(
                        translation: translation,
                        onTranslate: { translations?.send(.requested(id)) },
                        onShowOriginal: { translations?.send(.originalRequested(id)) },
                        onChooseLanguage: { code in
                            workspace.translate(into: code)
                            translations?.send(.retranslationRequested(id))
                        }
                    )
                }
            }

            ZStack(alignment: .bottom) {
                MessageBodyView(
                    html: isShownAsSent ? message.html : content.displayHTML,
                    policy: isShownAsSent ? .asSent : .protected,
                    blocked: isShownAsSent ? [] : content.images,
                    images: isShownAsSent ? [:] : images,
                    translation: messageTranslation,
                    translationReplacesOriginal: workspace.translation.state.settings.display == .translationOnly,
                    onShowImage: { thread?.send(.imageRequested(ImageRef(message: id, index: $0))) },
                    onOpenLink: openLink,
                    onParagraphs: { translations?.send(.paragraphsRead(id, $0)) },
                    maxHeight: isExpanded ? nil : Self.previewLimit,
                    onContentHeight: { bodyHeight = $0 }
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if isClipped {
                    LinearGradient(
                        colors: [Color.textBackground.opacity(0), Color.textBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 68)
                    .allowsHitTesting(false)
                }
            }

            if isExpanded, !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments) { attachmentProblem = $0 }
            }
        } else {
            MessageBodyPlaceholder()
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var cardFooter: some View {
        let hasExtraContent = isClipped
            || conversation.messages.count > 1
            || !(fullMessage?.attachments.isEmpty ?? true)

        if isExpanded {
            HStack(spacing: 10) {
                Button("Show less") {
                    isExpanded = false
                }
                .buttonStyle(FeedPillButtonStyle())

                if conversation.messages.count > 1 {
                    Button("Open all \(conversation.messages.count) messages", action: openThread)
                        .linkStyled()
                        .font(.subheadline)
                }

                Spacer(minLength: 8)

                if let id = fullMessage?.id {
                    Button {
                        if messageTranslation?.isShown == true {
                            translations?.send(.originalRequested(id))
                        } else {
                            translations?.send(.requested(id))
                        }
                    } label: {
                        Image(systemName: "translate")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(messageTranslation?.isShown == true ? HeydayTheme.rose : Color.secondary)
                    .help(messageTranslation?.isShown == true ? "Show Original" : "Translate")
                }

                if workspace.canMove([conversation], to: .role(.archive)) {
                    Button {
                        workspace.move([conversation], to: .role(.archive))
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Archive")
                }

                if workspace.canMove([conversation], to: .role(.trash)) {
                    Button {
                        workspace.move([conversation], to: .role(.trash))
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Move to Trash")
                }
            }
            .padding(.top, 2)
        } else if hasExtraContent {
            HStack(spacing: 12) {
                Button("See more…") {
                    isExpanded = true
                }
                .buttonStyle(FeedPillButtonStyle())

                if conversation.messages.count > 1 {
                    Button("Open thread (\(conversation.messages.count))", action: openThread)
                        .linkStyled()
                        .font(.subheadline)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Actions

    private func openThread() {
        workspace.navigation.send(.selectionChanged([conversation.id]))
    }

    private func requestLoadAsSent() {
        guard let id = fullMessage?.id else { return }
        if let report = protectedBody?.report, !report.pixels.isEmpty || !report.trackedLinks.isEmpty {
            isConfirmingAsSent = true
        } else {
            thread?.send(.asSentRequested(id))
        }
    }

    private func openLink(_ url: URL) {
        if !isShownAsSent, let tracker = MailTracker.tracking(link: url) {
            trackedLink = TrackedLink(url: url, tracker: tracker)
        } else {
            openURL(url)
        }
    }
}

/// Quiet capsule button matching HEY's "See more…" pill at the bottom of a Feed card.
private struct FeedPillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.textBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.response, value: configuration.isPressed)
    }
}
