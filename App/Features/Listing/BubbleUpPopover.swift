import HeydayKit
import SwiftUI

/// Native SwiftUI Bubble Up scheduler popover built around Heyday's Dawn palette:
/// adapts to macOS Liquid Glass / Light & Dark mode, offers a scannable 2×3 tile grid
/// of quick presets, and reveals an inline DatePicker with an "Always / If No Reply"
/// condition switch.
struct BubbleUpPopover: View {
    let conversation: Conversation
    let workspace: Workspace
    let onDone: () -> Void

    private enum Mode: Equatable {
        case presets
        case custom
    }

    @State private var mode: Mode = .presets
    @State private var customDate = BubbleUpSchedule.defaultCustomDate(now: .now, calendar: .current)
    @State private var customCondition: BubbleUp.Condition = .always

    private var current: BubbleUp? { workspace.bubbleUp(for: conversation) }
    private var now: Date { Date() }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let current {
                activeBanner(current)
            }

            switch mode {
            case .presets:
                presetContent
            case .custom:
                customDateContent
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: mode == .presets ? 304 : 332)
        #else
        .frame(minWidth: 296, idealWidth: 324, maxWidth: .infinity)
        #endif
        .tint(HeydayTheme.rose)
        .motion(Motion.layout, value: mode)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HeydayTheme.dawnGradient)
                Image(systemName: "sun.horizon.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Bubble Up")
                    .font(.headline)
                Text("Bring back to the top of Mebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if mode == .custom {
                Button {
                    mode = .presets
                } label: {
                    Label("Presets", systemImage: "chevron.left")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: Active status banner

    private func activeBanner(_ bubbleUp: BubbleUp) -> some View {
        let isDue = bubbleUp.isDue(for: conversation, at: now)
        let when = BubbleUpSchedule.shortLabel(for: bubbleUp.dueAt, now: now, calendar: .current, locale: .current)
        let title: String = if isDue {
            "Bubbled up now"
        } else if bubbleUp.condition == .ifNoReply {
            "If no reply · \(when)"
        } else {
            "Scheduled · \(when)"
        }

        return HStack(spacing: 8) {
            Image(systemName: bubbleUp.condition == .ifNoReply ? "hourglass" : "sun.horizon.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HeydayTheme.rose)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(isDue ? "Pop" : "Clear") {
                workspace.dismissBubbleUp(for: conversation)
                onDone()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(HeydayTheme.rose.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(HeydayTheme.rose.opacity(0.22), lineWidth: 0.75)
        )
    }

    // MARK: Presets (2×3 spatial grid + custom triggers)

    private var presetContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: gridColumns, spacing: 8) {
                PresetTile(
                    title: "Right Now",
                    subtitle: "Float to top",
                    symbol: "arrow.up.circle.fill",
                    tint: HeydayTheme.rose
                ) {
                    schedule(.now)
                }

                PresetTile(
                    title: "Later Today",
                    subtitle: subtitle(for: .laterToday),
                    symbol: "sunset.fill",
                    tint: HeydayTheme.coral
                ) {
                    schedule(.laterToday)
                }

                PresetTile(
                    title: "Tomorrow",
                    subtitle: subtitle(for: .tomorrow),
                    symbol: "sunrise.fill",
                    tint: HeydayTheme.sun
                ) {
                    schedule(.tomorrow)
                }

                PresetTile(
                    title: "This Weekend",
                    subtitle: subtitle(for: .thisWeekend),
                    symbol: "sun.max.fill",
                    tint: HeydayTheme.coral
                ) {
                    schedule(.thisWeekend)
                }

                PresetTile(
                    title: "Next Week",
                    subtitle: subtitle(for: .nextWeek),
                    symbol: "calendar",
                    tint: HeydayTheme.violet
                ) {
                    schedule(.nextWeek)
                }

                PresetTile(
                    title: "Surprise Me",
                    subtitle: "2–14 days",
                    symbol: "sparkles",
                    tint: HeydayTheme.rose,
                    usesGradientIcon: true
                ) {
                    schedule(.surpriseMe)
                }
            }

            Divider()

            VStack(spacing: 4) {
                CustomTriggerRow(
                    title: "Pick Date & Time…",
                    symbol: "calendar.badge.clock",
                    tint: HeydayTheme.violet
                ) {
                    openCustom(condition: .always)
                }

                CustomTriggerRow(
                    title: "Only If No Reply By…",
                    symbol: "hourglass",
                    tint: HeydayTheme.coral
                ) {
                    openCustom(condition: .ifNoReply)
                }
            }
        }
    }

    // MARK: Inline custom DatePicker + condition toggle

    private var customDateContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Condition", selection: $customCondition) {
                Text("Always").tag(BubbleUp.Condition.always)
                Text("If No Reply").tag(BubbleUp.Condition.ifNoReply)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if customCondition == .ifNoReply {
                Text("Cancels automatically if someone replies before this time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .tint(HeydayTheme.rose)

            Button {
                workspace.scheduleBubbleUp(conversation, dueAt: customDate, condition: customCondition)
                onDone()
            } label: {
                Text(customCondition == .ifNoReply ? "Schedule If No Reply" : "Schedule Bubble Up")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Helpers

    private func openCustom(condition: BubbleUp.Condition) {
        customCondition = condition
        if let existing = current?.dueAt, existing.timeIntervalSinceNow > 60 {
            customDate = existing
        } else {
            customDate = BubbleUpSchedule.defaultCustomDate(now: now, calendar: .current)
        }
        mode = .custom
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

/// One spatial quick-pick tile inside `BubbleUpPopover`.
private struct PresetTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var usesGradientIcon = false
    let action: () -> Void

    @State private var isHovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 11, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                if usesGradientIcon {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HeydayTheme.dawnGradient)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                shape.fill(isHovering ? tint.opacity(0.11) : Color.primary.opacity(0.045))
            )
            .overlay(
                shape.strokeBorder(isHovering ? tint.opacity(0.32) : Color.primary.opacity(0.06), lineWidth: 0.75)
            )
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .motion(Motion.response, value: isHovering)
    }
}

/// Compact native row for jumping into the graphical DatePicker.
private struct CustomTriggerRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(shape.fill(isHovering ? Color.primary.opacity(0.06) : Color.clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
