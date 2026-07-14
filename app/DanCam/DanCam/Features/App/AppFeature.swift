import Foundation
import OSLog

enum AppFeature {
    struct State: Equatable {
        var link: Link = .connecting
        var recording: RecordingFeature.State = .unknown
        var clips = ClipsFeature.State()
        var incidents = IncidentsFeature.State()
        var retentionEstimator = RetentionEstimator()
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
        case incidents(IncidentsFeature.Action)
        case foregrounded
        case backgrounded
        case recordTapped
        case manualRefresh
        case reconnectStreamIfOffline
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
            state.retentionEstimator.reset()
            _ = reduceIncidents(state: &state, action: .worldObserved(nil), dependencies: dependencies)
            return .merge([
                .cancel(id: streamID),
                .cancel(id: heartbeatID),
                .cancel(id: reconnectID),
                .cancel(id: timeSyncID),
            ])

        case .event(let event):
            let previousPhase = state.link.onlineWorld?.recorder.phase
            var isSnapshot = false
            var effects = [armHeartbeat(dependencies: dependencies)]

            if case .snapshot = event {
                state.retentionEstimator.reset()
            }
            state.link.fold(event)

            if case .snapshot = event {
                effects.append(reduceIncidents(
                    state: &state,
                    action: .worldObserved(state.link.onlineWorld),
                    dependencies: dependencies
                ))
            } else if case .segmentOpened = event {
                effects.append(reduceIncidents(
                    state: &state,
                    action: .worldObserved(state.link.onlineWorld),
                    dependencies: dependencies
                ))
            }

            if case .heartbeat = event, shouldReloadClipsOnHeartbeat(state) {
                effects.append(
                    ClipsFeature.reduce(
                        state: &state.clips,
                        action: .load,
                        dependencies: dependencies
                    )
                    .map(Action.clips)
                )
            }

            if case .snapshot = event {
                isSnapshot = true
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
                state.retentionEstimator.observe(clip)
                effects.append(
                    ClipsFeature.reduce(
                        state: &state.clips,
                        action: .clipFinalized(clip),
                        dependencies: dependencies
                    )
                    .map(Action.clips)
                )
                effects.append(reduceIncidents(
                    state: &state,
                    action: .clipsChanged,
                    dependencies: dependencies
                ))
            }

            if case .clipRemoved(let id) = event {
                effects.append(
                    ClipsFeature.reduce(
                        state: &state.clips,
                        action: .clipRemoved(id: id),
                        dependencies: dependencies
                    )
                    .map(Action.clips)
                )
                effects.append(reduceIncidents(
                    state: &state,
                    action: .clipRemoved(seq: id),
                    dependencies: dependencies
                ))
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

            if let phase = state.link.onlineWorld?.recorder.phase,
               isSnapshot || phase != previousPhase {
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
            state.retentionEstimator.reset()
            state.streamReconnectAttempt += 1
            return .merge([
                .cancel(id: heartbeatID),
                .cancel(id: timeSyncID),
                reduceRecording(
                    state: &state,
                    action: .linkWentOffline,
                    dependencies: dependencies
                ),
                reduceIncidents(state: &state, action: .worldObserved(nil), dependencies: dependencies),
                scheduleReconnect(
                    attempt: state.streamReconnectAttempt,
                    dependencies: dependencies
                ),
            ])

        case .heartbeatTimedOut:
            state.link.wentOffline()
            state.retentionEstimator.reset()
            state.streamReconnectAttempt += 1
            return .merge([
                .cancel(id: streamID),
                .cancel(id: heartbeatID),
                .cancel(id: timeSyncID),
                reduceRecording(
                    state: &state,
                    action: .linkWentOffline,
                    dependencies: dependencies
                ),
                reduceIncidents(state: &state, action: .worldObserved(nil), dependencies: dependencies),
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
            let clipsEffect = ClipsFeature.reduce(
                state: &state.clips,
                action: action,
                dependencies: dependencies
            )
            .map(Action.clips)
            var effects = [clipsEffect]
            switch action {
            case .clipRemoved(let id):
                effects.append(reduceIncidents(
                    state: &state,
                    action: .clipRemoved(seq: id),
                    dependencies: dependencies
                ))
            case .clipFinalized, .clipsResponse(_, _, .success), .pageResponse(_, _, .success):
                effects.append(reduceIncidents(
                    state: &state,
                    action: .clipsChanged,
                    dependencies: dependencies
                ))
            default:
                break
            }
            return .merge(effects)

        case .incidents(let action):
            let incidentEffect = reduceIncidents(
                state: &state,
                action: action,
                dependencies: dependencies
            )
            guard action == .pageRequested else { return incidentEffect }
            return .merge([
                incidentEffect,
                ClipsFeature.reduce(
                    state: &state.clips,
                    action: .loadMore,
                    dependencies: dependencies
                )
                .map(Action.clips),
            ])

        case .foregrounded:
            return reduceIncidents(
                state: &state,
                action: .foregrounded,
                dependencies: dependencies
            )

        case .backgrounded:
            return reduceIncidents(
                state: &state,
                action: .backgrounded,
                dependencies: dependencies
            )

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
            return .merge([
                ClipsFeature.reduce(
                    state: &state.clips,
                    action: .refresh,
                    dependencies: dependencies
                )
                .map(Action.clips),
                reduce(
                    state: &state,
                    action: .reconnectStreamIfOffline,
                    dependencies: dependencies
                ),
            ])

        case .reconnectStreamIfOffline:
            if case .offline = state.link {
                return reduce(state: &state, action: .streamStarted, dependencies: dependencies)
            }
            return .none

        case .timeSyncResponded(success: true):
            return .none

        case .timeSyncResponded(success: false):
            guard shouldSyncTime(state) else { return .none }
            return scheduleTimeSyncRetry(dependencies: dependencies)

        case .timeSyncRetry:
            return timeSyncEffectIfNeeded(state: state, dependencies: dependencies)
        }
    }

    private static func shouldReloadClipsOnHeartbeat(_ state: State) -> Bool {
        guard state.link.onlineWorld != nil else { return false }
        guard case .failed(let error) = state.clips.status else { return false }
        return error.isRetryable
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

    private static func reduceIncidents(
        state: inout State,
        action: IncidentsFeature.Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        IncidentsFeature.reduce(
            state: &state.incidents,
            action: action,
            world: state.link.onlineWorld,
            clipsState: state.clips,
            dependencies: dependencies
        )
        .map(Action.incidents)
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
        case .incidents(let action):
            "incidents.\(action.logLabel)"
        case .foregrounded:
            "foregrounded"
        case .backgrounded:
            "backgrounded"
        case .recordTapped:
            "recordTapped"
        case .manualRefresh:
            "manualRefresh"
        case .reconnectStreamIfOffline:
            "reconnectStreamIfOffline"
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
            "incidents=\(incidents.incidents.count)",
            "incident_pending=\(incidents.pendingIncidentCount)",
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
                fields.append("recording_capacity=\(storage.recordingCapacityBytes)")
            }
            fields.append("temp_soc_c=\(world.tempC.soc.current.map(String.init(describing:)) ?? "nil")")
            fields.append("temp_soc_max_c=\(world.tempC.soc.max.map(String.init(describing:)) ?? "nil")")
            fields.append("temp_sensor_c=\(world.tempC.sensor.current.map(String.init(describing:)) ?? "nil")")
            fields.append("temp_sensor_max_c=\(world.tempC.sensor.max.map(String.init(describing:)) ?? "nil")")
            if let mem = world.mem {
                fields.append("mem_available=\(mem.available)")
            }
            let cpu = world.cpu.cores.map { core in
                [core.id, core.currentPct, core.oneMinutePct, core.fiveMinutePct, core.fifteenMinutePct]
                    .map { $0.map(String.init) ?? "nil" }.joined(separator: "/")
            }.joined(separator: ",")
            fields.append("cpu_cores=\(cpu)")
            fields.append("time_synced=\(world.time.map { String($0.synced) } ?? "nil")")
        }

        return fields.joined(separator: " ")
    }
}

extension AppFeature {
    enum TransitionLog: Equatable {
        case notice(String)
        case debug(String)
    }

    static func transitionLog(action: Action, old: State, new: State) -> TransitionLog {
        let oldSummary = old.logSummary
        let newSummary = new.logSummary

        if oldSummary != newSummary {
            return .notice("action=\(action.logLabel) \(oldSummary) -> \(newSummary)")
        }
        if old != new {
            let diff = tokenDiff(old: old.logSnapshot, new: new.logSnapshot)
            return .debug("action=\(action.logLabel) \(diff.isEmpty ? "(state changed)" : diff)")
        }
        return .debug("action=\(action.logLabel) (no change)")
    }

    static func tokenDiff(old: String, new: String) -> String {
        func parse(_ snapshot: String) -> [(key: String, value: String)] {
            snapshot.split(separator: " ").compactMap { token in
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
        }

        let oldPairs = parse(old)
        let newPairs = parse(new)
        let oldValues = Dictionary(uniqueKeysWithValues: oldPairs.map { ($0.key, $0.value) })
        let newValues = Dictionary(uniqueKeysWithValues: newPairs.map { ($0.key, $0.value) })

        var changes = newPairs.compactMap { key, newValue -> String? in
            guard let oldValue = oldValues[key] else {
                return "\(key)=absent->\(newValue)"
            }
            guard oldValue != newValue else { return nil }
            return "\(key)=\(oldValue)->\(newValue)"
        }
        changes.append(contentsOf: oldPairs.compactMap { key, oldValue in
            guard newValues[key] == nil else { return nil }
            return "\(key)=\(oldValue)->absent"
        })
        return changes.joined(separator: " ")
    }

    static func logTransition(_ action: Action, _ old: State, _ new: State) {
        switch transitionLog(action: action, old: old, new: new) {
        case .notice(let message):
            Log.reducer.notice("\(message, privacy: .public)")
        case .debug(let message):
            Log.reducer.debug("\(message, privacy: .public)")
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
        case .clipRemoved:
            "clipRemoved"
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
        case .cpuChanged:
            "cpuChanged"
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
        case .linkWentOffline:
            "linkWentOffline"
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
        case .deleteTapped:
            "deleteTapped"
        case .deleteResponse(_, .success):
            "deleteResponse.success"
        case .deleteResponse(_, .failure):
            "deleteResponse.failure"
        case .clipRemoved:
            "clipRemoved"
        case .loadMore:
            "loadMore"
        case .clipsResponse(_, _, .success):
            "clipsResponse.success"
        case .clipsResponse(_, _, .failure):
            "clipsResponse.failure"
        case .pageResponse(_, _, .success):
            "pageResponse.success"
        case .pageResponse(_, _, .failure):
            "pageResponse.failure"
        }
    }
}

private extension IncidentsFeature.Action {
    var logLabel: String {
        switch self {
        case .worldObserved: "worldObserved"
        case .foregrounded: "foregrounded"
        case .backgrounded: "backgrounded"
        case .storeLoaded: "storeLoaded"
        case .clipsChanged: "clipsChanged"
        case .clipRemoved: "clipRemoved"
        case .pressTapped: "pressTapped"
        case .createResponded(_, true): "createResponded.success"
        case .createResponded(_, false): "createResponded.failure"
        case .persistenceAlertDismissed: "persistenceAlertDismissed"
        case .reconcile: "reconcile"
        case .recordPersisted(_, _, true): "recordPersisted.success"
        case .recordPersisted(_, _, false): "recordPersisted.failure"
        case .pageRequested: "pageRequested"
        case .pullFinished: "pullFinished"
        case .pullRecordsPersisted(_, _, true): "pullRecordsPersisted.success"
        case .pullRecordsPersisted(_, _, false): "pullRecordsPersisted.failure"
        case .lossRecordsPersisted(_, true): "lossRecordsPersisted.success"
        case .lossRecordsPersisted(_, false): "lossRecordsPersisted.failure"
        case .deleteTapped: "deleteTapped"
        case .deleteResponded(_, true): "deleteResponded.success"
        case .deleteResponded(_, false): "deleteResponded.failure"
        }
    }
}

typealias AppStore = Store<AppFeature.State, AppFeature.Action, AppDependencies>
