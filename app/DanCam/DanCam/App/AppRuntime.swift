import OSLog

@MainActor
final class AppRuntime {
    let dependencies: AppDependencies
    let store: AppStore

    private var activeSceneIDs: Set<String> = []

    init(
        dependencies: AppDependencies = .live,
        onAction: ((AppFeature.Action) -> Void)? = nil,
        logsTransitions: Bool = true
    ) {
        self.dependencies = dependencies
        store = AppStore(
            initialState: AppFeature.State(),
            dependencies: dependencies,
            reduce: { state, action, dependencies in
                onAction?(action)
                return AppFeature.reduce(
                    state: &state,
                    action: action,
                    dependencies: dependencies
                )
            },
            log: logsTransitions ? { action, oldState, newState in
                AppFeature.logTransition(action, oldState, newState)
            } : nil
        )
        Log.reducer.notice("snapshot \(self.store.state.logSnapshot, privacy: .public)")
    }

    func activateScene(id: String) {
        let wasEmpty = activeSceneIDs.isEmpty
        guard activeSceneIDs.insert(id).inserted, wasEmpty else { return }

        store.send(.streamStarted)
        store.send(.foregrounded)
    }

    func deactivateScene(id: String) {
        guard activeSceneIDs.remove(id) != nil, activeSceneIDs.isEmpty else { return }

        store.send(.backgrounded)
        store.send(.streamStopped)
    }
}
