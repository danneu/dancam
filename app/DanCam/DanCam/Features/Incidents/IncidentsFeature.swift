import Foundation
import OSLog

enum IncidentsFeature {
    nonisolated struct OpenSegmentAnchor: Equatable, Sendable {
        var recordingID: RecordingID
        var seq: Int
        var seedDurMs: UInt64
        var observedAt: ContinuousClock.Instant
    }

    nonisolated struct PullRequest: Equatable, Sendable {
        var seq: Int
        var storageGeneration: String = StorageGeneration.legacy
        var etag: String
        var incidentIDs: [UUID]
    }

    nonisolated enum PullOutcome: Equatable, Sendable {
        case completed(bytes: [UUID: UInt64])
        case notFound
        case failed
    }

    nonisolated struct State: Equatable, Sendable {
        struct RuntimeLockout: Equatable, Sendable {
            var recordingID: RecordingID
            var deadline: ContinuousClock.Instant
        }

        var incidents: [IncidentRecord] = []
        var unreadableDirectoryNames: [String] = []
        var openSegmentAnchor: OpenSegmentAnchor?
        var runtimeLockout: RuntimeLockout?
        var lockoutResolvedRecordingID: RecordingID?
        var persistenceFailed = false
        var hasRequestedProvisionalAuth = false
        var pendingProvisionalAuthRecordID: UUID?
        var pendingRecords: [RecordingID: IncidentRecord] = [:]
        var pullQueue: [PullRequest] = []
        var activePull: PullRequest?
        var pendingPersistIDs: Set<UUID> = []
        var hasLoadedStore = false
        var isLoadingStore = false
        var requiredCoverageBoundary: ClipCursor?
        var isForeground = false

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.incidents == rhs.incidents
                && lhs.unreadableDirectoryNames == rhs.unreadableDirectoryNames
                && lhs.openSegmentAnchor == rhs.openSegmentAnchor
                && lhs.runtimeLockout == rhs.runtimeLockout
                && lhs.lockoutResolvedRecordingID == rhs.lockoutResolvedRecordingID
                && lhs.persistenceFailed == rhs.persistenceFailed
                && lhs.hasRequestedProvisionalAuth == rhs.hasRequestedProvisionalAuth
                && lhs.pendingProvisionalAuthRecordID == rhs.pendingProvisionalAuthRecordID
                && lhs.pendingRecords == rhs.pendingRecords
                && lhs.pullQueue == rhs.pullQueue
                && lhs.activePull == rhs.activePull
                && lhs.pendingPersistIDs == rhs.pendingPersistIDs
                && lhs.hasLoadedStore == rhs.hasLoadedStore
                && lhs.isLoadingStore == rhs.isLoadingStore
                && lhs.isForeground == rhs.isForeground
        }

        var pendingIncidentCount: Int {
            var ids = Set(incidents.lazy.filter { $0.status == .pending }.map(\.id))
            ids.formUnion(pendingRecords.values.map(\.id))
            return ids.count
        }

        func captureRecordingID(world: World?) -> RecordingID? {
            guard let world,
                  hasLoadedStore,
                  world.recorder.phase.claimsRecording,
                  let storageGeneration = world.storageGeneration,
                  let bootTag = world.bootTag,
                  let segment = world.recorder.currentSegment,
                  let openSegmentAnchor,
                  openSegmentAnchor.recordingID == RecordingID(
                      storageGeneration: storageGeneration,
                      bootTag: bootTag,
                      session: world.recorder.session
                  ),
                  openSegmentAnchor.seq == segment.id else { return nil }
            return openSegmentAnchor.recordingID
        }

        func activeLockout(
            for recordingID: RecordingID,
            now: ContinuousClock.Instant
        ) -> ContinuousClock.Instant? {
            guard let runtimeLockout,
                  runtimeLockout.recordingID == recordingID,
                  now < runtimeLockout.deadline else { return nil }
            return runtimeLockout.deadline
        }

        func canPress(world: World?, now: ContinuousClock.Instant) -> Bool {
            guard let recordingID = captureRecordingID(world: world) else { return false }
            return pendingRecords[recordingID] == nil
                && activeLockout(for: recordingID, now: now) == nil
        }

        mutating func resolveLockoutIfNeeded(
            world: World?,
            wallNow: Date,
            continuousNow: ContinuousClock.Instant
        ) {
            guard let recordingID = captureRecordingID(world: world),
                  lockoutResolvedRecordingID != recordingID else { return }

            let remaining = (Array(pendingRecords.values) + incidents)
                .lazy
                .filter { $0.recordingID == recordingID }
                .compactMap { record -> TimeInterval? in
                    let pressedAt = Date(timeIntervalSince1970: TimeInterval(record.pressedAtMs) / 1_000)
                    let windowEnd = pressedAt.addingTimeInterval(IncidentRecord.pressLockoutSpan)
                    guard wallNow >= pressedAt, wallNow < windowEnd else { return nil }
                    return windowEnd.timeIntervalSince(wallNow)
                }
                .max()

            runtimeLockout = remaining.map {
                RuntimeLockout(
                    recordingID: recordingID,
                    deadline: continuousNow.advanced(by: .seconds($0))
                )
            }
            lockoutResolvedRecordingID = recordingID
        }
    }

    enum Action: Equatable {
        case worldObserved(World?)
        case foregrounded
        case backgrounded
        case storeLoaded([StoredIncident]?)
        case clipsChanged
        case clipRemoved(seq: Int)
        case pressTapped
        case createResponded(IncidentRecord, success: Bool)
        case persistenceAlertDismissed
        case reconcile
        case recordPersisted(IncidentRecord, success: Bool)
        case pullFinished(PullRequest, PullOutcome)
        case pullRecordsPersisted(PullRequest, [IncidentRecord], success: Bool)
        case lossRecordsPersisted([IncidentRecord], success: Bool)
        case deleteTapped(IncidentListItemID)
        case deleteResponded(IncidentListItemID, success: Bool)
    }

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
            let continuousNow = dependencies.continuousNow()
            updateAnchor(state: &state, world: world, now: continuousNow)
            state.resolveLockoutIfNeeded(
                world: world,
                wallNow: dependencies.wallNow(),
                continuousNow: continuousNow
            )
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .foregrounded:
            state.isForeground = true
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

        case .backgrounded:
            state.isForeground = false
            let pendingIDs = state.incidents.compactMap { record in
                record.status == .pending ? record.id : nil
            }
            guard pendingIDs.isEmpty == false else { return .none }
            return .run { _ in
                for id in pendingIDs {
                    guard Task.isCancelled == false else { return }
                    await dependencies.incidentNotifier.scheduleNudge(id, .seconds(180))
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
            state.resolveLockoutIfNeeded(
                world: world,
                wallNow: dependencies.wallNow(),
                continuousNow: dependencies.continuousNow()
            )
            let terminalIDs = state.incidents.filter { $0.status.isTerminal }.map(\.id)
            return .run { send in
                for id in terminalIDs {
                    await dependencies.incidentNotifier.cancelNudge(id)
                }
                await send(.reconcile)
            }

        case .clipsChanged:
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .clipRemoved(let seq):
            guard let storageGeneration = world?.storageGeneration else { return .none }
            guard state.activePull?.seq != seq
                    || state.activePull?.storageGeneration != storageGeneration else { return .none }

            var changed: [IncidentRecord] = []
            for original in state.incidents {
                guard original.storageGeneration == storageGeneration,
                      var segment = original.segment(seq: seq),
                      segment.state == .wanted
                        || (segment.state == .lost && segment.lossEvidence == .inferredAbsence) else { continue }
                var record = original
                segment.confirmMissing()
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
                guard request.seq == seq,
                      request.storageGeneration == storageGeneration else { return request }
                let remaining = request.incidentIDs.filter { changedIDs.contains($0) == false }
                guard remaining.isEmpty == false else { return nil }
                return PullRequest(
                    seq: request.seq,
                    storageGeneration: request.storageGeneration,
                    etag: request.etag,
                    incidentIDs: remaining
                )
            }
            return persist(records: records, previous: state.incidents, dependencies: dependencies) {
                .lossRecordsPersisted(records, success: $0)
            }

        case .pressTapped:
            let now = dependencies.continuousNow()
            guard state.canPress(world: world, now: now),
                  let anchor = state.openSegmentAnchor else { return .none }

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
            state.pendingRecords[record.recordingID] = record
            state.runtimeLockout = State.RuntimeLockout(
                recordingID: record.recordingID,
                deadline: now.advanced(by: .seconds(IncidentRecord.pressLockoutSpan))
            )
            state.persistenceFailed = false

            let shouldRequestAuth = state.hasRequestedProvisionalAuth == false
            state.hasRequestedProvisionalAuth = true
            if shouldRequestAuth {
                state.pendingProvisionalAuthRecordID = record.id
            }

            return .run { send in
                do {
                    try await dependencies.incidentStore.create(record)
                    if shouldRequestAuth {
                        await dependencies.incidentNotifier.requestProvisionalAuth()
                    }
                    await dependencies.incidentNotifier.scheduleNudge(record.id, .seconds(180))
                    await send(.createResponded(record, success: true))
                } catch is CancellationError {
                    return
                } catch {
                    await send(.createResponded(record, success: false))
                }
            }

        case .createResponded(let record, success: true):
            guard state.pendingRecords[record.recordingID]?.id == record.id else { return .none }
            state.pendingRecords[record.recordingID] = nil
            if state.pendingProvisionalAuthRecordID == record.id {
                state.pendingProvisionalAuthRecordID = nil
            }
            state.incidents.append(record)
            return send(.reconcile)

        case .createResponded(let record, success: false):
            guard state.pendingRecords[record.recordingID]?.id == record.id else { return .none }
            state.pendingRecords[record.recordingID] = nil
            if state.pendingProvisionalAuthRecordID == record.id {
                state.pendingProvisionalAuthRecordID = nil
                state.hasRequestedProvisionalAuth = false
            }
            if state.runtimeLockout?.recordingID == record.recordingID {
                state.runtimeLockout = nil
            }
            state.persistenceFailed = true
            return .none

        case .persistenceAlertDismissed:
            state.persistenceFailed = false
            return .none

        case .reconcile:
            let available = state.incidents.filter { state.pendingPersistIDs.contains($0.id) == false }
            guard clipsState.hasLoadedOnce else {
                state.requiredCoverageBoundary = available
                    .map { ClipCursor(UInt32(clamping: $0.markSeq)) }
                    .min()
                return .none
            }
            let commands = IncidentPlanner.plan(
                incidents: available,
                clips: clipsState.clips,
                listCoverage: coverage(clipsState),
                recorder: recorderState(world)
            )
            var effects: [Effect<Action>] = []
            state.requiredCoverageBoundary = nil

            for command in commands {
                switch command {
                case .persist(let record):
                    guard state.pendingPersistIDs.insert(record.id).inserted else { continue }
                    let previousRecord = state.incidents.first(where: { $0.id == record.id }) ?? record
                    effects.append(persist(
                        record: record,
                        previousRecord: previousRecord,
                        dependencies: dependencies
                    ))

                case .pull(let seq, let etag, let incidentIDs):
                    let storageGeneration = state.incidents
                        .first { incidentIDs.contains($0.id) }?
                        .storageGeneration ?? StorageGeneration.legacy
                    enqueue(
                        PullRequest(
                            seq: seq,
                            storageGeneration: storageGeneration,
                            etag: etag,
                            incidentIDs: incidentIDs
                        ),
                        state: &state
                    )

                case .requireCoverage(let boundary):
                    state.requiredCoverageBoundary = state.requiredCoverageBoundary
                        .map { min($0, boundary) } ?? boundary

                }
            }

            if let pull = startNextPull(state: &state, dependencies: dependencies) {
                effects.append(pull)
            }
            return .merge(effects)

        case .recordPersisted(let record, success: true):
            state.pendingPersistIDs.remove(record.id)
            replace(record, in: &state)
            return reduce(
                state: &state,
                action: .reconcile,
                world: world,
                clipsState: clipsState,
                dependencies: dependencies
            )

        case .recordPersisted(let record, success: false):
            state.pendingPersistIDs.remove(record.id)
            return .none

        case .pullFinished(let request, let outcome):
            guard state.activePull == request else { return .none }
            switch outcome {
            case .completed(let bytes):
                let records = updatedRecords(for: request, state: state, bytes: bytes, lost: false)
                state.pendingPersistIDs.formUnion(records.map(\.id))
                return persist(records: records, previous: state.incidents, dependencies: dependencies) {
                    .pullRecordsPersisted(request, records, success: $0)
                }
            case .notFound:
                let records = updatedRecords(for: request, state: state, bytes: [:], lost: true)
                state.pendingPersistIDs.formUnion(records.map(\.id))
                return persist(records: records, previous: state.incidents, dependencies: dependencies) {
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
                    return PullRequest(
                        seq: request.seq,
                        storageGeneration: request.storageGeneration,
                        etag: request.etag,
                        incidentIDs: incidentIDs
                    )
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
                return .merge([
                    .run { _ in
                        await dependencies.incidentNotifier.cancelNudge(id)
                    },
                    reduce(
                        state: &state,
                        action: .reconcile,
                        world: world,
                        clipsState: clipsState,
                        dependencies: dependencies
                    ),
                ])
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
        previousRecord: IncidentRecord,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run { send in
            do {
                try await dependencies.incidentStore.update(record)
                await updateNudge(
                    incidentID: record.id,
                    from: previousRecord.status,
                    to: record.status,
                    dependencies: dependencies
                )
                logTransition(record: record, previousRecord: previousRecord)
                await send(.recordPersisted(record, success: true))
            } catch is CancellationError {
                return
            } catch {
                await send(.recordPersisted(record, success: false))
            }
        }
    }

    private static func persist(
        records: [IncidentRecord],
        previous: [IncidentRecord],
        dependencies: AppDependencies,
        response: @escaping @Sendable (Bool) -> Action
    ) -> Effect<Action> {
        let previousRecords = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return .run { send in
            do {
                for record in records {
                    try await dependencies.incidentStore.update(record)
                    let previousRecord = previousRecords[record.id] ?? record
                    await updateNudge(
                        incidentID: record.id,
                        from: previousRecord.status,
                        to: record.status,
                        dependencies: dependencies
                    )
                    logTransition(record: record, previousRecord: previousRecord)
                }
                await send(response(true))
            } catch is CancellationError {
                return
            } catch {
                await send(response(false))
            }
        }
    }

    private static func updateNudge(
        incidentID: UUID,
        from previousStatus: IncidentStatus,
        to status: IncidentStatus,
        dependencies: AppDependencies
    ) async {
        guard previousStatus != status else { return }
        if previousStatus.isTerminal, status == .pending {
            await dependencies.incidentNotifier.scheduleNudge(incidentID, .seconds(180))
        } else if previousStatus == .pending, status.isTerminal {
            await dependencies.incidentNotifier.cancelNudge(incidentID)
        }
    }

    private static func logTransition(record: IncidentRecord, previousRecord: IncidentRecord) {
        let previousBySeq = Dictionary(uniqueKeysWithValues: previousRecord.wanted.map { ($0.seq, $0) })
        for segment in record.wanted where
            segment.state == .lost
                && segment.lossEvidence == .inferredAbsence
                && previousBySeq[segment.seq]?.state != .lost {
            Log.incident.notice("inferred loss clip_id=\(segment.seq, privacy: .public) incident_id=\(record.id.uuidString, privacy: .public)")
        }
        for segment in record.wanted where
            segment.state == .lost
                && segment.lossEvidence == .confirmedMissing
                && previousBySeq[segment.seq]?.state != .lost {
            Log.incident.notice("confirmed loss clip_id=\(segment.seq, privacy: .public) incident_id=\(record.id.uuidString, privacy: .public)")
        }
        for segment in record.wanted where
            segment.state == .pulled && previousBySeq[segment.seq]?.state != .pulled {
            Log.incident.notice("pull completion clip_id=\(segment.seq, privacy: .public) incident_id=\(record.id.uuidString, privacy: .public)")
        }
        let previousStatus = previousRecord.status
        if previousStatus.isTerminal, record.status == .pending {
            Log.incident.notice("corrective reopening incident_id=\(record.id.uuidString, privacy: .public)")
        } else if previousStatus != record.status, record.status.isTerminal {
            Log.incident.notice("terminal state incident_id=\(record.id.uuidString, privacy: .public) status=\(record.status.rawValue, privacy: .public)")
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
        guard state.isForeground,
              state.activePull == nil,
              state.pullQueue.isEmpty == false else { return nil }
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
        let clip = Clip(
            id: request.seq,
            storageGeneration: request.storageGeneration,
            startMs: nil,
            durMs: nil,
            bytes: 0,
            locked: false,
            etag: request.etag,
            timeApproximate: true
        )
        let cancellation = PullTaskCancellation()
        let token = await dependencies.incidentBackgroundTask.begin {
            cancellation.cancel()
        }
        let task = Task<PullOutcome, Never> {
            do {
                let bytes = try await dependencies.clipMedia.preserve(
                    clip,
                    request.incidentIDs,
                    markIncidentIDs
                )
                return .completed(bytes: bytes)
            } catch is CancellationError {
                return .failed
            } catch ClipPullError.http(404) {
                return .notFound
            } catch {
                return .failed
            }
        }
        cancellation.set(task)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await dependencies.incidentBackgroundTask.end(token)
        return result
    }

    private nonisolated final class PullTaskCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<PullOutcome, Never>?
        private var isCancelled = false

        func set(_ task: Task<PullOutcome, Never>) {
            lock.lock()
            self.task = task
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
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
                segment.markLost(.confirmedMissing)
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
        ClipsFeature.incidentCoverage(clips)
    }

    private static func recorderState(_ world: World?) -> IncidentRecorderState {
        guard let world else { return .unknown }
        guard world.recorder.phase.isActive,
              let storageGeneration = world.storageGeneration,
              let bootTag = world.bootTag else { return .notRecording }
        return .recording(RecordingID(
            storageGeneration: storageGeneration,
            bootTag: bootTag,
            session: world.recorder.session
        ))
    }

    private static func updateAnchor(
        state: inout State,
        world: World?,
        now: ContinuousClock.Instant
    ) {
        guard let world,
              world.recorder.phase.claimsRecording,
              let storageGeneration = world.storageGeneration,
              let bootTag = world.bootTag,
              let segment = world.recorder.currentSegment else {
            state.openSegmentAnchor = nil
            return
        }

        let recordingID = RecordingID(
            storageGeneration: storageGeneration,
            bootTag: bootTag,
            session: world.recorder.session
        )
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
