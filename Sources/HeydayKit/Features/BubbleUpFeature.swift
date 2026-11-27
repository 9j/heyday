import Foundation

/// Scheduled and active Bubble Up reminders, loaded from and saved to this Mac,
/// and synced with other devices via the account (`SyncedState`).
public struct BubbleUpFeature: Feature {
    public struct State: Equatable, Sendable {
        /// Nil until loaded from disk.
        public var rules: BubbleUpRules?
        /// Why Bubble Up reminders could not be read or written, until dismissed.
        public var storageProblem: String?

        public init() {}
    }

    public enum Event: Sendable {
        case loadRequested
        case loaded(BubbleUpRules?)
        case scheduled(Conversation.ID, BubbleUp, at: Date)
        case dismissed(Conversation.ID, at: Date)
        /// What another device scheduled or dismissed has been read from the account.
        case remoteArrived(BubbleUpRules)
        case storageFailed(String)
        case storageProblemDismissed
    }

    public enum Effect: Equatable, Sendable {
        case load
        case save(BubbleUpRules)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .loadRequested:
            return state.rules == nil ? [.load] : []

        case .loaded(let saved):
            state.rules = saved ?? BubbleUpRules()
            return []

        case .scheduled(let id, let bubbleUp, let time):
            guard var rules = state.rules else { return [] }
            rules.schedule(bubbleUp, for: id, at: time)
            guard rules != state.rules else { return [] }
            state.rules = rules
            return [.save(rules)]

        case .dismissed(let id, let time):
            guard var rules = state.rules, rules.bubbleUp(for: id) != nil else { return [] }
            rules.dismiss(for: id, at: time)
            state.rules = rules
            return [.save(rules)]

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

    public static func effects(store: JSONFileStore<BubbleUpRules>) -> EffectRunner<BubbleUpFeature> {
        { effect, send in
            switch effect {
            case .load:
                do throws(StorageError) {
                    await send(.loaded(try store.load()))
                } catch {
                    await send(.storageFailed(error.message))
                    await send(.loaded(nil))
                }
            case .save(let rules):
                do throws(StorageError) {
                    try store.save(rules)
                } catch {
                    await send(.storageFailed(error.message))
                }
            }
        }
    }
}
