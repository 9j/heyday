import HeydayKit
import SwiftUI

/// HEY-inspired Bubble Up scheduler popover: quick presets ("Now", "Later today",
/// "Tomorrow", "This weekend", "Next week", "Surprise me"), custom date picker,
/// and "If no reply by…".
struct BubbleUpPopover: View {
    let conversation: Conversation
    let workspace: Workspace
    let onDone: () -> Void

    private enum CustomMode: Equatable {
        case none
        case pickDate
        case ifNoReply
    }

    @State private var customMode: CustomMode = .none
    @State private var customDate = BubbleUpSchedule.defaultCustomDate(now: .now, calendar: .current)
    @State private var hoveredRow: String?

    private var current: BubbleUp? { workspace.bubbleUp(for: conversation) }
    private var now: Date { Date() }

    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.39, blue: 0.94),
                Color(red: 0.25, green: 0.20, blue: 0.90),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use Bubble Up to schedule when this email floats back up to your Mebox.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            if let current {
                activeBanner(current)
            }

            switch customMode {
            case .none:
                presetList
            case .pickDate:
                customDateForm(condition: .always)
            case .ifNoReply:
                customDateForm(condition: .ifNoReply)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: customMode == .none ? 288 : 316)
        #else
        .frame(minWidth: 288, idealWidth: customMode == .none ? 300 : 328, maxWidth: .infinity)
        #endif
        .background(cardGradient)
        .environment(\.colorScheme, .dark)
        .motion(Motion.layout, value: customMode)
    }

    // MARK: Active status banner

    private func activeBanner(_ bubbleUp: BubbleUp) -> some View {
        let isDue = bubbleUp.isDue(for: conversation, at: now)
        let when = BubbleUpSchedule.shortLabel(for: bubbleUp.dueAt, now: now, calendar: .current, locale: .current)
        let label: String = if isDue {
            "Currently bubbled up"
        } else if bubbleUp.condition == .ifNoReply {
            "If no reply by \(when)"
        } else {
            "Scheduled for \(when)"
        }

        return HStack(spacing: 8) {
            Image(systemName: bubbleUp.condition == .ifNoReply ? "hourglass" : "bubbles.and.sparkles")
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Dismiss") {
                workspace.dismissBubbleUp(for: conversation)
                onDone()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.22), in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Presets

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BUBBLE THIS UP…")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            presetRow(id: "now", title: "Now", detail: nil, symbol: "circle") {
                schedule(.now)
            }
            presetRow(id: "later", title: "Later today", detail: subtitle(for: .laterToday), symbol: "circle") {
                schedule(.laterToday)
            }
            presetRow(id: "tomorrow", title: "Tomorrow", detail: subtitle(for: .tomorrow), symbol: "circle") {
                schedule(.tomorrow)
            }
            presetRow(id: "weekend", title: "This weekend", detail: subtitle(for: .thisWeekend), symbol: "circle") {
                schedule(.thisWeekend)
            }
            presetRow(id: "nextWeek", title: "Next week", detail: subtitle(for: .nextWeek), symbol: "circle") {
                schedule(.nextWeek)
            }
            presetRow(id: "surprise", title: "Surprise me", detail: "???", symbol: "circle") {
                schedule(.surpriseMe)
            }
            presetRow(id: "pick", title: "Pick a date…", detail: "8am", symbol: "circle") {
                customDate = BubbleUpSchedule.defaultCustomDate(now: now, calendar: .current)
                customMode = .pickDate
            }
            presetRow(id: "noReply", title: "If no reply by…", detail: "8am", symbol: "hourglass") {
                customDate = BubbleUpSchedule.defaultCustomDate(now: now, calendar: .current)
                customMode = .ifNoReply
            }
        }
    }

    private func presetRow(
        id: String,
        title: String,
        detail: String?,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoveredRow == id ? Color.white.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isOver in
            hoveredRow = isOver ? id : (hoveredRow == id ? nil : hoveredRow)
        }
    }

    // MARK: Custom date & "If no reply by…"

    private func customDateForm(condition: BubbleUp.Condition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    customMode = .none
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(condition == .ifNoReply ? "IF NO REPLY BY" : "PICK A DATE")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.75))
            }

            if condition == .ifNoReply {
                Text("Floats back to Mebox only if nobody replies before this time.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            DatePicker(
                "Bubble Up Time",
                selection: $customDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(.white)

            Button {
                workspace.scheduleBubbleUp(conversation, dueAt: customDate, condition: condition)
                onDone()
            } label: {
                Text(condition == .ifNoReply ? "Bubble Up If No Reply" : "Bubble Up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.28, blue: 0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.pressable)
        }
    }

    private func subtitle(for preset: BubbleUpSchedule.Preset) -> String {
        let target = BubbleUpSchedule.date(for: preset, now: now, calendar: .current)
        return BubbleUpSchedule.shortLabel(for: target, now: now, calendar: .current, locale: .current)
    }

    private func schedule(_ preset: BubbleUpSchedule.Preset) {
        let target = BubbleUpSchedule.date(for: preset, now: now, calendar: .current)
        workspace.scheduleBubbleUp(conversation, dueAt: target, condition: .always)
        onDone()
    }
}
