import Foundation

/// Something the person just did to their mail that can be taken back.
public enum MailAction: Equatable, Sendable {
    /// Mail was moved into a mailbox.
    case moved([MovedMessage], to: String)
    /// A sender was given a place, or screened out.
    /// - Parameters:
    ///   - previously: what had been decided about them before, if anything.
    ///   - markedRead: their mail that the answer marked read. Screening a sender out
    ///     does that to whatever of theirs was unread; taking the answer back makes it
    ///     unread again.
    case senderDecided(EmailAddress, SenderDecision, previously: SenderDecision?, markedRead: [MessageSummary.ID])
    /// A conversation's Bubble Up schedule was set, changed, or dismissed.
    case bubbleUpChanged(Conversation.ID, subject: String, BubbleUp?, previously: BubbleUp?)

    /// Whether everything needed to take it back is known. Moved mail is found
    /// again by its Message-ID, and the odd message has none.
    public var canBeTakenBack: Bool {
        switch self {
        case .moved(let messages, _): !messages.isEmpty && messages.allSatisfy { $0.messageID != nil }
        case .senderDecided, .bubbleUpChanged: true
        }
    }
}

/// A message that was moved: where it was, and the Message-ID it is known by
/// wherever it goes. A move gives it a new number, so the old one finds nothing.
public struct MovedMessage: Equatable, Sendable {
    public let messageID: String?
    /// The mailbox it was moved out of.
    public let source: String

    public init(messageID: String?, source: String) {
        self.messageID = messageID
        self.source = source
    }
}

/// The last thing done to the mail, and the chance to take it back.
///
/// Each action is on offer for a short while, and the next one replaces it. Taking
/// one back is a request to the server, so it can be under way and it can fail;
/// both are said in the same place the offer was. Actions are taken back one at a
/// time, in the order asked: the second of two often undoes what the first has to
/// find in place.
public struct RecentActionFeature: Feature {
    public struct Notice: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// Just done, and can still be taken back from here.
            case done(MailAction)
            case takingBack(MailAction)
            case notTakenBack(MailError)
        }

        /// Which notice this is, counting from one: a timer set for one notice
        /// must not clear the next.
        public let id: Int
        public let kind: Kind
    }

    public struct State: Equatable, Sendable {
        /// What there is to say about the last action. Nil when there is nothing.
        public fileprivate(set) var notice: Notice?
        fileprivate var noticesShown = 0
        /// The action being taken back, and those waiting their turn behind it.
        fileprivate var takingBack: [MailAction] = []

        public init() {}
    }

    public enum Event: Sendable {
        case performed(MailAction)
        /// The person asked for an action to be taken back: the one on offer, or an
        /// earlier one through the system's own Undo.
        case undoRequested(MailAction)
        /// - Parameter error: why it could not be taken back, or nil when it was.
        case undoFinished(MailError?)
        /// A notice has been up for as long as notices stay.
        case expired(Notice.ID)
        /// The person put the notice away.
        case dismissed
    }

    public enum Effect: Equatable, Sendable {
        case expire(Notice.ID)
        case takeBack(MailAction)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .performed(let action):
            return [.expire(show(.done(action), in: &state))]

        case .undoRequested(let action):
            guard action.canBeTakenBack else { return [] }
            state.takingBack.append(action)
            guard state.takingBack.count == 1 else { return [] }
            return [begin(action, in: &state)]

        case .undoFinished(nil):
            guard !state.takingBack.isEmpty else { return [] }
            state.takingBack.removeFirst()
            if let next = state.takingBack.first { return [begin(next, in: &state)] }
            if case .takingBack = state.notice?.kind { state.notice = nil }
            return []

        case .undoFinished(let error?):
            // What waited behind it expected it to have worked, so it is not tried.
            state.takingBack = []
            return [.expire(show(.notTakenBack(error), in: &state))]

        case .expired(let id):
            if state.notice?.id == id { state.notice = nil }
            return []

        case .dismissed:
            // A request to the server cannot be waved away; its outcome is still owed.
            if case .takingBack = state.notice?.kind { return [] }
            state.notice = nil
            return []
        }
    }

    /// Starts taking an action back. Its notice has no timer: it stays until the
    /// server has answered.
    private func begin(_ action: MailAction, in state: inout State) -> Effect {
        _ = show(.takingBack(action), in: &state)
        return .takeBack(action)
    }

    /// Puts a notice up in place of whatever was there, and returns its id.
    private func show(_ kind: Notice.Kind, in state: inout State) -> Notice.ID {
        state.noticesShown += 1
        state.notice = Notice(id: state.noticesShown, kind: kind)
        return state.noticesShown
    }

    /// - Parameters:
    ///   - lifetime: how long a notice stays up.
    ///   - takeBack: undoes an action, and returns why it could not if it could not.
    public static func effects(
        lifetime: Duration,
        takeBack: @escaping @Sendable (MailAction) async -> MailError?
    ) -> EffectRunner<RecentActionFeature> {
        { effect, send in
            switch effect {
            case .expire(let id):
                // Cancelled with the store, in which case there is no notice left to clear.
                guard (try? await Task.sleep(for: lifetime)) != nil else { return }
                await send(.expired(id))
            case .takeBack(let action):
                await send(.undoFinished(await takeBack(action)))
            }
        }
    }
}
