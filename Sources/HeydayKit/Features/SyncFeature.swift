import Foundation
import os

/// Keeps this Mac and the account in line, so that every Mac signed in to the
/// account shows the same.
///
/// One round trip reads what the account holds, merges it with what this Mac holds,
/// hands anything new to the features that keep it here, and writes the merged copy
/// back if the account lacks any of it. Nothing is ever taken from either side:
/// both end up with everything, and where they disagree, with the later choice.
public struct SyncFeature: Feature {
    public enum Status: Equatable, Sendable {
        /// Nothing has been tried yet.
        case waiting
        case running
        /// The account and this Mac held the same, as of this moment.
        case upToDate(Date)
        case failed(MailError)
    }

    public struct State: Equatable, Sendable {
        public var status: Status = .waiting
        /// What this Mac held when the round trip under way began, with what the
        /// account has added to it since.
        var local = SyncedState(rules: nil, folders: nil)
        /// What this Mac holds now, when that changed during a round trip. It goes
        /// round again once the one under way is done.
        var pending: SyncedState?

        public init() {}
    }

    public enum Event: Sendable {
        /// Bring the two into line. Carries what this Mac holds now.
        case requested(SyncedState)
        /// - Parameter remote: nil when the account holds nothing yet.
        case pulled(Result<SyncedState?, MailError>, at: Date)
        case pushed(MailError?, at: Date)
    }

    public enum Effect: Equatable, Sendable {
        case pull
        /// Hand what other Macs changed to the features that keep it on this one.
        case adopt(SyncedState)
        case push(SyncedState)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .requested(let local):
            guard state.status != .running else {
                state.pending = local
                return []
            }
            state.local = local
            state.status = .running
            return [.pull]

        case .pulled(.success(let remote), let time):
            guard state.status == .running else { return [] }
            let merged = remote.map(state.local.merged) ?? state.local
            var effects: [Effect] = []
            if merged != state.local {
                state.local = merged
                effects.append(.adopt(merged))
            }
            // The account lacks something this Mac has: write the merged copy back.
            guard merged == remote else { return effects + [.push(merged)] }
            return effects + finish(&state, at: time)

        case .pulled(.failure(let error), _):
            return fail(&state, error)

        case .pushed(nil, let time):
            guard state.status == .running else { return [] }
            return finish(&state, at: time)

        case .pushed(let error?, _):
            return fail(&state, error)
        }
    }

    private func finish(_ state: inout State, at time: Date) -> [Effect] {
        guard let pending = state.pending else {
            state.status = .upToDate(time)
            return []
        }
        // Something changed here meanwhile. Go round again with it, keeping what
        // the account added on the way.
        state.pending = nil
        state.local = state.local.merged(with: pending)
        return [.pull]
    }

    private func fail(_ state: inout State, _ error: MailError) -> [Effect] {
        guard state.status == .running else { return [] }
        // The next request carries whatever this Mac holds by then.
        state.pending = nil
        state.status = .failed(error)
        return []
    }

    /// What each round trip did, for telling why two Macs differ. In Console, or
    /// `log show --predicate 'subsystem == "app.heyday.mac"' --info`. Says nothing
    /// of who the decisions are about.
    private static let log = Logger(subsystem: "app.heyday.mac", category: "sync")

    /// - Parameter adopt: hands what other Macs changed to the features that keep it here.
    public static func effects(
        store: MailDocumentStore<SyncedState>,
        now: @escaping @Sendable () -> Date = { Date() },
        adopt: @escaping @Sendable (SyncedState) async -> Void
    ) -> EffectRunner<SyncFeature> {
        { effect, send in
            switch effect {
            case .pull:
                let pulled = await outcome { () throws(MailError) in try await store.load() }
                switch pulled {
                case .success(nil): log.info("Read the account: nothing kept there yet")
                case .success(let remote?): log.info("Read the account: \(remote.rules?.decisions.count ?? 0, privacy: .public) decisions")
                case .failure(let error): log.error("Could not read the account: \(error.userMessage, privacy: .public)")
                }
                await send(.pulled(pulled, at: now()))
            case .adopt(let state):
                log.info("Took in what other Macs changed: now \(state.rules?.decisions.count ?? 0, privacy: .public) decisions")
                await adopt(state)
            case .push(let state):
                do throws(MailError) {
                    try await store.save(state)
                    log.info("Wrote this Mac's copy to the account: \(state.rules?.decisions.count ?? 0, privacy: .public) decisions")
                    await send(.pushed(nil, at: now()))
                } catch {
                    log.error("Could not write to the account: \(error.userMessage, privacy: .public)")
                    await send(.pushed(error, at: now()))
                }
            }
        }
    }
}
