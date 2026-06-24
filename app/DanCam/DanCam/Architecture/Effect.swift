enum Effect<Action> {
    case none
    case run(
        id: AnyHashable? = nil,
        cancelInFlight: Bool = false,
        operation: (_ send: (Action) async -> Void) async -> Void
    )
    case cancel(id: AnyHashable)
}
