import Foundation

@MainActor
struct StoreObservation {
    private let cancelHandler: () -> Void

    init(cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        cancelHandler()
    }
}

@MainActor
final class Store<State: Equatable, Action, Dependencies> {
    typealias Reducer = (inout State, Action, Dependencies) -> Effect<Action>

    private(set) var state: State

    private let dependencies: Dependencies
    private let reduce: Reducer
    private let log: ((Action, State, State) -> Void)?
    private var observers: [UInt64: (State) -> Void] = [:]
    private var nextObserverToken: UInt64 = 0
    private var nextTaskToken: UInt64 = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var taskIDs: [AnyHashable: UInt64] = [:]

    init(
        initialState: State,
        dependencies: Dependencies,
        reduce: @escaping Reducer,
        log: ((Action, State, State) -> Void)? = nil
    ) {
        state = initialState
        self.dependencies = dependencies
        self.reduce = reduce
        self.log = log
    }

    @discardableResult
    func observe(_ observer: @escaping (State) -> Void) -> StoreObservation {
        let token = nextObserverToken
        nextObserverToken += 1
        observers[token] = observer
        observer(state)

        return StoreObservation { [weak self] in
            self?.observers.removeValue(forKey: token)
        }
    }

    @discardableResult
    func observe<Value: Equatable>(
        select: @escaping (State) -> Value,
        _ observer: @escaping (Value) -> Void
    ) -> StoreObservation {
        var last: Value?
        return observe { state in
            let value = select(state)
            if let last, last == value { return }
            last = value
            observer(value)
        }
    }

    @discardableResult
    func observe<Value: Equatable>(
        _ keyPath: KeyPath<State, Value>,
        _ observer: @escaping (Value) -> Void
    ) -> StoreObservation {
        observe(select: { $0[keyPath: keyPath] }, observer)
    }

    func send(_ action: Action) {
        let old = state
        let effect = reduce(&state, action, dependencies)
        log?(action, old, state)

        if state != old {
            notifyObservers()
        }
        execute(effect)
    }

    private func notifyObservers() {
        for observer in Array(observers.values) {
            observer(state)
        }
    }

    private func execute(_ effect: Effect<Action>) {
        switch effect {
        case .none:
            return
        case .merge(let effects):
            for effect in effects {
                execute(effect)
            }
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
                    self?.send(action)
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
