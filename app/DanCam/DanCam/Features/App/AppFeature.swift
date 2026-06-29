enum AppFeature {
    struct State: Equatable {
        var connection = ConnectionFeature.State()
        var recording: RecordingFeature.State = .unknown
        var clips: ClipsFeature.State = .idle
        var pendingManualRefresh = false
    }

    enum Action: Equatable {
        case connection(ConnectionFeature.Action)
        case recording(RecordingFeature.Action)
        case clips(ClipsFeature.Action)
        case recordTapped
        case manualRefresh
    }

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .connection(let action):
            let previousRecording = state.connection.lastStatus?.recording
            let previousSegmentId = state.connection.lastStatus?.currentSegmentId
            let connectionEffect = ConnectionFeature.reduce(
                state: &state.connection,
                action: action,
                dependencies: dependencies
            )
            .map(Action.connection)
            var effects = [connectionEffect]

            if state.connection.lastStatus?.recording != previousRecording,
               let recording = state.connection.lastStatus?.recording {
                effects.append(
                    reduceRecording(
                        state: &state,
                        action: .statusObserved(recording: recording),
                        dependencies: dependencies
                    )
                )
            }

            if let currentSegmentId = state.connection.lastStatus?.currentSegmentId,
               currentSegmentId != previousSegmentId {
                effects.append(
                    ClipsFeature.reduce(
                        state: &state.clips,
                        action: .refresh,
                        dependencies: dependencies
                    )
                    .map(Action.clips)
                )
            }

            return effects.count == 1 ? connectionEffect : .merge(effects)

        case .recording(let action):
            return reduceRecording(
                state: &state,
                action: action,
                dependencies: dependencies
            )

        case .clips(let action):
            let clipsEffect = ClipsFeature.reduce(
                state: &state.clips,
                action: action,
                dependencies: dependencies
            )
            .map(Action.clips)

            if case .clipsResponse = action {
                state.pendingManualRefresh = false
            }

            return clipsEffect

        case .recordTapped:
            switch state.recording {
            case .recording:
                return reduceRecording(
                    state: &state,
                    action: .stopTapped,
                    dependencies: dependencies
                )
            case .unknown, .idle, .failed:
                return reduceRecording(
                    state: &state,
                    action: .startTapped,
                    dependencies: dependencies
                )
            case .starting, .stopping:
                return .none
            }

        case .manualRefresh:
            state.pendingManualRefresh = true
            return .merge([
                ClipsFeature.reduce(
                    state: &state.clips,
                    action: .refresh,
                    dependencies: dependencies
                )
                .map(Action.clips),
                ConnectionFeature.reduce(
                    state: &state.connection,
                    action: .poll,
                    dependencies: dependencies
                )
                .map(Action.connection),
            ])
        }
    }

    private static func reduceRecording(
        state: inout State,
        action: RecordingFeature.Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        let previous = state.recording
        let recordingEffect = RecordingFeature.reduce(
            state: &state.recording,
            action: action,
            dependencies: dependencies
        )
        .map(Action.recording)

        guard shouldRefreshClips(from: previous, to: state.recording) else {
            return recordingEffect
        }

        return .merge([
            recordingEffect,
            ClipsFeature.reduce(
                state: &state.clips,
                action: .refresh,
                dependencies: dependencies
            )
            .map(Action.clips),
        ])
    }

    private static func shouldRefreshClips(
        from previous: RecordingFeature.State,
        to next: RecordingFeature.State
    ) -> Bool {
        guard case .idle = next else { return false }

        switch previous {
        case .recording, .stopping:
            return true
        case .unknown, .idle, .starting, .failed:
            return false
        }
    }
}

typealias AppStore = Store<AppFeature.State, AppFeature.Action, AppDependencies>
