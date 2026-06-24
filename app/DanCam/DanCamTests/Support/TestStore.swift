import Testing
@testable import DanCam

@MainActor
final class TestStore<State: Equatable, Action: Equatable, Dependencies> {
    typealias Reducer = (inout State, Action, Dependencies) -> Effect<Action>

    private(set) var state: State

    private let dependencies: Dependencies
    private let reduce: Reducer
    private var receivedActions: [Action] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextTaskToken: UInt64 = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var taskIDs: [AnyHashable: UInt64] = [:]

    init(initialState: State, dependencies: Dependencies, reduce: @escaping Reducer) {
        state = initialState
        self.dependencies = dependencies
        self.reduce = reduce
    }

    func send(
        _ action: Action,
        assert updateExpectedState: (inout State) -> Void = { _ in },
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var expectedState = state
        let effect = reduce(&state, action, dependencies)
        updateExpectedState(&expectedState)
        #expect(state == expectedState, sourceLocation: sourceLocation)
        execute(effect)
    }

    func receive(
        _ expectedAction: Action,
        assert updateExpectedState: (inout State) -> Void = { _ in },
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let action = await nextAction()
        #expect(action == expectedAction, sourceLocation: sourceLocation)

        var expectedState = state
        let effect = reduce(&state, action, dependencies)
        updateExpectedState(&expectedState)
        #expect(state == expectedState, sourceLocation: sourceLocation)
        execute(effect)
    }

    func finishEffects() async {
        while tasks.isEmpty == false {
            let currentTasks = Array(tasks.values)
            for task in currentTasks {
                await task.value
            }
        }
    }

    func expectNoReceivedActions(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(receivedActions.isEmpty, sourceLocation: sourceLocation)
    }

    private func nextAction() async -> Action {
        while true {
            if receivedActions.isEmpty == false {
                return receivedActions.removeFirst()
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private func enqueue(_ action: Action) {
        receivedActions.append(action)

        if waiters.isEmpty == false {
            waiters.removeFirst().resume()
        }
    }

    private func execute(_ effect: Effect<Action>) {
        switch effect {
        case .none:
            return
        case .cancel(let id):
            cancelTask(id: id)
        case .run(let id, let cancelInFlight, let operation):
            if let id, cancelInFlight {
                cancelTask(id: id)
            }

            let token = nextTaskToken
            nextTaskToken += 1

            let task = Task { [weak self] in
                let send: (Action) async -> Void = { [weak self] action in
                    guard Task.isCancelled == false else { return }
                    self?.enqueue(action)
                }

                await operation(send)
                self?.finishTask(token: token, id: id)
            }

            tasks[token] = task
            if let id {
                taskIDs[id] = token
            }
        }
    }

    private func cancelTask(id: AnyHashable) {
        guard let token = taskIDs.removeValue(forKey: id) else { return }
        tasks.removeValue(forKey: token)?.cancel()
    }

    private func finishTask(token: UInt64, id: AnyHashable?) {
        tasks.removeValue(forKey: token)

        if let id, taskIDs[id] == token {
            taskIDs.removeValue(forKey: id)
        }
    }
}
