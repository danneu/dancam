import Foundation

enum IncidentsFeature {
    nonisolated struct OpenSegmentAnchor: Equatable, Sendable {
        var recordingID: RecordingID
        var seq: Int
        var seedDurMs: UInt64
        var observedAt: ContinuousClock.Instant
    }

    nonisolated struct PullRequest: Equatable, Sendable {
        var seq: Int
        var etag: String
        var incidentIDs: [UUID]
    }

    nonisolated enum PullOutcome: Equatable, Sendable {
        case completed(bytes: [UUID: UInt64])
        case notFound
        case failed
    }

    nonisolated struct State: Equatable, Sendable {
        var incidents: [IncidentRecord] = []
        var unreadableDirectoryNames: [String] = []
        var openSegmentAnchor: OpenSegmentAnchor?
        var isPressFeedbackVisible = false
        var persistenceFailed = false
        var hasRequestedProvisionalAuth = false
        var pendingRecord: IncidentRecord?
        var pullQueue: [PullRequest] = []
        var activePull: PullRequest?
        var pendingPersistIDs: Set<UUID> = []
        var hasLoadedStore = false
        var isLoadingStore = false
        var isPageRequestPending = false

        func canPress(world: World?) -> Bool {
            guard let world,
                  world.recorder.phase.claimsRecording,
                  let bootTag = world.bootTag,
                  let segment = world.recorder.currentSegment,
                  let openSegmentAnchor,
                  openSegmentAnchor.recordingID == RecordingID(
                      bootTag: bootTag,
                      session: world.recorder.session
                  ),
                  openSegmentAnchor.seq == segment.id else { return false }
            return isPressFeedbackVisible == false && pendingRecord == nil
        }
    }

    enum Action: Equatable {
        case worldObserved(World?)
        case foregrounded
        case storeLoaded([StoredIncident]?)
        case clipsChanged
        case clipRemoved(seq: Int)
        case pressTapped
        case createResponded(IncidentRecord, success: Bool)
        case cooldownFinished
        case persistenceAlertDismissed
        case reconcile
        case recordPersisted(IncidentRecord, cancelNudge: Bool, success: Bool)
        case pageRequested
        case pullFinished(PullRequest, PullOutcome)
        case pullRecordsPersisted(PullRequest, [IncidentRecord], success: Bool)
        case lossRecordsPersisted([IncidentRecord], success: Bool)
        case deleteTapped(IncidentListItemID)
        case deleteResponded(IncidentListItemID, success: Bool)
    }

    private static let cooldownID = "incident-press-cooldown"
    private static let pullID = "incident-active-pull"

    static func reduce(
        state: inout State,
        action: Action,
        world: World?,
        clipsState: ClipsFeature.State = .init(),
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .worldObserved(let world):
            updateAnchor(state: &state, world: world, now: dependencies.continuousNow())
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .foregrounded:
            guard state.hasLoadedStore == false, state.isLoadingStore == false else {
                return reduce(
                    state: &state,
                    action: .reconcile,
                    world: world,
                    clipsState: clipsState,
                    dependencies: dependencies
                )
            }
            state.isLoadingStore = true
            return .run { send in
                do {
                    await send(.storeLoaded(try await dependencies.incidentStore.list()))
                } catch is CancellationError {
                    return
                } catch {
                    await send(.storeLoaded(nil))
                }
            }

        case .storeLoaded(let stored):
            state.isLoadingStore = false
            guard let stored else { return .none }
            state.hasLoadedStore = true
            state.incidents = stored.compactMap { item in
                guard case .readable(let record, _) = item else { return nil }
                return record
            }
            state.unreadableDirectoryNames = stored.compactMap { item in
                guard case .unreadable(let directoryName, _) = item else { return nil }
                return directoryName
            }
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .clipsChanged:
            state.isPageRequestPending = false
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .clipRemoved(let seq):
            guard state.activePull?.seq != seq else { return .none }

            var changed: [IncidentRecord] = []
            for original in state.incidents where original.status == .pending {
                guard var segment = original.segment(seq: seq), segment.state == .wanted else { continue }
                var record = original
                segment.markLost()
                record.updateSegment(segment)
                changed.append(record)
            }
            guard changed.isEmpty == false else {
                return reduce(
                    state: &state,
                    action: .reconcile,
                    world: world,
                    clipsState: clipsState,
                    dependencies: dependencies
                )
            }

            let records = changed
            let changedIDs = Set(records.map(\.id))
            state.pendingPersistIDs.formUnion(changedIDs)
            state.pullQueue = state.pullQueue.compactMap { request in
                guard request.seq == seq else { return request }
                let remaining = request.incidentIDs.filter { changedIDs.contains($0) == false }
                guard remaining.isEmpty == false else { return nil }
                return PullRequest(seq: request.seq, etag: request.etag, incidentIDs: remaining)
            }
            return persist(records: records, dependencies: dependencies) {
                .lossRecordsPersisted(records, success: $0)
            }

        case .pressTapped:
            guard state.canPress(world: world),
                  let anchor = state.openSegmentAnchor else { return .none }

            let now = dependencies.continuousNow()
            let elapsed = anchor.observedAt.duration(to: now)
            let elapsedMs = max(0, elapsed.milliseconds)
            let markAge = anchor.seedDurMs.addingReportingOverflow(UInt64(elapsedMs))
            let pressedAtMs = UInt64(max(0, dependencies.wallNow().timeIntervalSince1970 * 1_000))
            let record = IncidentRecord(
                id: dependencies.uuid(),
                pressedAtMs: pressedAtMs,
                recordingID: anchor.recordingID,
                markSeq: anchor.seq,
                markAgeMs: markAge.overflow ? .max : markAge.partialValue
            )
            state.pendingRecord = record
            state.isPressFeedbackVisible = true
            state.persistenceFailed = false

            return .run { send in
                do {
                    try await dependencies.incidentStore.create(record)
                    await send(.createResponded(record, success: true))
                } catch is CancellationError {
                    return
                } catch {
                    await send(.createResponded(record, success: false))
                }
            }

        case .createResponded(let record, success: true):
            guard state.pendingRecord?.id == record.id else { return .none }
            state.pendingRecord = nil
            state.incidents.append(record)

            let shouldRequestAuth = state.hasRequestedProvisionalAuth == false
            state.hasRequestedProvisionalAuth = true
            return .merge([
                .run { send in
                    if shouldRequestAuth {
                        await dependencies.incidentNotifier.requestProvisionalAuth()
                    }
                    await dependencies.incidentNotifier.scheduleNudge(record.id, .seconds(180))
                    await send(.reconcile)
                },
                .run(id: cooldownID, cancelInFlight: true) { send in
                    await dependencies.sleep(.seconds(3))
                    guard Task.isCancelled == false else { return }
                    await send(.cooldownFinished)
                },
            ])

        case .createResponded(let record, success: false):
            guard state.pendingRecord?.id == record.id else { return .none }
            state.pendingRecord = nil
            state.isPressFeedbackVisible = false
            state.persistenceFailed = true
            return .none

        case .cooldownFinished:
            state.isPressFeedbackVisible = false
            return .none

        case .persistenceAlertDismissed:
            state.persistenceFailed = false
            return .none

        case .reconcile:
            guard clipsState.hasLoadedOnce else { return .none }
            let available = state.incidents.filter { state.pendingPersistIDs.contains($0.id) == false }
            let commands = IncidentPlanner.plan(
                incidents: available,
                clips: clipsState.clips,
                listCoverage: coverage(clipsState),
                recorder: recorderState(world)
            )
            var effects: [Effect<Action>] = []

            for command in commands {
                switch command {
                case .persist(let record):
                    guard state.pendingPersistIDs.insert(record.id).inserted else { continue }
                    effects.append(persist(record: record, cancelNudge: false, dependencies: dependencies))

                case .pull(let seq, let etag, let incidentIDs):
                    enqueue(
                        PullRequest(seq: seq, etag: etag, incidentIDs: incidentIDs),
                        state: &state
                    )

                case .page:
                    guard clipsState.isPaging == false,
                          clipsState.nextCursor != nil,
                          state.isPageRequestPending == false else { continue }
                    state.isPageRequestPending = true
                    effects.append(send(.pageRequested))

                case .finalize(let incidentID, let status):
                    guard state.pendingPersistIDs.insert(incidentID).inserted,
                          var record = state.incidents.first(where: { $0.id == incidentID }) else { continue }
                    record.status = status
                    effects.append(persist(record: record, cancelNudge: true, dependencies: dependencies))

                case .cancelNudge:
                    // Cancellation follows the durable terminal write above.
                    continue
                }
            }

            if let pull = startNextPull(state: &state, dependencies: dependencies) {
                effects.append(pull)
            }
            return .merge(effects)

        case .recordPersisted(let record, let cancelNudge, success: true):
            state.pendingPersistIDs.remove(record.id)
            replace(record, in: &state)
            var effects: [Effect<Action>] = [reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )]
            if cancelNudge {
                effects.insert(.run { _ in
                    await dependencies.incidentNotifier.cancelNudge(record.id)
                }, at: 0)
            }
            return .merge(effects)

        case .recordPersisted(let record, _, success: false):
            state.pendingPersistIDs.remove(record.id)
            return .none

        case .pageRequested:
            return .none

        case .pullFinished(let request, let outcome):
            guard state.activePull == request else { return .none }
            switch outcome {
            case .completed(let bytes):
                let records = updatedRecords(for: request, state: state, bytes: bytes, lost: false)
                state.pendingPersistIDs.formUnion(records.map(\.id))
                return persist(records: records, dependencies: dependencies) {
                    .pullRecordsPersisted(request, records, success: $0)
                }
            case .notFound:
                let records = updatedRecords(for: request, state: state, bytes: [:], lost: true)
                state.pendingPersistIDs.formUnion(records.map(\.id))
                return persist(records: records, dependencies: dependencies) {
                    .pullRecordsPersisted(request, records, success: $0)
                }
            case .failed:
                state.activePull = nil
                return startNextPull(state: &state, dependencies: dependencies) ?? .none
            }

        case .pullRecordsPersisted(let request, let records, success: true):
            guard state.activePull == request else { return .none }
            state.pendingPersistIDs.subtract(records.map(\.id))
            for record in records { replace(record, in: &state) }
            state.activePull = nil
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .pullRecordsPersisted(let request, let records, success: false):
            guard state.activePull == request else { return .none }
            state.pendingPersistIDs.subtract(records.map(\.id))
            state.activePull = nil
            return startNextPull(state: &state, dependencies: dependencies) ?? .none

        case .lossRecordsPersisted(let records, success: true):
            state.pendingPersistIDs.subtract(records.map(\.id))
            for record in records { replace(record, in: &state) }
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .lossRecordsPersisted(let records, success: false):
            state.pendingPersistIDs.subtract(records.map(\.id))
            return .none

        case .deleteTapped(let itemID):
            var effects: [Effect<Action>] = []
            switch itemID {
            case .readable(let id):
                state.pullQueue = state.pullQueue.compactMap { request in
                    let incidentIDs = request.incidentIDs.filter { $0 != id }
                    guard incidentIDs.isEmpty == false else { return nil }
                    return PullRequest(seq: request.seq, etag: request.etag, incidentIDs: incidentIDs)
                }
                if state.activePull?.incidentIDs.contains(id) == true {
                    state.activePull = nil
                    effects.append(.cancel(id: pullID))
                }
                effects.append(.run { send in
                    do {
                        try await dependencies.incidentStore.delete(id)
                        await send(.deleteResponded(itemID, success: true))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.deleteResponded(itemID, success: false))
                    }
                })

            case .unreadable(let directoryName):
                effects.append(.run { send in
                    do {
                        try await dependencies.incidentStore.deleteUnreadable(directoryName)
                        await send(.deleteResponded(itemID, success: true))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.deleteResponded(itemID, success: false))
                    }
                })
            }
            return .merge(effects)

        case .deleteResponded(let itemID, success: true):
            switch itemID {
            case .readable(let id):
                state.incidents.removeAll { $0.id == id }
                state.pendingPersistIDs.remove(id)
            case .unreadable(let directoryName):
                state.unreadableDirectoryNames.removeAll { $0 == directoryName }
            }
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .deleteResponded(_, success: false):
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )
        }
    }

    private static func persist(
        record: IncidentRecord,
        cancelNudge: Bool,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run { send in
            do {
                try await dependencies.incidentStore.update(record)
                await send(.recordPersisted(record, cancelNudge: cancelNudge, success: true))
            } catch is CancellationError {
                return
            } catch {
                await send(.recordPersisted(record, cancelNudge: cancelNudge, success: false))
            }
        }
    }

    private static func persist(
        records: [IncidentRecord],
        dependencies: AppDependencies,
        response: @escaping @Sendable (Bool) -> Action
    ) -> Effect<Action> {
        .run { send in
            do {
                for record in records {
                    try await dependencies.incidentStore.update(record)
                }
                await send(response(true))
            } catch is CancellationError {
                return
            } catch {
                await send(response(false))
            }
        }
    }

    private static func send(_ action: Action) -> Effect<Action> {
        .run { send in await send(action) }
    }

    private static func enqueue(_ request: PullRequest, state: inout State) {
        if let active = state.activePull,
           active.seq == request.seq,
           active.etag == request.etag {
            return
        }
        guard state.pullQueue.contains(where: {
            $0.seq == request.seq && $0.etag == request.etag
        }) == false else { return }
        state.pullQueue.append(request)
    }

    private static func startNextPull(
        state: inout State,
        dependencies: AppDependencies
    ) -> Effect<Action>? {
        guard state.activePull == nil, state.pullQueue.isEmpty == false else { return nil }
        let request = state.pullQueue.removeFirst()
        state.activePull = request
        let markIDs = state.incidents.compactMap { record in
            request.incidentIDs.contains(record.id) && record.markSeq == request.seq ? record.id : nil
        }

        return .run(id: pullID, cancelInFlight: true) { send in
            let outcome = await pull(
                request,
                markIncidentIDs: markIDs,
                dependencies: dependencies
            )
            guard Task.isCancelled == false else { return }
            await send(.pullFinished(request, outcome))
        }
    }

    private static func pull(
        _ request: PullRequest,
        markIncidentIDs: [UUID],
        dependencies: AppDependencies
    ) async -> PullOutcome {
        if let cached = await dependencies.clipCache.lookup(request.seq, request.etag) {
            do {
                await dependencies.incidentArtifactInstaller.writeThumbnail(
                    cached,
                    .mp4,
                    request.seq,
                    markIncidentIDs
                )
                let bytes = try await dependencies.incidentArtifactInstaller.install(
                    cached,
                    .mp4,
                    request.seq,
                    request.incidentIDs
                )
                return .completed(bytes: bytes)
            } catch {
                return .failed
            }
        }

        let task = Task {
            await networkPull(request, markIncidentIDs: markIncidentIDs, dependencies: dependencies)
        }
        let token = await dependencies.incidentBackgroundTask.begin { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await dependencies.incidentBackgroundTask.end(token)
        return result
    }

    private static func networkPull(
        _ request: PullRequest,
        markIncidentIDs: [UUID],
        dependencies: AppDependencies
    ) async -> PullOutcome {
        do {
            var result: ClipPullResult?
            for try await event in dependencies.clipPull.pull(request.seq, request.etag) {
                try Task.checkCancellation()
                if case .completed(let completed) = event {
                    result = completed
                }
            }
            guard let result else { return .failed }
            defer { try? FileManager.default.removeItem(at: result.fileURL) }

            await dependencies.incidentArtifactInstaller.writeThumbnail(
                result.fileURL,
                .ts,
                request.seq,
                markIncidentIDs
            )

            do {
                let remuxed = try await dependencies.clipRemuxer.remux(result.fileURL, request.seq)
                defer {
                    if remuxed.fileURL != result.fileURL {
                        try? FileManager.default.removeItem(at: remuxed.fileURL)
                    }
                }
                let bytes = try await dependencies.incidentArtifactInstaller.install(
                    remuxed.fileURL,
                    .mp4,
                    request.seq,
                    request.incidentIDs
                )
                return .completed(bytes: bytes)
            } catch is CancellationError {
                return .failed
            } catch {
                let bytes = try await dependencies.incidentArtifactInstaller.install(
                    result.fileURL,
                    .ts,
                    request.seq,
                    request.incidentIDs
                )
                return .completed(bytes: bytes)
            }
        } catch is CancellationError {
            return .failed
        } catch ClipPullError.http(404) {
            return .notFound
        } catch {
            return .failed
        }
    }

    private static func updatedRecords(
        for request: PullRequest,
        state: State,
        bytes: [UUID: UInt64],
        lost: Bool
    ) -> [IncidentRecord] {
        state.incidents.compactMap { original in
            guard request.incidentIDs.contains(original.id),
                  var segment = original.segment(seq: request.seq),
                  segment.state == .wanted else { return nil }
            var record = original
            if lost {
                segment.markLost()
            } else {
                segment.markPulled(bytes: bytes[record.id] ?? 0)
            }
            record.updateSegment(segment)
            return record
        }
    }

    private static func replace(_ record: IncidentRecord, in state: inout State) {
        guard let index = state.incidents.firstIndex(where: { $0.id == record.id }) else { return }
        state.incidents[index] = record
    }

    private static func coverage(_ clips: ClipsFeature.State) -> IncidentListCoverage {
        clips.hasLoadedOnce ? .loaded(nextCursor: clips.nextCursor) : .unloaded
    }

    private static func recorderState(_ world: World?) -> IncidentRecorderState {
        guard let world else { return .unknown }
        guard world.recorder.phase.claimsRecording,
              let bootTag = world.bootTag else { return .notRecording }
        return .recording(RecordingID(bootTag: bootTag, session: world.recorder.session))
    }

    private static func updateAnchor(
        state: inout State,
        world: World?,
        now: ContinuousClock.Instant
    ) {
        guard let world,
              world.recorder.phase.claimsRecording,
              let bootTag = world.bootTag,
              let segment = world.recorder.currentSegment else {
            state.openSegmentAnchor = nil
            return
        }

        let recordingID = RecordingID(bootTag: bootTag, session: world.recorder.session)
        if state.openSegmentAnchor?.recordingID == recordingID,
           state.openSegmentAnchor?.seq == segment.id {
            return
        }
        state.openSegmentAnchor = OpenSegmentAnchor(
            recordingID: recordingID,
            seq: segment.id,
            seedDurMs: segment.durMs ?? 0,
            observedAt: now
        )
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard seconds.overflow == false else { return seconds.partialValue }
        return seconds.partialValue + components.attoseconds / 1_000_000_000_000_000
    }
}
