import HeydayKit
import SwiftUI

/// The floating Set Aside card pile pinned at the bottom of Mebox. Shows the newest
/// pinned email stacked atop any others, and fans open into a quick list on click.
struct SetAsidePile: View {
    let workspace: Workspace

    @State private var isExpanded = false
    @State private var isHovering = false

    private var conversations: [Conversation] { workspace.setAsideConversations }

    var body: some View {
        if let top = conversations.first {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(-30))
                        .accessibilityHidden(true)

                    pileStack(top: top, count: conversations.count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .scaleEffect(isHovering ? 1.02 : 1)
            .motion(Motion.response, value: isHovering)
            .accessibilityLabel("Set Aside, \(conversations.count) pinned")
            .help("View \(conversations.count) Set Aside \(conversations.count == 1 ? "conversation" : "conversations")")
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                SetAsidePilePopover(workspace: workspace, conversations: conversations) {
                    isExpanded = false
                }
            }
            .transition(.settle)
        }
    }

    private func pileStack(top: Conversation, count: Int) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .bottom) {
            if count >= 3 {
                cardShape
                    .fill(Color.textBackground.opacity(0.75))
                    .overlay(cardShape.strokeBorder(.separator.opacity(0.6)))
                    .frame(height: 44)
                    .padding(.horizontal, 12)
                    .offset(y: -8)
            }
            if count >= 2 {
                cardShape
                    .fill(Color.textBackground.opacity(0.9))
                    .overlay(cardShape.strokeBorder(.separator.opacity(0.75)))
                    .frame(height: 46)
                    .padding(.horizontal, 6)
                    .offset(y: -4)
            }

            HStack(spacing: 9) {
                AvatarView(address: top.latest.from, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(top.subject.isEmpty ? "(No Subject)" : top.subject)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(top.latest.from?.address ?? top.latest.from?.displayName ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 168, alignment: .leading)

                if count > 1 {
                    Text(String(count))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.textBackground, in: cardShape)
            .overlay(cardShape.strokeBorder(.separator))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        }
        .padding(.top, count >= 3 ? 8 : count >= 2 ? 4 : 0)
    }
}

private struct SetAsidePilePopover: View {
    let workspace: Workspace
    let conversations: [Conversation]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Set Aside", systemImage: "pin.fill")
                    .font(.headline)
                Text(String(conversations.count))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button("Open List") {
                    onClose()
                    workspace.navigation.send(.listingChosen(.appFolder(.setAside)))
                }
                .linkStyled()
                .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(conversations) { conversation in
                        SetAsidePileRow(
                            conversation: conversation,
                            onOpen: {
                                onClose()
                                workspace.openSetAsideConversation(conversation)
                            },
                            onPutBack: {
                                workspace.move([conversation], to: .inbox)
                                if conversations.count <= 1 { onClose() }
                            }
                        )
                        if conversation.id != conversations.last?.id {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        #if os(macOS)
        .frame(width: 320)
        #else
        .frame(minWidth: 300, idealWidth: 320, maxWidth: .infinity)
        #endif
    }
}

private struct SetAsidePileRow: View {
    let conversation: Conversation
    let onOpen: () -> Void
    let onPutBack: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    AvatarView(address: conversation.latest.from, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.subject.isEmpty ? "(No Subject)" : conversation.subject)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(conversation.latest.from?.displayName ?? "Unknown Sender")
                                .lineLimit(1)
                            if let date = conversation.latest.date {
                                Text("·")
                                Text(ThreadTimestamp.text(for: date, now: .now, calendar: .current, locale: .current))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onPutBack) {
                Image(systemName: "pin.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Remove from Set Aside (return to Mebox)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovering = $0 }
    }
}
