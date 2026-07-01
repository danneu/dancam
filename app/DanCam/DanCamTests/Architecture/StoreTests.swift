import Testing
@testable import DanCam

@MainActor
final class Signal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        isSignaled = true
        let currentWaiters = waiters
        waiters.removeAll()

        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()

        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

@MainActor
struct StoreTests {
    @Test func observeFiresWithNewStateAfterSend() {
        enum Action {
            case increment
        }

        var observedStates: [Int] = []
        let store = Store<Int, Action, Void>(initialState: 0, dependencies: ()) { state, action, _ in
            switch action {
            case .increment:
                state += 1
                return .none
            }
        }

        store.observe { state in
            observedStates.append(state)
        }

        store.send(.increment)

        #expect(observedStates == [0, 1])
    }

    @Test func logClosureReceivesActionOldStateAndNewStateOnSend() {
        enum Action: Equatable {
            case increment
        }

        struct LogEntry: Equatable {
            var action: Action
            var oldState: Int
            var newState: Int
        }

        var logEntries: [LogEntry] = []
        let store = Store<Int, Action, Void>(
            initialState: 0,
            dependencies: (),
            reduce: { state, action, _ in
                switch action {
                case .increment:
                    state += 1
                    return .none
                }
            },
            log: { action, oldState, newState in
                logEntries.append(LogEntry(
                    action: action,
                    oldState: oldState,
                    newState: newState
                ))
            }
        )

        store.send(.increment)

        #expect(logEntries == [
            LogEntry(action: .increment, oldState: 0, newState: 1),
        ])
    }

    @Test func defaultNilLogClosureLeavesSendBehaviorUnchanged() {
        enum Action {
            case increment
        }

        let store = Store<Int, Action, Void>(initialState: 0, dependencies: ()) { state, action, _ in
            switch action {
            case .increment:
                state += 1
                return .none
            }
        }

        store.send(.increment)

        #expect(store.state == 1)
    }

    @Test func unchangedStateDoesNotNotifyButStillExecutesEffect() async {
        enum Action {
            case start
            case finish
        }

        let finished = Signal()
        var observedStates: [Int] = []
        let store = Store<Int, Action, Void>(initialState: 0, dependencies: ()) { state, action, _ in
            switch action {
            case .start:
                return .run { send in
                    await send(.finish)
                }
            case .finish:
                state = 1
                return .none
            }
        }

        store.observe { state in
            observedStates.append(state)
            if state == 1 {
                finished.signal()
            }
        }

        store.send(.start)
        await finished.wait()

        #expect(observedStates == [0, 1])
    }

    @Test func scopedObserveFiresOnlyWhenSliceChanges() {
        struct State: Equatable {
            var count = 0
            var name = "initial"
        }

        enum Action {
            case increment
            case rename(String)
        }

        var observedCounts: [Int] = []
        let store = Store<State, Action, Void>(initialState: State(), dependencies: ()) { state, action, _ in
            switch action {
            case .increment:
                state.count += 1
            case .rename(let name):
                state.name = name
            }

            return .none
        }

        store.observe(\.count) { count in
            observedCounts.append(count)
        }

        store.send(.rename("changed"))
        store.send(.increment)

        #expect(observedCounts == [0, 1])
    }

    @Test func scopedObserveUpdatesLastBeforeInvokingObserver() {
        struct State: Equatable {
            var count = 0
            var name = "initial"
        }

        enum Action {
            case increment
            case rename(String)
        }

        var observedCounts: [Int] = []
        var store: Store<State, Action, Void>!
        store = Store<State, Action, Void>(initialState: State(), dependencies: ()) { state, action, _ in
            switch action {
            case .increment:
                state.count += 1
            case .rename(let name):
                state.name = name
            }

            return .none
        }

        store.observe(\.count) { count in
            observedCounts.append(count)

            if count == 0 {
                store.send(.rename("re-entered"))
            }
        }

        #expect(observedCounts == [0])
        #expect(store.state.name == "re-entered")

        store.send(.increment)

        #expect(observedCounts == [0, 1])
    }

    @Test func effectFedActionIsDeliveredBackAndApplied() async {
        enum Action {
            case start
            case finish
        }

        let finished = Signal()
        let store = Store<Int, Action, Void>(initialState: 0, dependencies: ()) { state, action, _ in
            switch action {
            case .start:
                state = 1
                return .run { send in
                    await send(.finish)
                }
            case .finish:
                state = 2
                return .none
            }
        }

        store.observe { state in
            if state == 2 {
                finished.signal()
            }
        }

        store.send(.start)
        await finished.wait()

        #expect(store.state == 2)
    }

    @Test func effectFedActionIsLoggedOnReentry() async {
        enum Action: Equatable {
            case start
            case finish
        }

        struct LogEntry: Equatable {
            var action: Action
            var oldState: Int
            var newState: Int
        }

        let finished = Signal()
        var logEntries: [LogEntry] = []
        let store = Store<Int, Action, Void>(
            initialState: 0,
            dependencies: (),
            reduce: { state, action, _ in
                switch action {
                case .start:
                    state = 1
                    return .run { send in
                        await send(.finish)
                    }
                case .finish:
                    state = 2
                    return .none
                }
            },
            log: { action, oldState, newState in
                logEntries.append(LogEntry(
                    action: action,
                    oldState: oldState,
                    newState: newState
                ))

                if action == .finish {
                    finished.signal()
                }
            }
        )

        store.send(.start)
        await finished.wait()

        #expect(logEntries == [
            LogEntry(action: .start, oldState: 0, newState: 1),
            LogEntry(action: .finish, oldState: 1, newState: 2),
        ])
    }

    @Test func mergeRunsBothMappedChildEffects() async {
        enum ChildAction {
            case append(String)
        }

        enum Action {
            case start
            case child(ChildAction)
        }

        let finished = Signal()
        let store = Store<[String], Action, Void>(initialState: [], dependencies: ()) { state, action, _ in
            switch action {
            case .start:
                func childEffect(_ value: String) -> Effect<ChildAction> {
                    .run { send in
                        await send(.append(value))
                    }
                }

                return .merge([
                    childEffect("first").map(Action.child),
                    childEffect("second").map(Action.child),
                ])

            case .child(.append(let value)):
                state.append(value)
                return .none
            }
        }

        store.observe { state in
            if state.count == 2 {
                finished.signal()
            }
        }

        store.send(.start)
        await finished.wait()

        #expect(Set(store.state) == Set(["first", "second"]))
    }

    @Test func immediateEffectChainIsAppliedInOrder() async {
        enum Action {
            case start
            case step1
            case step2
        }

        let finished = Signal()
        var observedStates: [[String]] = []
        let store = Store<[String], Action, Void>(initialState: [], dependencies: ()) { state, action, _ in
            switch action {
            case .start:
                state.append("start")
                return .run { send in
                    await send(.step1)
                }
            case .step1:
                state.append("step1")
                return .run { send in
                    await send(.step2)
                }
            case .step2:
                state.append("step2")
                return .none
            }
        }

        store.observe { state in
            observedStates.append(state)
            if state == ["start", "step1", "step2"] {
                finished.signal()
            }
        }

        store.send(.start)
        await finished.wait()

        #expect(observedStates == [
            [],
            ["start"],
            ["start", "step1"],
            ["start", "step1", "step2"],
        ])
    }

    @Test func cancelStopsInFlightEffectAction() async {
        enum Action {
            case start
            case cancel
            case finish
        }

        let started = Signal()
        let proceed = Gate()
        let attemptedSend = Signal()
        let store = Store<Int, Action, Void>(initialState: 0, dependencies: ()) { state, action, _ in
            switch action {
            case .start:
                state = 1
                return .run(id: "work") { send in
                    started.signal()
                    await proceed.wait()
                    await send(.finish)
                    attemptedSend.signal()
                }
            case .cancel:
                return .cancel(id: "work")
            case .finish:
                state = 2
                return .none
            }
        }

        store.send(.start)
        await started.wait()
        store.send(.cancel)
        proceed.open()
        await attemptedSend.wait()

        #expect(store.state == 1)
    }

    @Test func mappedCancellationStopsInFlightEffectAction() async {
        enum ChildAction {
            case finish
        }

        enum Action {
            case start
            case cancel
            case child(ChildAction)
        }

        let started = Signal()
        let proceed = Gate()
        let attemptedSend = Signal()
        let store = Store<Int, Action, Void>(initialState: 0, dependencies: ()) { state, action, _ in
            switch action {
            case .start:
                state = 1
                let effect: Effect<ChildAction> = .run(id: "mapped-work") { send in
                    started.signal()
                    await proceed.wait()
                    await send(.finish)
                    attemptedSend.signal()
                }
                return effect.map(Action.child)

            case .cancel:
                let effect: Effect<ChildAction> = .cancel(id: "mapped-work")
                return effect.map(Action.child)

            case .child(.finish):
                state = 2
                return .none
            }
        }

        store.send(.start)
        await started.wait()
        store.send(.cancel)
        proceed.open()
        await attemptedSend.wait()

        #expect(store.state == 1)
    }

    @Test func cancelInFlightStopsPriorEffectAction() async {
        enum Action {
            case start
            case finish(Int)
        }

        let firstStarted = Signal()
        let secondStarted = Signal()
        let firstProceed = Gate()
        let secondProceed = Gate()
        let firstAttemptedSend = Signal()
        let secondAttemptedSend = Signal()
        var runCount = 0

        let store = Store<Int, Action, Void>(initialState: 0, dependencies: ()) { state, action, _ in
            switch action {
            case .start:
                state += 1
                runCount += 1
                let runIndex = runCount
                return .run(id: "work", cancelInFlight: true) { send in
                    if runIndex == 1 {
                        firstStarted.signal()
                        await firstProceed.wait()
                        await send(.finish(1))
                        firstAttemptedSend.signal()
                    } else {
                        secondStarted.signal()
                        await secondProceed.wait()
                        await send(.finish(2))
                        secondAttemptedSend.signal()
                    }
                }
            case .finish(let index):
                state = 100 + index
                return .none
            }
        }

        store.send(.start)
        await firstStarted.wait()
        store.send(.start)
        await secondStarted.wait()

        firstProceed.open()
        await firstAttemptedSend.wait()
        #expect(store.state == 2)

        secondProceed.open()
        await secondAttemptedSend.wait()
        #expect(store.state == 102)
    }

    @Test func idlessRunTaskDoesNotRetainStore() async {
        enum Action {
            case start
            case finish
        }

        let proceed = Gate()
        weak var weakStore: Store<Int, Action, Void>?

        do {
            var store: Store<Int, Action, Void>? = Store(initialState: 0, dependencies: ()) { state, action, _ in
                switch action {
                case .start:
                    state = 1
                    return .run { send in
                        await proceed.wait()
                        await send(.finish)
                    }
                case .finish:
                    state = 2
                    return .none
                }
            }

            weakStore = store
            store?.send(.start)
            store = nil
        }

        #expect(weakStore == nil)
        proceed.open()
    }
}
