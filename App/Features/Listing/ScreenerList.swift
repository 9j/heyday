import HeydayKit
import SwiftUI

/// The Screener's middle column: one row per sender waiting for an answer. Selecting
/// a row shows what they sent; the thumbs, or a swipe, answer without opening it.
struct ScreenerList<Footer: View>: View {
    let workspace: Workspace
    @ViewBuilder var footer: Footer

    var body: some View {
        let waiting = workspace.waitingSenders
        let waitingIDs = waiting.map(\.id)
        List(selection: workspace.listSelection) {
            ForEach(waiting) { entry in
                ScreenerRow(entry: entry) { workspace.decide($0, for: entry.sender) }
                    // The detail column shows the sender's newest conversation.
                    .tag(entry.latest.id)
                    .contextMenu { DeliveryChoices(sender: entry.sender, workspace: workspace) }
                    .swipeActions(edge: .leading) {
                        Button("Yes", systemImage: "hand.thumbsup.fill") { workspace.decide(.approved(.mebox), for: entry.sender) }
                            .tint(HeydayTheme.rose)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("No", systemImage: "hand.thumbsdown.fill") { workspace.decide(.screenedOut, for: entry.sender) }
                            .tint(.gray)
                    }
            }
            footer
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        #endif
        // An answered sender's row closes up behind them.
        .motion(Motion.layout, value: waitingIDs)
        .keepsMacListRowHeights(when: waitingIDs)
    }
}

private struct ScreenerRow: View {
    let entry: WaitingSender
    let onDecide: (SenderDecision) -> Void

    @ScaledMetric(relativeTo: .body) private var avatarSize = Self.avatarBaseSize

    private static var avatarBaseSize: CGFloat {
        #if os(macOS)
        32
        #else
        40
        #endif
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(address: entry.sender, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sender.displayName)
                    .font(.headline)
                if !entry.sender.name.isEmpty {
                    Text(entry.sender.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(summary)
                    .font(.subheadline)
            }
            .lineLimit(1)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }
            Spacer(minLength: 8)
            Button {
                onDecide(.approved(.mebox))
            } label: {
                Label("Yes", systemImage: "hand.thumbsup.fill")
            }
            .buttonStyle(AnswerCircleStyle(isProminent: true))
            .help("Yes: deliver their email to Mebox")
            Button {
                onDecide(.screenedOut)
            } label: {
                Label("No", systemImage: "hand.thumbsdown.fill")
            }
            .buttonStyle(AnswerCircleStyle())
            .help("No: screen them out")
        }
        .padding(.vertical, 4)
    }

    /// Their newest subject, and how many more conversations are waiting behind it.
    private var summary: String {
        let subject = entry.latest.subject.isEmpty ? "(No Subject)" : entry.latest.subject
        let others = entry.conversations.count - 1
        return others > 0 ? "\(subject) + \(others) more" : subject
    }
}

/// The question the Screener asks, floating over a waiting sender's email: who is
/// asking to get in, and the four answers. Where they do not fit side by side with
/// their names, the two boxes besides Mebox go into a menu between the thumbs.
struct ScreenerBanner: View {
    let sender: EmailAddress
    let onDecide: (SenderDecision) -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(address: sender, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(sender.displayName)
                    .font(.subheadline.weight(.semibold))
                if !sender.name.isEmpty {
                    Text(sender.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                answersByName
                answersBySymbol
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .floatingSurface(in: shape)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Want to get email from \(sender.displayName)?")
    }

    private var answersByName: some View {
        HStack(spacing: 6) {
            Button("Screen Out", systemImage: "hand.thumbsdown") { onDecide(.screenedOut) }
                .tint(.primary)
            Button("Paper Trail", systemImage: "scroll") { onDecide(.approved(.paperTrail)) }
                .tint(.primary)
            Button("The Feed", systemImage: "newspaper") { onDecide(.approved(.feed)) }
                .tint(.primary)
            Button("Yes", systemImage: "hand.thumbsup.fill") { onDecide(.approved(.mebox)) }
                .buttonStyle(.borderedProminent)
                .tint(HeydayTheme.rose)
                .help("Yes: deliver their email to Mebox")
        }
        .buttonBorderShape(.capsule)
        .fixedSize()
    }

    private var answersBySymbol: some View {
        HStack(spacing: 8) {
            Button("Screen Out", systemImage: "hand.thumbsdown.fill") { onDecide(.screenedOut) }
                .buttonStyle(AnswerCircleStyle())
                .help("No: screen them out")
            Menu("Deliver Elsewhere", systemImage: "tray.and.arrow.down") {
                Button("The Feed", systemImage: "newspaper") { onDecide(.approved(.feed)) }
                Button("Paper Trail", systemImage: "scroll") { onDecide(.approved(.paperTrail)) }
            }
            // Drawn by the button style, with no arrow beside it: a Mac otherwise
            // draws a menu as a pull-down.
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(AnswerCircleStyle())
            .help("Deliver their email to The Feed or the Paper Trail")
            Button("Yes", systemImage: "hand.thumbsup.fill") { onDecide(.approved(.mebox)) }
                .buttonStyle(AnswerCircleStyle(isProminent: true))
                .help("Yes: deliver their email to Mebox")
        }
        .fixedSize()
    }
}

/// How the Screener draws an answer given by its symbol: the symbol in a circle,
/// filled with the accent colour for yes and with grey for the rest.
///
/// The app's own style rather than the system's bordered one, so that a menu among
/// the answers looks like the buttons beside it: a Mac draws a menu as a pull-down,
/// and the system's circle does not fit around one.
private struct AnswerCircleStyle: ButtonStyle {
    var isProminent = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// About the size of the system's own round buttons on each platform.
    private static var diameter: CGFloat {
        #if os(macOS)
        26
        #else
        34
        #endif
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: Self.diameter, height: Self.diameter)
            .background(isProminent ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : isEnabled ? 1 : 0.4)
            .animation(Motion.response, value: configuration.isPressed)
    }
}
