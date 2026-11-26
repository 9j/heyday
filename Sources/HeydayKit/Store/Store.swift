import Observation

/// A feature's state machine: every change to `State` happens in `reduce`, in response
/// to a named `Event`. `reduce` does no I/O. Anything that touches the network, the
/// clock or the keychain is described as an `Effect` and returned for the store to run.
public protocol Feature: Sendable {
    associatedtype State: Sendable
    associatedtype Event: Sendable
    associatedtype Effect: Sendable

    func reduce(_ state: inout State, _ event: Event) -> [Effect]
}

/// Runs a feature's effects. An effect reports back by sending events, as many as it
/// needs: one for a request, a stream of them for a live subscription.
public typealias EffectRunner<F: Feature> =
    @Sendable (F.Effect, _ send: @escaping @Sendable (F.Event) async -> Void) async -> Void

/// Holds a feature's state on the main actor and is the only thing that mutates it.
///
/// Views read `state` and call `send`. Effects started by an event run as child tasks
/// that the store owns; they are cancelled when the store is deallocated, so a screen
/// that goes away takes its in-flight requests with it.
@MainActor
@Observable
public final class Store<F: Feature> {
    public private(set) var state: F.State

    private let feature: F
    private let runEffect: EffectRunner<F>
    private let tasks = TaskBag()

    public init(initialState: F.State, feature: F, runEffect: @escaping EffectRunner<F>) {
        self.state = initialState
        self.feature = feature
        self.runEffect = runEffect
    }

    public func send(_ event: F.Event) {
        let effects = feature.reduce(&state, event)
        guard !effects.isEmpty else { return }
        let runEffect = runEffect
        // Weak, so an effect that outlives its screen cannot keep the store alive.
        let sendBack: @Sendable (F.Event) async -> Void = { [weak self] event in
            await self?.send(event)
        }
        for effect in effects {
            tasks.add { await runEffect(effect, sendBack) }
        }
    }

    /// Returns once the state passes a test: at once if it already does, otherwise
    /// after the change that makes it so. For a caller that has to wait out
    /// something it started, as a pull to refresh waits for the reload.
    ///
    /// It waits for as long as that takes, so the test must be one that some
    /// event is sure to satisfy.
    public func state(where isMet: (F.State) -> Bool) async {
        while !isMet(state) {
            await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = state
                } onChange: {
                    changed.resume()
                }
            }
        }
    }
}

/// Owns the tasks a store has started and cancels whatever is still running when the
/// store goes away.
@MainActor
private final class TaskBag {
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextID = 0

    func add(_ operation: @escaping @Sendable () async -> Void) {
        let id = nextID
        nextID += 1
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }
}
