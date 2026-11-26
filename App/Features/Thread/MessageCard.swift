import HeydayKit
import SwiftUI

/// One email in a conversation. Folded, it is a line of sender and preview;
/// expanded, the full header, body and attachments.
///
/// The header is drawn from what the list already knew about the message, so a
/// conversation shows who wrote what the moment it is opened. The rest fills in
/// when the message itself arrives.
struct MessageCard: View {
    /// What the card tells the conversation it sits in.
    struct Actions {
        let toggle: () -> Void
        let showImage: (Int) -> Void
        let showAllImages: () -> Void
        let loadAsSent: () -> Void
        let protect: () -> Void
        let translate: () -> Void
        let showOriginal: () -> Void
        /// Receives the code of a language chosen for this message's translation.
        let chooseLanguage: (String) -> Void
        /// Receives the message's paragraphs when its translation waits for them.
        let paragraphs: ([String]) -> Void
        let reply: () -> Void
        let forward: () -> Void
        let problem: (String) -> Void
    }

    let summary: MessageSummary
    /// The message itself, once fetched.
    let message: FullMessage?
    /// The message's body with its trackers dealt with.
    let content: ProtectedBody?
    /// How fetching the remote images asked for so far is going.
    let images: [Int: ImageLoad]
    /// How far the message's translation is, if one was asked for.
    let translation: MessageTranslation?
    /// Whether a translation takes its paragraph's place, rather than following it.
    let translationReplacesOriginal: Bool
    /// Whether the person asked to see this message exactly as it was sent.
    let isShownAsSent: Bool
    let isExpanded: Bool
    let canFold: Bool
    let actions: Actions

    /// A link the reader clicked that goes through a click tracker.
    @State private var trackedLink: TrackedLink?
    /// Whether the person is being asked if known trackers may run.
    @State private var isConfirmingAsSent = false
    @State private var isUnderPointer = false
    @Environment(\.openURL) private var openURL

    private struct TrackedLink: Identifiable {
        let url: URL
        let tracker: MailTracker
        var id: URL { url }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MessageHeader(summary: summary, isExpanded: isExpanded) {
                if isExpanded, message != nil {
                    menu
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canFold { actions.toggle() }
            }
            // Folded, the line is one thing to press. Expanded, its parts are
            // reached one by one, and folding is an action on them.
            .accessibilityElement(children: isExpanded ? .contain : .combine)
            .accessibilityAddTraits(canFold && !isExpanded ? .isButton : [])
            .accessibilityAction(named: isExpanded ? "Fold Message" : "Expand Message") {
                if canFold { actions.toggle() }
            }

            if isExpanded {
                if let message, let content {
                    opened(message, content)
                        .transition(.opacity)
                } else {
                    MessageBodyPlaceholder()
                        .transition(.opacity)
                }
            }
        }
        .padding(isExpanded ? 16 : 12)
        .background(surface, in: shape)
        .overlay(shape.strokeBorder(.separator))
        .onHover { isUnderPointer = $0 }
        .motion(Motion.response, value: isUnderPointer)
        // A notice coming or going moves the email under it, rather than jolting it.
        .motion(Motion.layout, value: translation?.phase)
        .motion(Motion.layout, value: translation?.isShown)
        .motion(Motion.layout, value: isShownAsSent)
        .motion(Motion.layout, value: images.count)
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
            Button("Load as Sent", action: actions.loadAsSent)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The sender will see that you opened it, when, and from which network. Tracked links will open without asking.")
        }
    }

    /// A folded message sits back into the page and comes forward under the pointer;
    /// an open one is a sheet of paper on it.
    private var surface: Color {
        if isExpanded { return .textBackground }
        return .textBackground.opacity(canFold && isUnderPointer ? 0.9 : 0.45)
    }

    @ViewBuilder
    private func opened(_ message: FullMessage, _ content: ProtectedBody) -> some View {
        if isShownAsSent {
            AsSentNotice(onProtect: actions.protect)
        } else {
            PrivacyNotice(
                report: content.report,
                heldBackImages: content.images.indices.count { images[$0] == nil },
                onShowAllImages: actions.showAllImages,
                onLoadAsSent: loadAsSent
            )
        }
        if let translation {
            TranslationNotice(
                translation: translation,
                onTranslate: actions.translate,
                onShowOriginal: actions.showOriginal,
                onChooseLanguage: actions.chooseLanguage
            )
        }
        MessageBodyView(
            // As sent, the page is the email as it arrived and fetches for
            // itself; otherwise the app does, into the cleaned copy.
            html: isShownAsSent ? message.html : content.displayHTML,
            policy: isShownAsSent ? .asSent : .protected,
            blocked: isShownAsSent ? [] : content.images,
            images: isShownAsSent ? [:] : images,
            translation: translation,
            translationReplacesOriginal: translationReplacesOriginal,
            onShowImage: actions.showImage,
            onOpenLink: open,
            onParagraphs: actions.paragraphs
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        if !message.attachments.isEmpty {
            AttachmentStrip(attachments: message.attachments, onProblem: actions.problem)
        }
    }

    private var menu: some View {
        Menu {
            Button("Reply", systemImage: "arrowshape.turn.up.left", action: actions.reply)
            Button("Forward", systemImage: "arrowshape.turn.up.right", action: actions.forward)
            Divider()
            if translation?.isShown == true {
                Button("Show Original", systemImage: "translate", action: actions.showOriginal)
            } else {
                Button("Translate", systemImage: "translate", action: actions.translate)
            }
            if isShownAsSent {
                Button("Protect Again", systemImage: "eye.slash", action: actions.protect)
            } else {
                Button("Load as Sent…", systemImage: "eye", action: loadAsSent)
            }
        } label: {
            Label("Options for This Message", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                // Room for a finger around three small dots.
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        // Quiet beside the date: it is the fourth thing in the header, not the first.
        .tint(.secondary)
        .fixedSize()
    }

    /// Shows the email as sent. Asks first when that lets a known tracker report;
    /// a picture that was merely held back is not worth a question.
    private func loadAsSent() {
        guard let report = content?.report, !report.pixels.isEmpty || !report.trackedLinks.isEmpty else {
            actions.loadAsSent()
            return
        }
        isConfirmingAsSent = true
    }

    /// Opens a link the reader clicked, asking first when it is a tracked one. In an
    /// email taken as sent, its tracked links were accepted with it.
    private func open(_ url: URL) {
        if !isShownAsSent, let tracker = MailTracker.tracking(link: url) {
            trackedLink = TrackedLink(url: url, tracker: tracker)
        } else {
            openURL(url)
        }
    }
}

/// Who an email is from, to whom and when. Folded, all of it is one line with the
/// email's first words; expanded, the sender's address and the recipients show too,
/// and the recipients open into the full list.
struct MessageHeader<Accessory: View>: View {
    let summary: MessageSummary
    let isExpanded: Bool
    /// What sits at the end of the header, after the date.
    @ViewBuilder var accessory: Accessory

    @State private var showsEveryRecipient = false

    var body: some View {
        HStack(alignment: isExpanded ? .top : .center, spacing: 10) {
            AvatarView(address: summary.from, size: isExpanded ? 36 : 28)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    // The address goes beside the name where both fit whole; on a
                    // narrow screen the name alone is clearer than two cut-off halves.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            senderName
                            if let from = summary.from, !from.name.isEmpty {
                                Text(from.address)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        senderName
                    }
                    .lineLimit(1)
                    recipients
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                senderName
                    .lineLimit(1)
                    .layoutPriority(1)
                // The first words run on as far as the date leaves room.
                Text(summary.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let date = summary.date {
                Text(ThreadTimestamp.text(for: date, now: .now, calendar: .current, locale: .current))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(date.formatted(date: .complete, time: .shortened))
            }
            accessory
        }
    }

    private var senderName: some View {
        Text(summary.from?.displayName ?? "Unknown Sender")
            .font(isExpanded ? .headline : .subheadline.weight(.semibold))
    }

    /// "To: jane@example.com, sam@example.com + 2 more", and on a click every
    /// recipient by name and address.
    @ViewBuilder
    private var recipients: some View {
        let everyone = summary.to + summary.cc
        if !everyone.isEmpty {
            Button {
                showsEveryRecipient.toggle()
            } label: {
                Group {
                    if showsEveryRecipient {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("To: " + summary.to.map(\.formatted).joined(separator: ", "))
                            if !summary.cc.isEmpty {
                                Text("Cc: " + summary.cc.map(\.formatted).joined(separator: ", "))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    } else {
                        Text(briefRecipients(everyone))
                            .lineLimit(1)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsEveryRecipient ? "Shows fewer recipients" : "Shows every recipient")
            .motion(Motion.layout, value: showsEveryRecipient)
        }
    }

    private func briefRecipients(_ everyone: [EmailAddress]) -> String {
        let shown = everyone.prefix(2).map(\.address).joined(separator: ", ")
        let hidden = everyone.count - 2
        return hidden > 0 ? "To: \(shown) + \(hidden) more" : "To: \(shown)"
    }
}
