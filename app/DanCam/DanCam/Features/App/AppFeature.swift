import Foundation
import OSLog

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
        case timeSyncResponded(success: Bool)
        case timeSyncRetry
    }

    private static let streamID = "events-stream"
    private static let heartbeatID = "events-heartbeat"
    private static let reconnectID = "events-reconnect"
    private static let timeSyncID = "time-sync"

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
                .cancel(id: timeSyncID),
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
                effects.append(timeSyncEffectIfNeeded(state: state, dependencies: dependencies))
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

            if case .timeSynced = event {
                effects.append(.cancel(id: timeSyncID))
                effects.append(
                    ClipsFeature.reduce(
                        state: &state.clips,
                        action: .load,
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
                .cancel(id: timeSyncID),
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
                .cancel(id: timeSyncID),
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

        case .timeSyncResponded(success: true):
            return .none

        case .timeSyncResponded(success: false):
            guard shouldSyncTime(state) else { return .none }
            return scheduleTimeSyncRetry(dependencies: dependencies)

        case .timeSyncRetry:
            return timeSyncEffectIfNeeded(state: state, dependencies: dependencies)
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

    private static func timeSyncEffectIfNeeded(
        state: State,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        guard shouldSyncTime(state) else { return .none }
        return syncTimeEffect(dependencies: dependencies)
    }

    private static func shouldSyncTime(_ state: State) -> Bool {
        guard let world = state.link.onlineWorld else { return false }
        return world.time?.synced != true
    }

    private static func syncTimeEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: timeSyncID, cancelInFlight: true) { send in
            do {
                try await dependencies.time.sync()
                guard Task.isCancelled == false else { return }
                await send(.timeSyncResponded(success: true))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                await send(.timeSyncResponded(success: false))
            }
        }
    }

    private static func scheduleTimeSyncRetry(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: timeSyncID, cancelInFlight: true) { send in
            await dependencies.sleep(.seconds(2))
            guard Task.isCancelled == false else { return }
            await send(.timeSyncRetry)
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

extension AppFeature.Action {
    var logLabel: String {
        switch self {
        case .streamStarted:
            "streamStarted"
        case .streamStopped:
            "streamStopped"
        case .event(let event):
            "event.\(event.logLabel)"
        case .streamFailed:
            "streamFailed"
        case .streamReconnect:
            "streamReconnect"
        case .heartbeatTimedOut:
            "heartbeatTimedOut"
        case .recording(let action):
            "recording.\(action.logLabel)"
        case .clips(let action):
            "clips.\(action.logLabel)"
        case .recordTapped:
            "recordTapped"
        case .manualRefresh:
            "manualRefresh"
        case .timeSyncResponded(true):
            "timeSyncResponded.success"
        case .timeSyncResponded(false):
            "timeSyncResponded.failure"
        case .timeSyncRetry:
            "timeSyncRetry"
        }
    }
}

extension AppFeature.State {
    var logSummary: String {
        [
            "link=\(link.logPhase)",
            "recording=\(recording.logPhase)",
            "clips=\(clips.logPhase)",
            "clip_count=\(clips.clips.count)",
            "paging=\(clips.isPaging)",
            "cursor=\(clips.nextCursor == nil ? "none" : "present")",
            "recon=\(streamReconnectAttempt)",
        ].joined(separator: " ")
    }

    var logSnapshot: String {
        var fields = [logSummary]

        if let world = link.onlineWorld {
            fields.append("camera=\(world.cameraState.rawValue)")
            fields.append("recorder=\(world.recorder.phase.rawValue)")
            fields.append("session=\(world.recorder.session)")
            if let segment = world.recorder.currentSegment {
                fields.append("segment=\(segment.id)")
            }
            fields.append("uptime_s=\(world.uptimeS)")
            if let storage = world.storage {
                fields.append("storage_used=\(storage.used)")
                fields.append("storage_total=\(storage.total)")
            }
            fields.append("temp_soc_c=\(world.tempC.soc.map(String.init(describing:)) ?? "nil")")
            fields.append("temp_sensor_c=\(world.tempC.sensor.map(String.init(describing:)) ?? "nil")")
        }

        return fields.joined(separator: " ")
    }
}

extension AppFeature {
    static func logTransition(_ action: Action, _ old: State, _ new: State) {
        let oldSummary = old.logSummary
        let newSummary = new.logSummary

        if oldSummary == newSummary {
            Log.reducer.debug("action=\(action.logLabel, privacy: .public) (no change)")
        } else {
            Log.reducer.notice(
                "action=\(action.logLabel, privacy: .public) \(oldSummary, privacy: .public) -> \(newSummary, privacy: .public)"
            )
        }
    }
}

private extension Link {
    var logPhase: String {
        switch self {
        case .connecting:
            "connecting"
        case .online:
            "online"
        case .offline:
            "offline"
        }
    }
}

private extension RecordingFeature.State {
    var logPhase: String {
        switch self {
        case .unknown:
            "unknown"
        case .idle:
            "idle"
        case .starting:
            "starting"
        case .recording:
            "recording"
        case .stopping:
            "stopping"
        case .failed:
            "failed"
        }
    }
}

private extension ClipsFeature.State {
    var logPhase: String {
        switch status {
        case .idle:
            "loaded"
        case .loading:
            "loading"
        case .failed:
            "failed"
        }
    }
}

private extension CameraEvent {
    var logLabel: String {
        switch self {
        case .snapshot:
            "snapshot"
        case .recordingStarting:
            "recordingStarting"
        case .recordingStarted:
            "recordingStarted"
        case .segmentOpened:
            "segmentOpened"
        case .clipFinalized:
            "clipFinalized"
        case .recordingStopping:
            "recordingStopping"
        case .recordingStopped:
            "recordingStopped"
        case .recorderFailed:
            "recorderFailed"
        case .cameraStateChanged:
            "cameraStateChanged"
        case .storageChanged:
            "storageChanged"
        case .tempChanged:
            "tempChanged"
        case .memChanged:
            "memChanged"
        case .timeSynced:
            "timeSynced"
        case .heartbeat:
            "heartbeat"
        case .unknown(let type):
            "unknown.\(type)"
        }
    }
}

private extension RecordingFeature.Action {
    var logLabel: String {
        switch self {
        case .startTapped:
            "startTapped"
        case .stopTapped:
            "stopTapped"
        case .recordingResponse(.success):
            "recordingResponse.success"
        case .recordingResponse(.failure):
            "recordingResponse.failure"
        case .recorderPhaseObserved:
            "recorderPhaseObserved"
        }
    }
}

private extension ClipsFeature.Action {
    var logLabel: String {
        switch self {
        case .load:
            "load"
        case .refresh:
            "refresh"
        case .onDisappear:
            "onDisappear"
        case .clipFinalized:
            "clipFinalized"
        case .loadMore:
            "loadMore"
        case .clipsResponse(.success):
            "clipsResponse.success"
        case .clipsResponse(.failure):
            "clipsResponse.failure"
        case .pageResponse(_, .success):
            "pageResponse.success"
        case .pageResponse(_, .failure):
            "pageResponse.failure"
        }
    }
}

typealias AppStore = Store<AppFeature.State, AppFeature.Action, AppDependencies>
