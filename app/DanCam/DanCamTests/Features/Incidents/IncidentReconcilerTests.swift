import Foundation
import Testing
@testable import DanCam

@MainActor
struct IncidentReconcilerTests {
    @Test func queuedPullWaitsForForegroundWhileActivePullKeepsBackgroundGrace() async {
        let request = IncidentsFeature.PullRequest(seq: 10, etag: "e10", incidentIDs: [])
        let pullStarted = AsyncSignal()
        let releasePull = AsyncSignal()
        let state = IncidentsFeature.State(
            pullQueue: [request],
            hasLoadedStore: true
        )
        let dependencies = AppDependencies(
            clipCache: ClipCache(
                lookup: { _, _ in
                    await pullStarted.signal()
                    await releasePull.wait()
                    return URL(filePath: "/tmp/cached.mp4")
                },
                insert: { _, _, source in source }
            ),
            incidentArtifactInstaller: installer { _, _, _, _ in [:] }
        )
        let clips = clipsState([])
        let store = TestStore(
            initialState: state,
            dependencies: dependencies,
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: nil,
                    clipsState: clips,
                    dependencies: dependencies
                )
            }
        )

        await store.send(.reconcile)
        #expect(store.state.pullQueue == [request])
        #expect(store.state.activePull == nil)

        await store.send(.foregrounded) {
            $0.isForeground = true
            $0.pullQueue = []
            $0.activePull = request
        }
        await pullStarted.wait()

        await store.send(.backgrounded) {
            $0.isForeground = false
        }
        #expect(store.state.activePull == request)

        await releasePull.signal()
        await store.receive(.pullFinished(request, .completed(bytes: [:])))
        await store.receive(.pullRecordsPersisted(request, [], success: true)) {
            $0.activePull = nil
        }
        await store.finishEffects()
    }

    @Test func happyThreeSegmentSaveFinishesSavedAndCancelsNudge() async throws {
        let id = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let cached = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([1]).write(to: cached)
        defer { try? FileManager.default.removeItem(at: cached) }
        let ledger = ReconcilerLedger()
        var state = IncidentsFeature.State(incidents: [
            record(id: id, states: [.wanted, .wanted, .wanted]),
        ], isForeground: true)
        let dependencies = AppDependencies(
            clipCache: ClipCache(lookup: { _, _ in cached }, insert: { _, _, source in source }),
            incidentStore: store { _ in },
            incidentNotifier: IncidentNotifier(
                requestProvisionalAuth: {},
                scheduleNudge: { _, _ in },
                cancelNudge: { _ in await ledger.append("cancel") }
            ),
            incidentArtifactInstaller: installer { _, _, _, ids in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) })
            }
        )
        let clips = clipsState([clip(seq: 10), clip(seq: 11), clip(seq: 12)])
        var effect = IncidentsFeature.reduce(
            state: &state,
            action: .reconcile,
            world: recordingWorld(),
            clipsState: clips,
            dependencies: dependencies
        )

        for seq in 10...12 {
            let pullAction = try #require(await actions(from: effect).first)
            guard case .pullFinished(let request, .completed) = pullAction else {
                Issue.record("Expected completed pull for segment \(seq).")
                return
            }
            #expect(request.seq == seq)

            let persistEffect = IncidentsFeature.reduce(
                state: &state,
                action: pullAction,
                world: recordingWorld(),
                clipsState: clips,
                dependencies: dependencies
            )
            let persistedAction = try #require(await actions(from: persistEffect).first)
            effect = IncidentsFeature.reduce(
                state: &state,
                action: persistedAction,
                world: recordingWorld(),
                clipsState: clips,
                dependencies: dependencies
            )
        }

        #expect(await actions(from: effect).isEmpty)
        #expect(state.incidents[0].status == .saved)
        #expect(await ledger.values() == ["cancel"])
    }

    @Test func resolutionPersistsBeforeCacheHitCloneStarts() async throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let ledger = ReconcilerLedger()
        let cached = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([1, 2, 3]).write(to: cached)
        defer { try? FileManager.default.removeItem(at: cached) }

        var state = IncidentsFeature.State(
            incidents: [record(id: id, states: [.unresolved])],
            isForeground: true
        )
        let dependencies = AppDependencies(
            clipCache: ClipCache(
                lookup: { _, _ in
                    await ledger.append("cache")
                    return cached
                },
                insert: { _, _, source in source }
            ),
            incidentStore: store { _ in await ledger.append("persist") },
            incidentArtifactInstaller: installer { _, _, _, _ in
                await ledger.append("install")
                return [id: 3]
            }
        )
        let clips = clipsState([clip(seq: 10)])

        let first = IncidentsFeature.reduce(
            state: &state,
            action: .reconcile,
            world: recordingWorld(),
            clipsState: clips,
            dependencies: dependencies
        )
        #expect(state.pendingPersistIDs == [id])
        let firstActions = await actions(from: first)
        let resolved = try #require(firstActions.first)
        guard case .recordPersisted(let resolvedRecord, true) = resolved else {
            Issue.record("Expected the witnessed resolution to persist.")
            return
        }
        #expect(await ledger.values() == ["persist"])

        let second = IncidentsFeature.reduce(
            state: &state,
            action: .recordPersisted(resolvedRecord, success: true),
            world: recordingWorld(),
            clipsState: clips,
            dependencies: dependencies
        )
        #expect(state.activePull?.seq == 10)
        _ = await actions(from: second)
        #expect(await ledger.values() == ["persist", "cache", "install"])
    }

    @Test func overlappingIncidentsShareOneSingleFlightPull() async throws {
        let firstID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let secondID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let ledger = ReconcilerLedger()
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([7]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var state = IncidentsFeature.State(incidents: [
            record(id: firstID, states: [.wanted]),
            record(id: secondID, states: [.wanted]),
        ], isForeground: true)
        let dependencies = AppDependencies(
            clipPull: completedPull(source),
            clipRemuxer: ClipRemuxer { url, _ in
                ClipRemuxResult(fileURL: url, duration: .seconds(5), bytes: 1)
            },
            clipCache: ClipCache(
                lookup: { _, _ in
                    await ledger.append("pull")
                    return nil
                },
                insert: { _, _, source in source }
            ),
            incidentArtifactInstaller: installer { _, _, _, ids in
                #expect(Set(ids) == [firstID, secondID])
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) })
            }
        )

        let effect = IncidentsFeature.reduce(
            state: &state,
            action: .reconcile,
            world: recordingWorld(),
            clipsState: clipsState([clip(seq: 10)]),
            dependencies: dependencies
        )
        #expect(state.activePull?.incidentIDs == [firstID, secondID])
        #expect(state.pullQueue.isEmpty)
        let emitted = await actions(from: effect)
        #expect(emitted.count == 1)
        #expect(await ledger.values() == ["pull"])
    }

    @Test func removalLosesQueuedEntryButNeverPreemptsActivePull() async throws {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let active = IncidentsFeature.PullRequest(seq: 10, etag: "e10", incidentIDs: [id])
        let queued = IncidentsFeature.PullRequest(seq: 11, etag: "e11", incidentIDs: [id])
        var state = IncidentsFeature.State(
            incidents: [record(id: id, states: [.wanted, .wanted])],
            pullQueue: [queued],
            activePull: active
        )

        let activeEffect = IncidentsFeature.reduce(
            state: &state,
            action: .clipRemoved(seq: 10),
            world: recordingWorld(),
            clipsState: clipsState([]),
            dependencies: AppDependencies()
        )
        #expect(state.incidents[0].segment(seq: 10)?.state == .wanted)
        #expect(state.activePull == active)
        #expect(await actions(from: activeEffect).isEmpty)

        let queuedEffect = IncidentsFeature.reduce(
            state: &state,
            action: .clipRemoved(seq: 11),
            world: recordingWorld(),
            clipsState: clipsState([]),
            dependencies: AppDependencies(incidentStore: store { _ in })
        )
        #expect(state.pullQueue.isEmpty)
        let emitted = await actions(from: queuedEffect)
        let removalAction = try #require(emitted.first)
        guard case .lossRecordsPersisted(let records, true) = removalAction else {
            Issue.record("Expected queued removal to persist loss evidence.")
            return
        }
        #expect(records[0].segment(seq: 11)?.state == .lost)
    }

    @Test func removalUpgradesInferredLossSoStaleListCannotReopenIt() async throws {
        let id = UUID(uuidString: "45454545-4545-4545-4545-454545454545")!
        var inferred = record(id: id, states: [.lost])
        inferred.wanted[0].lossEvidence = .inferredAbsence
        var state = IncidentsFeature.State(incidents: [inferred])

        let effect = IncidentsFeature.reduce(
            state: &state,
            action: .clipRemoved(seq: 10),
            world: recordingWorld(),
            clipsState: clipsState([]),
            dependencies: AppDependencies(incidentStore: store { _ in })
        )
        let emitted = await actions(from: effect)
        guard case .lossRecordsPersisted(let records, true) = try #require(emitted.first) else {
            Issue.record("Expected removal to persist confirmed loss evidence.")
            return
        }

        let confirmed = try #require(records.first)
        #expect(confirmed.segment(seq: 10)?.lossEvidence == .confirmedMissing)
        #expect(IncidentPlanner.plan(
            incidents: [confirmed],
            clips: [clip(seq: 10)],
            listCoverage: .loaded(nextCursor: nil),
            recorder: .notRecording
        ).isEmpty)
    }

    @Test func activeRemovalFollowedByCompletionSalvagesIncident() async throws {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let request = IncidentsFeature.PullRequest(seq: 10, etag: "e10", incidentIDs: [id])
        var state = IncidentsFeature.State(
            incidents: [record(id: id, states: [.wanted])],
            activePull: request,
            isForeground: true
        )
        let dependencies = AppDependencies(incidentStore: store { _ in })

        _ = IncidentsFeature.reduce(
            state: &state,
            action: .clipRemoved(seq: 10),
            world: recordingWorld(),
            clipsState: clipsState([]),
            dependencies: dependencies
        )
        let effect = IncidentsFeature.reduce(
            state: &state,
            action: .pullFinished(request, .completed(bytes: [id: 99])),
            world: recordingWorld(),
            clipsState: clipsState([]),
            dependencies: dependencies
        )
        let emitted = await actions(from: effect)
        let completionAction = try #require(emitted.first)
        guard case .pullRecordsPersisted(_, let records, true) = completionAction else {
            Issue.record("Expected completed active pull to be persisted.")
            return
        }
        #expect(records[0].segment(seq: 10)?.state == .pulled)
        #expect(records[0].segment(seq: 10)?.bytes == 99)
    }

    @Test func pull404PersistsLossAndNon404RetriesOnlyOnNextTrigger() async throws {
        let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let request = IncidentsFeature.PullRequest(seq: 10, etag: "e10", incidentIDs: [id])
        var state = IncidentsFeature.State(
            incidents: [record(id: id, states: [.wanted])],
            activePull: request,
            isForeground: true
        )
        let dependencies = AppDependencies(incidentStore: store { _ in })

        let notFound = IncidentsFeature.reduce(
            state: &state,
            action: .pullFinished(request, .notFound),
            world: recordingWorld(),
            clipsState: clipsState([]),
            dependencies: dependencies
        )
        let emitted = await actions(from: notFound)
        let notFoundAction = try #require(emitted.first)
        guard case .pullRecordsPersisted(_, let lostRecords, true) = notFoundAction else {
            Issue.record("Expected 404 loss to persist.")
            return
        }
        #expect(lostRecords[0].segment(seq: 10)?.state == .lost)

        state.pendingPersistIDs = []
        state.activePull = request
        let failure = IncidentsFeature.reduce(
            state: &state,
            action: .pullFinished(request, .failed),
            world: recordingWorld(),
            clipsState: clipsState([]),
            dependencies: dependencies
        )
        #expect(state.activePull == nil)
        #expect(await actions(from: failure).isEmpty)

        _ = IncidentsFeature.reduce(
            state: &state,
            action: .reconcile,
            world: recordingWorld(),
            clipsState: clipsState([clip(seq: 10)]),
            dependencies: dependencies
        )
        #expect(state.activePull == request)
    }

    @Test func relaunchResumeNeverQueuesAlreadyPulledSegment() async throws {
        let id = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let resumed = record(id: id, states: [.pulled, .wanted])
        var state = IncidentsFeature.State()
        let dependencies = AppDependencies(
            incidentStore: IncidentStore(
                list: { [.readable(record: resumed, directoryURL: URL(filePath: "/tmp/i"))] },
                create: { _ in },
                update: { _ in },
                delete: { _ in },
                deleteUnreadable: { _ in },
                directoryURL: { _ in URL(filePath: "/tmp/i") }
            )
        )

        let load = IncidentsFeature.reduce(
            state: &state,
            action: .foregrounded,
            world: recordingWorld(),
            clipsState: clipsState([clip(seq: 10), clip(seq: 11)]),
            dependencies: dependencies
        )
        let emitted = await actions(from: load)
        guard case .storeLoaded(let stored?) = try #require(emitted.first) else {
            Issue.record("Expected stored incidents to load.")
            return
        }
        let install = IncidentsFeature.reduce(
            state: &state,
            action: .storeLoaded(stored),
            world: recordingWorld(),
            clipsState: clipsState([clip(seq: 10), clip(seq: 11)]),
            dependencies: dependencies
        )
        let reconcile = try #require(await actions(from: install).first)
        _ = IncidentsFeature.reduce(
            state: &state,
            action: reconcile,
            world: recordingWorld(),
            clipsState: clipsState([clip(seq: 10), clip(seq: 11)]),
            dependencies: dependencies
        )
        #expect(state.activePull?.seq == 11)
        #expect(state.pullQueue.allSatisfy { $0.seq != 10 })
    }

    @Test func remuxFailurePublishesRawFallbackAndBalancesBackgroundAssertion() async throws {
        let id = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let ledger = ReconcilerLedger()
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([1, 2]).write(to: source)
        var state = IncidentsFeature.State(
            incidents: [record(id: id, states: [.wanted])],
            isForeground: true
        )
        let dependencies = AppDependencies(
            clipPull: completedPull(source),
            clipRemuxer: ClipRemuxer { _, _ in throw CocoaError(.fileReadCorruptFile) },
            clipCache: ClipCache(lookup: { _, _ in nil }, insert: { _, _, source in source }),
            incidentArtifactInstaller: installer { _, kind, _, _ in
                await ledger.append("install:\(kind.rawValue)")
                return [id: 2]
            },
            incidentBackgroundTask: IncidentBackgroundTaskClient(
                begin: { _ in
                    await ledger.append("begin")
                    return 9
                },
                end: { token in await ledger.append("end:\(token)") }
            )
        )

        let effect = IncidentsFeature.reduce(
            state: &state,
            action: .reconcile,
            world: recordingWorld(),
            clipsState: clipsState([clip(seq: 10)]),
            dependencies: dependencies
        )
        let emitted = await actions(from: effect)
        #expect(emitted.count == 1)
        #expect(await ledger.values() == ["begin", "install:ts", "end:9"])
    }

    @Test func liveInstallerPublishesOnlyCompleteFinalArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "incident-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([4, 5, 6]).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let installer = IncidentArtifactInstaller.live { incidentID in
            root.appending(path: incidentID.uuidString, directoryHint: .isDirectory)
        }

        let bytes = try await installer.install(source, .mp4, 41, [id])
        let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(bytes == [id: 3])
        #expect(files == ["seg_00041.mp4"])
        #expect(try Data(contentsOf: directory.appending(path: "seg_00041.mp4")) == Data([4, 5, 6]))
    }

    private func record(
        id: UUID,
        states: [IncidentSegmentState]
    ) -> IncidentRecord {
        let segments = states.enumerated().map { offset, state in
            IncidentSegment(
                seq: 10 + offset,
                state: state,
                etag: state == .unresolved ? nil : "e\(10 + offset)",
                durMs: state == .unresolved ? nil : 5_000,
                bytes: state == .pulled ? 50 : nil
            )
        }
        return IncidentRecord(
            id: id,
            pressedAtMs: 1,
            recordingID: RecordingID(bootTag: "boot-a", session: 7),
            markSeq: 10,
            markAgeMs: 0,
            preMs: 0,
            postMs: UInt64(max(0, states.count - 1) * 5_000),
            slackMs: 0,
            wanted: segments
        )
    }

    private func clip(seq: Int) -> Clip {
        Clip(
            id: seq,
            startMs: nil,
            durMs: 5_000,
            bytes: 1,
            locked: false,
            etag: "e\(seq)",
            timeApproximate: true,
            bootTag: "boot-a",
            session: 7
        )
    }

    private func clipsState(_ clips: [Clip]) -> ClipsFeature.State {
        var state = ClipsFeature.State()
        state.clips = clips
        state.hasLoadedOnce = true
        state.nextCursor = nil
        return state
    }

    private func recordingWorld() -> World {
        CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 12, durMs: 1_000),
            bootTag: "boot-a"
        )
    }

    private func store(
        update: @escaping @Sendable (IncidentRecord) async throws -> Void
    ) -> IncidentStore {
        IncidentStore(
            list: { [] },
            create: { _ in },
            update: update,
            delete: { _ in },
            deleteUnreadable: { _ in },
            directoryURL: { _ in URL(filePath: "/tmp") }
        )
    }

    private func installer(
        install: @escaping @Sendable (URL, IncidentArtifactKind, Int, [UUID]) async throws -> [UUID: UInt64]
    ) -> IncidentArtifactInstaller {
        IncidentArtifactInstaller(install: install, writeThumbnail: { _, _, _, _ in })
    }

    private func completedPull(_ source: URL) -> ClipPullClient {
        ClipPullClient { _, etag in
            AsyncThrowingStream { continuation in
                continuation.yield(.completed(ClipPullResult(
                    fileURL: source,
                    bytes: 1,
                    elapsed: .seconds(1),
                    throughputMbps: 1,
                    resolvedETag: etag
                )))
                continuation.finish()
            }
        }
    }

    private func actions(from effect: Effect<IncidentsFeature.Action>) async -> [IncidentsFeature.Action] {
        let collector = ReconcilerActionCollector()
        await execute(effect, collector: collector)
        return await collector.values()
    }

    private func execute(
        _ effect: Effect<IncidentsFeature.Action>,
        collector: ReconcilerActionCollector
    ) async {
        switch effect {
        case .none, .cancel:
            return
        case .merge(let effects):
            for effect in effects { await execute(effect, collector: collector) }
        case .run(_, _, let operation):
            await operation { action in await collector.append(action) }
        }
    }
}

private actor ReconcilerLedger {
    private var entries: [String] = []

    func append(_ value: String) { entries.append(value) }
    func values() -> [String] { entries }
}

private actor ReconcilerActionCollector {
    private var actions: [IncidentsFeature.Action] = []

    func append(_ action: IncidentsFeature.Action) { actions.append(action) }
    func values() -> [IncidentsFeature.Action] { actions }
}
