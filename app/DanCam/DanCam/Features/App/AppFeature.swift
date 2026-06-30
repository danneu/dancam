import Foundation

enum AppFeature {
    struct State: Equatable {
        var link: Link = .connecting
        var recording: RecordingFeature.State = .unknown
        var clips = ClipsFeature.State()
        var streamReconnectAttempt = 0
    }

    enum Action: Equatable {
        case streamStarted
        case streamStopped
        case event(CameraEvent)
        case streamFailed
        case streamReconnect
        case heartbeatTimedOut
        case recording(RecordingFeature.Action)
        case clips(ClipsFeature.Action)
        case recordTapped
        case manualRefresh
    }

    private static let streamID = "events-stream"
    private static let heartbeatID = "events-heartbeat"
    private static let reconnectID = "events-reconnect"

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .streamStarted:
            if case .offline = state.link {
                // Preserve the offline -> online recovery edge until the next snapshot.
            } else if state.link.onlineWorld == nil {
                state.link = .connecting
            }

            return .merge([
                .cancel(id: reconnectID),
                streamEffect(dependencies: dependencies),
                armHeartbeat(dependencies: dependencies),
            ])

        case .streamStopped:
            state.streamReconnectAttempt = 0
            return .merge([
                .cancel(id: streamID),
                .cancel(id: heartbeatID),
                .cancel(id: reconnectID),
            ])

        case .event(let event):
            let previousPhase = state.link.world?.recorder.phase
            var effects = [armHeartbeat(dependencies: dependencies)]

            state.link.fold(event)

            if case .snapshot = event {
                state.streamReconnectAttempt = 0
                effects.append(
                    ClipsFeature.reduce(
                        state: &state.clips,
                        action: .load,
                        dependencies: dependencies
                    )
                    .map(Action.clips)
                )
            }

            if case .clipFinalized(let clip) = event {
                effects.append(
                    ClipsFeature.reduce(
                        state: &state.clips,
                        action: .clipFinalized(clip),
                        dependencies: dependencies
                    )
                    .map(Action.clips)
                )
            }

            if let phase = state.link.world?.recorder.phase,
               phase != previousPhase {
                effects.append(
                    reduceRecording(
                        state: &state,
                        action: .recorderPhaseObserved(phase),
                        dependencies: dependencies
                    )
                )
            }

            return .merge(effects)

        case .streamFailed:
            state.link.wentOffline()
            state.streamReconnectAttempt += 1
            return .merge([
                .cancel(id: heartbeatID),
                scheduleReconnect(
                    attempt: state.streamReconnectAttempt,
                    dependencies: dependencies
                ),
            ])

        case .heartbeatTimedOut:
            state.link.wentOffline()
            state.streamReconnectAttempt += 1
            return .merge([
                .cancel(id: streamID),
                .cancel(id: heartbeatID),
                scheduleReconnect(
                    attempt: state.streamReconnectAttempt,
                    dependencies: dependencies
                ),
            ])

        case .streamReconnect:
            return .merge([
                streamEffect(dependencies: dependencies),
                armHeartbeat(dependencies: dependencies),
            ])

        case .recording(let action):
            return reduceRecording(
                state: &state,
                action: action,
                dependencies: dependencies
            )

        case .clips(let action):
            return ClipsFeature.reduce(
                state: &state.clips,
                action: action,
                dependencies: dependencies
            )
            .map(Action.clips)

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
            return ClipsFeature.reduce(
                state: &state.clips,
                action: .refresh,
                dependencies: dependencies
            )
            .map(Action.clips)
        }
    }

    private static func reduceRecording(
        state: inout State,
        action: RecordingFeature.Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        RecordingFeature.reduce(
            state: &state.recording,
            action: action,
            dependencies: dependencies
        )
        .map(Action.recording)
    }

    private static func streamEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: streamID, cancelInFlight: true) { send in
            do {
                for try await event in dependencies.events.connect() {
                    guard Task.isCancelled == false else { return }
                    await send(.event(event))
                }

                guard Task.isCancelled == false else { return }
                await send(.streamFailed)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                await send(.streamFailed)
            }
        }
    }

    private static func armHeartbeat(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: heartbeatID, cancelInFlight: true) { send in
            do {
                try await dependencies.heartbeatTimeout()
                guard Task.isCancelled == false else { return }
                await send(.heartbeatTimedOut)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                await send(.heartbeatTimedOut)
            }
        }
    }

    private static func scheduleReconnect(
        attempt: Int,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: reconnectID, cancelInFlight: true) { send in
            await dependencies.sleep(reconnectDelay(for: attempt))
            guard Task.isCancelled == false else { return }
            await send(.streamReconnect)
        }
    }

    private static func reconnectDelay(for attempt: Int) -> Duration {
        switch attempt {
        case 0, 1:
            .seconds(1)
        case 2:
            .seconds(2)
        default:
            .seconds(4)
        }
    }
}

typealias AppStore = Store<AppFeature.State, AppFeature.Action, AppDependencies>
