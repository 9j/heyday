import Foundation

/// A scheduled reminder to float a conversation back to the top of Mebox at a chosen
/// time — either unconditionally or only if nobody has replied by then.
public struct BubbleUp: Codable, Equatable, Sendable {
    public enum Condition: String, Codable, Equatable, Sendable {
        case always
        case ifNoReply
    }

    /// When the conversation floats to the top of Mebox (stored to the second).
    public let dueAt: Date
    public let condition: Condition
    /// Message count in the conversation when scheduled, so `.ifNoReply` can detect
    /// whether a newer message arrived before `dueAt`.
    public let baselineMessageCount: Int
    public let scheduledAt: Date

    public init(
        dueAt: Date,
        condition: Condition = .always,
        baselineMessageCount: Int = 0,
        scheduledAt: Date
    ) {
        self.dueAt = dueAt.toTheSecond
        self.condition = condition
        self.baselineMessageCount = baselineMessageCount
        self.scheduledAt = scheduledAt.toTheSecond
    }

    /// Whether a reply arrived after this Bubble Up was scheduled, cancelling an
    /// `.ifNoReply` reminder.
    public func isSatisfiedByReply(in conversation: Conversation) -> Bool {
        condition == .ifNoReply && conversation.messages.count > baselineMessageCount
    }

    /// Whether this conversation should currently sit in the "Bubbled Up" section.
    public func isDue(for conversation: Conversation, at now: Date) -> Bool {
        guard now.toTheSecond >= dueAt else { return false }
        return !isSatisfiedByReply(in: conversation)
    }
}

/// Every active and recently dismissed Bubble Up, keyed by conversation ID.
/// Kept on this Mac and synced across devices via `SyncedState`.
public struct BubbleUpRules: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        /// Nil records a dismissal so other devices also pop the bubble.
        var bubbleUp: BubbleUp?
        var changedAt: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func bubbleUp(for id: Conversation.ID) -> BubbleUp? {
        entries[id]?.bubbleUp
    }

    public mutating func schedule(_ bubbleUp: BubbleUp, for id: Conversation.ID, at time: Date) {
        entries[id] = Entry(bubbleUp: bubbleUp, changedAt: nextTimestamp(for: id, at: time))
    }

    public mutating func dismiss(for id: Conversation.ID, at time: Date) {
        entries[id] = Entry(bubbleUp: nil, changedAt: nextTimestamp(for: id, at: time))
    }

    /// The earliest future `dueAt` across all active Bubble Ups, so the app can
    /// sleep until the exact moment the next conversation floats up.
    public func nextDueDate(after now: Date) -> Date? {
        let nowSecond = now.toTheSecond
        return entries.values
            .compactMap(\.bubbleUp?.dueAt)
            .filter { $0 > nowSecond }
            .min()
    }

    /// Ensures rapid schedule/dismiss changes within the same second remain ordered.
    private func nextTimestamp(for id: Conversation.ID, at time: Date) -> Date {
        let second = time.toTheSecond
        if let last = entries[id]?.changedAt, second <= last {
            return last.addingTimeInterval(1)
        }
        return second
    }
}

extension BubbleUpRules: Mergeable {
    /// Each conversation keeps whichever device scheduled or dismissed it last.
    public func merged(with other: BubbleUpRules) -> BubbleUpRules {
        var merged = self
        merged.entries.merge(other.entries) { mine, theirs in
            if theirs.changedAt != mine.changedAt {
                return theirs.changedAt > mine.changedAt ? theirs : mine
            }
            // Changed in the same second: deterministic order on both devices.
            switch (mine.bubbleUp, theirs.bubbleUp) {
            case (let lhs?, let rhs?):
                return Self.isOrderedBefore(lhs, rhs) ? theirs : mine
            case (.some, nil):
                return mine
            case (nil, .some):
                return theirs
            case (nil, nil):
                return mine
            }
        }
        return merged
    }

    private static func isOrderedBefore(_ lhs: BubbleUp, _ rhs: BubbleUp) -> Bool {
        if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
        if lhs.condition.rawValue != rhs.condition.rawValue { return lhs.condition.rawValue < rhs.condition.rawValue }
        if lhs.baselineMessageCount != rhs.baselineMessageCount { return lhs.baselineMessageCount < rhs.baselineMessageCount }
        return lhs.scheduledAt < rhs.scheduledAt
    }
}

/// Computes target dates and compact labels for HEY's Bubble Up quick options.
public enum BubbleUpSchedule {
    public enum Preset: Hashable, Sendable {
        case now
        case laterToday
        case tomorrow
        case thisWeekend
        case nextWeek
        /// Picks a future day 2–14 days out at morning or afternoon.
        case surpriseMe
    }

    /// Computes when `preset` fires relative to `now`.
    /// - Parameter randomDayOffset: injectable 0-based offset (0...12 → 2...14 days) for `.surpriseMe`.
    public static func date(
        for preset: Preset,
        now: Date,
        calendar: Calendar,
        randomDayOffset: Int = Int.random(in: 0...12)
    ) -> Date {
        switch preset {
        case .now:
            return now.toTheSecond

        case .laterToday:
            if let sixPM = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now),
               sixPM > now.addingTimeInterval(3600) {
                return sixPM
            }
            // After 5pm: three hours from now, rounded to the hour.
            let target = now.addingTimeInterval(3 * 3600)
            return calendar.date(
                bySettingHour: calendar.component(.hour, from: target),
                minute: 0,
                second: 0,
                of: target
            ) ?? target.toTheSecond

        case .tomorrow:
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: nextDay) ?? nextDay

        case .thisWeekend:
            // Saturday = 7 in Gregorian calendar.
            let weekday = calendar.component(.weekday, from: now)
            let hour = calendar.component(.hour, from: now)
            let daysUntilSaturday: Int
            if weekday == 7 && hour < 8 {
                daysUntilSaturday = 0
            } else {
                let raw = (7 - weekday + 7) % 7
                daysUntilSaturday = raw == 0 ? 7 : raw
            }
            let saturday = calendar.date(byAdding: .day, value: daysUntilSaturday, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: saturday) ?? saturday

        case .nextWeek:
            // Monday = 2 in Gregorian calendar.
            let weekday = calendar.component(.weekday, from: now)
            let raw = (2 - weekday + 7) % 7
            let daysUntilMonday = raw == 0 ? 7 : raw
            let monday = calendar.date(byAdding: .day, value: daysUntilMonday, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: monday) ?? monday

        case .surpriseMe:
            let clamped = max(0, min(12, randomDayOffset))
            let days = 2 + clamped
            let targetDay = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            let hour = (clamped % 2 == 0) ? 8 : 14
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: targetDay) ?? targetDay
        }
    }

    /// Default date shown when opening "Pick a date…" or "If no reply by…": tomorrow at 8am.
    public static func defaultCustomDate(now: Date, calendar: Calendar) -> Date {
        date(for: .tomorrow, now: now, calendar: calendar)
    }

    /// Compact label such as "Fri, 6pm", "Sat, 8am", or "Dec 4, 8am".
    public static func shortLabel(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let minute = calendar.component(.minute, from: date)
        let timeStyle: Date.FormatStyle = {
            let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return minute == 0 ? base.hour(.defaultDigits(amPM: .abbreviated)) : base.hour().minute()
        }()
        let timeText = date.formatted(timeStyle)
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        let startOfToday = calendar.startOfDay(for: now)
        let withinWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)
        let dayStyle = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let dayText: String
        if let withinWeek, date < withinWeek {
            dayText = date.formatted(dayStyle.weekday(.abbreviated))
        } else {
            dayText = date.formatted(dayStyle.month(.abbreviated).day())
        }
        return "\(dayText), \(timeText)"
    }
}
