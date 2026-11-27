import Foundation

/// Last-visit watermarks for Paper Trail and The Feed, loaded from and saved to
/// this Mac, and merged with other devices through the account (`SyncedState`).
public struct BoxVisitsFeature: Feature {
    public struct State: Equatable, Sendable {
        /// Nil until loaded from disk.
        public var visits: BoxVisits?
        /// Why the visit times could not be read or written, until dismissed.
        public var storageProblem: String?

        public init() {}
    }

    public enum Event: Sendable {
        case loadRequested
        case loaded(BoxVisits?)
        case visited(Destination, at: Date)
        /// What another device recorded has been read from the account.
        case remoteArrived(BoxVisits)
        case storageFailed(String)
        case storageProblemDismissed
    }

    public enum Effect: Equatable, Sendable {
        case load
        case save(BoxVisits)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .loadRequested:
            return state.visits == nil ? [.load] : []

        case .loaded(let saved):
            state.visits = saved ?? BoxVisits()
            return []

        case .visited(let destination, let time):
            guard var visits = state.visits else { return [] }
            visits.markVisited(destination, at: time)
            guard visits != state.visits else { return [] }
            state.visits = visits
            return [.save(visits)]

        case .remoteArrived(let remote):
            guard let visits = state.visits else { return [] }
            let merged = visits.merged(with: remote)
            guard merged != visits else { return [] }
            state.visits = merged
            return [.save(merged)]

        case .storageFailed(let message):
            state.storageProblem = message
            return []

        case .storageProblemDismissed:
            state.storageProblem = nil
            return []
        }
    }

    public static func effects(store: JSONFileStore<BoxVisits>) -> EffectRunner<BoxVisitsFeature> {
        { effect, send in
            switch effect {
            case .load:
                do throws(StorageError) {
                    await send(.loaded(try store.load()))
                } catch {
                    await send(.storageFailed(error.message))
                    await send(.loaded(nil))
                }
            case .save(let visits):
                do throws(StorageError) {
                    try store.save(visits)
                } catch {
                    await send(.storageFailed(error.message))
                }
            }
        }
    }
}
