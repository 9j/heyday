import Foundation

/// Which senders and conversations the person asked to be told about, loaded from
/// and saved to this Mac, and joined with what other devices chose when that is
/// read from the account.
public struct NotificationsFeature: Feature {
    public struct State: Equatable, Sendable {
        /// Nil until loaded. Nothing is announced before then.
        public var rules: NotificationRules?
        /// Why the choices could not be read or written, until it has been seen.
        public var storageProblem: String?

        public init() {}
    }

    public enum Event: Sendable {
        case loadRequested
        case loaded(NotificationRules?)
        case senderSwitched(EmailAddress, isOn: Bool, at: Date)
        case conversationSwitched(Conversation.ID, isOn: Bool, at: Date)
        /// The person turned notifications off for every conversation at once.
        case conversationsSilenced(at: Date)
        /// What another device chose has been read from the account.
        case remoteArrived(NotificationRules)
        case storageFailed(String)
        case storageProblemDismissed
    }

    public enum Effect: Equatable, Sendable {
        case load
        case save(NotificationRules)
        /// Ask the system for leave to show notifications. It asks the person once,
        /// and the moment they turn one on is when the question makes sense.
        case askToNotify
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .loadRequested:
            return state.rules == nil ? [.load] : []

        case .loaded(let saved):
            state.rules = saved ?? NotificationRules()
            return []

        case .senderSwitched(let sender, let isOn, let time):
            return change(&state, asking: isOn) { $0.setNotifying(isOn, about: sender, at: time) }

        case .conversationSwitched(let id, let isOn, let time):
            return change(&state, asking: isOn) { $0.setNotifying(isOn, aboutConversation: id, at: time) }

        case .conversationsSilenced(let time):
            return change(&state, asking: false) { $0.silenceConversations(at: time) }

        case .remoteArrived(let remote):
            guard let rules = state.rules else { return [] }
            let merged = rules.merged(with: remote)
            guard merged != rules else { return [] }
            state.rules = merged
            return [.save(merged)]

        case .storageFailed(let message):
            state.storageProblem = message
            return []

        case .storageProblemDismissed:
            state.storageProblem = nil
            return []
        }
    }

    private func change(_ state: inout State, asking: Bool, _ apply: (inout NotificationRules) -> Void) -> [Effect] {
        guard var rules = state.rules else { return [] }
        apply(&rules)
        guard rules != state.rules else { return [] }
        state.rules = rules
        return [.save(rules)] + (asking ? [.askToNotify] : [])
    }

    /// - Parameter askToNotify: asks the system for leave to show notifications.
    public static func effects(
        store: JSONFileStore<NotificationRules>,
        askToNotify: @escaping @Sendable () async -> Void
    ) -> EffectRunner<NotificationsFeature> {
        { effect, send in
            switch effect {
            case .load:
                do throws(StorageError) {
                    await send(.loaded(try store.load()))
                } catch {
                    // Unreadable choices are reported and then treated as none: the app is quiet.
                    await send(.storageFailed(error.message))
                    await send(.loaded(nil))
                }
            case .save(let rules):
                do throws(StorageError) {
                    try store.save(rules)
                } catch {
                    await send(.storageFailed(error.message))
                }
            case .askToNotify:
                await askToNotify()
            }
        }
    }
}
