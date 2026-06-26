enum Effect<Action> {
    case none
    case merge([Effect<Action>])
    case run(
        id: AnyHashable? = nil,
        cancelInFlight: Bool = false,
        operation: (_ send: (Action) async -> Void) async -> Void
    )
    case cancel(id: AnyHashable)

    func map<T>(_ transform: @escaping (Action) -> T) -> Effect<T> {
        switch self {
        case .none:
            return .none
        case .merge(let effects):
            return .merge(effects.map { $0.map(transform) })
        case .run(let id, let cancelInFlight, let operation):
            return .run(id: id, cancelInFlight: cancelInFlight) { send in
                await operation { action in
                    await send(transform(action))
                }
            }
        case .cancel(let id):
            return .cancel(id: id)
        }
    }
}
