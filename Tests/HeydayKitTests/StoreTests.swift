import Testing
@testable import HeydayKit

/// A feature small enough to show the store's contract: one event changes state
/// directly, another asks for an effect whose result comes back as a second event.
private struct Counter: Feature {
    struct State: Sendable, Equatable {
        var count = 0
        var isDoubling = false
    }

    enum Event: Sendable {
        case increment
        case doubleRequested
        case doubled(Int)
    }

    enum Effect: Sendable, Equatable {
        case double(Int)
    }

    func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .increment:
            state.count += 1
            return []
        case .doubleRequested:
            state.isDoubling = true
            return [.double(state.count)]
        case .doubled(let value):
            state.count = value
            state.isDoubling = false
            return []
        }
    }
}

@MainActor
@Suite struct StoreTests {
    @Test func eventsWithoutEffectsChangeStateSynchronously() {
        let store = Store(initialState: Counter.State(), feature: Counter()) { _, _ in }

        store.send(.increment)
        store.send(.increment)

        #expect(store.state == Counter.State(count: 2, isDoubling: false))
    }

    @Test func effectResultsComeBackAsEvents() async {
        let finished = AsyncStream<Void>.makeStream()
        let store = Store(initialState: Counter.State(count: 21), feature: Counter()) { effect, send in
            switch effect {
            case .double(let value):
                await send(.doubled(value * 2))
                finished.continuation.yield()
            }
        }

        store.send(.doubleRequested)
        #expect(store.state.isDoubling)

        for await _ in finished.stream { break }
        #expect(store.state == Counter.State(count: 42, isDoubling: false))
    }

    @Test func waitingForAStateReturnsOnceAnEventBringsIt() async {
        let store = Store(initialState: Counter.State(count: 21), feature: Counter()) { effect, send in
            switch effect {
            case .double(let value):
                await send(.doubled(value * 2))
            }
        }

        store.send(.doubleRequested)
        await store.state { !$0.isDoubling }

        #expect(store.state.count == 42)
    }

    @Test func waitingForAStateThatAlreadyHoldsReturnsAtOnce() async {
        let store = Store(initialState: Counter.State(count: 3), feature: Counter()) { _, _ in }

        await store.state { $0.count == 3 }

        #expect(store.state.count == 3)
    }

    @Test func deallocatingTheStoreCancelsRunningEffects() async {
        let cancelled = AsyncStream<Void>.makeStream()
        var store: Store<Counter>? = Store(initialState: Counter.State(), feature: Counter()) { _, _ in
            await withTaskCancellationHandler {
                // Parks until cancelled; never finishes on its own.
                try? await Task.sleep(for: .seconds(3600))
            } onCancel: {
                cancelled.continuation.yield()
            }
        }

        store?.send(.doubleRequested)
        store = nil

        for await _ in cancelled.stream { break }
    }
}
