import HeydayKit
import SwiftUI

/// What was just done to the mail, floating over the bottom of the window for a few
/// seconds with the way to take it back: where the mail went, or who was answered
/// about, as a symbol and a name.
struct RecentActionToast: View {
    let workspace: Workspace
    /// Takes back the action a notice is about.
    let onUndo: (RecentActionFeature.Notice, MailAction) -> Void

    private var store: Store<RecentActionFeature> { workspace.recentAction }

    var body: some View {
        ZStack {
            if let notice = store.state.notice {
                content(of: notice)
                    .font(.subheadline)
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .frame(minHeight: 40)
                    .floatingSurface(in: Capsule())
                    // Flicked down, it goes without waiting for its time.
                    .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                        if drag.translation.height > 8 { store.send(.dismissed) }
                    })
                    .id(notice.id)
                    .transition(.settle)
            }
        }
        .motion(Motion.arrival, value: store.state.notice?.id)
        .sensoryFeedback(trigger: store.state.notice) { _, notice in
            switch notice?.kind {
            case .done: .impact(weight: .light)
            case .notTakenBack: .error
            case .takingBack, nil: nil
            }
        }
    }

    @ViewBuilder
    private func content(of notice: RecentActionFeature.Notice) -> some View {
        switch notice.kind {
        case .done(let action):
            let presentation = workspace.presentation(of: action)
            HStack(spacing: 12) {
                Label(presentation.title, systemImage: presentation.symbol)
                    .lineLimit(1)
                    .accessibilityLabel(presentation.spoken)
                if action.canBeTakenBack {
                    Button("Undo") { onUndo(notice, action) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .fontWeight(.semibold)
                } else {
                    // Keeps the name off the capsule's end where there is no button.
                    Spacer().frame(width: 8)
                }
            }
        case .takingBack:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Undoing…")
                Spacer().frame(width: 8)
            }
        case .notTakenBack(let error):
            HStack(spacing: 8) {
                Label("Couldn’t Undo", systemImage: "exclamationmark.triangle.fill")
                    .help(error.userMessage)
                    .accessibilityLabel("Couldn’t undo. \(error.userMessage)")
                Spacer().frame(width: 8)
            }
        }
    }
}

/// The mail actions on the system's Undo stack (the Edit menu's Undo, a shake).
///
/// Each is registered under a target of its own, so that one taken back from its
/// notice can be taken off the stack as well and is not offered a second time. The
/// undo manager does not keep its targets alive, so they are kept here, and are
/// all withdrawn when the window they belong to goes.
@MainActor
final class UndoEntries {
    private final class Target {}

    private var targets: [RecentActionFeature.Notice.ID: Target] = [:]

    func register(
        _ notice: RecentActionFeature.Notice,
        named name: String,
        with undoManager: UndoManager?,
        undo: @escaping @MainActor () -> Void
    ) {
        guard let undoManager, targets[notice.id] == nil else { return }
        let target = Target()
        targets[notice.id] = target
        undoManager.registerUndo(withTarget: target) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.targets[notice.id] = nil
                undo()
            }
        }
        undoManager.setActionName(name)
    }

    /// Takes one action off the stack, as when it has been taken back another way.
    func withdraw(_ notice: RecentActionFeature.Notice, from undoManager: UndoManager?) {
        guard let target = targets.removeValue(forKey: notice.id) else { return }
        undoManager?.removeAllActions(withTarget: target)
    }

    func withdrawAll(from undoManager: UndoManager?) {
        for target in targets.values {
            undoManager?.removeAllActions(withTarget: target)
        }
        targets = [:]
    }
}

/// How an action is named: on its notice, to a screen reader, and after "Undo" in
/// the Edit menu.
struct ActionPresentation {
    let title: String
    let symbol: String
    let spoken: String
    let undoName: String
}

extension Workspace {
    /// A move is named for where the mail went; a decision about a sender for the
    /// sender, with the symbol of where their mail goes now.
    func presentation(of action: MailAction) -> ActionPresentation {
        switch action {
        case .moved(_, let destination):
            let place = place(at: destination)
            return ActionPresentation(title: place.title, symbol: place.symbol, spoken: "Moved to \(place.title)", undoName: "Move to \(place.title)")
        case .senderDecided(let sender, let decision, _, _):
            let listing: Listing = switch decision {
            case .approved(let box): .box(box)
            case .screenedOut: .screenedOut
            }
            let place = ListingPresentation(listing, directory: directory)
            return ActionPresentation(
                title: sender.displayName,
                symbol: place.symbol,
                spoken: "\(sender.displayName): \(place.title)",
                undoName: "\(place.title) for \(sender.displayName)"
            )
        case .bubbleUpChanged(_, _, let updated, _):
            guard let updated else {
                return ActionPresentation(
                    title: "Bubble Up Dismissed",
                    symbol: "bubbles.and.sparkles",
                    spoken: "Bubble Up dismissed",
                    undoName: "Dismiss Bubble Up"
                )
            }
            let now = Date()
            if updated.dueAt <= now.addingTimeInterval(5) {
                return ActionPresentation(
                    title: "Bubbled up!",
                    symbol: "bubbles.and.sparkles",
                    spoken: "Bubbled up to Mebox",
                    undoName: "Bubble Up"
                )
            }
            let when = BubbleUpSchedule.shortLabel(for: updated.dueAt, now: now, calendar: .current, locale: .current)
            let prefix = updated.condition == .ifNoReply ? "If no reply by" : "Bubble Up"
            return ActionPresentation(
                title: "\(prefix) \(when)",
                symbol: updated.condition == .ifNoReply ? "hourglass" : "bubbles.and.sparkles",
                spoken: "Scheduled Bubble Up for \(when)",
                undoName: "Bubble Up"
            )
        }
    }

    /// The name and symbol of a mailbox as the app shows it: its own name for
    /// Reply Later and Set Aside, the server's for the rest.
    private func place(at path: String) -> (title: String, symbol: String) {
        if let folder = MailboxDirectory.AppFolder.allCases.first(where: { isSetUp($0) && folderPath($0) == path }) {
            let presentation = ListingPresentation(.appFolder(folder), directory: directory)
            return (presentation.title, presentation.symbol)
        }
        if path == directory.inbox { return ("Inbox", "tray") }
        let presentation = ListingPresentation(.mailbox(path: path), directory: directory)
        return (presentation.title, presentation.symbol)
    }
}
