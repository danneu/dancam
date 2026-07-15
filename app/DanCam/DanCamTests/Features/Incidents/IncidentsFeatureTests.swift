import Foundation
import Testing
@testable import DanCam

@MainActor
struct IncidentsFeatureTests {
    private let clock = ContinuousClock()

    @Test func enablementRequiresOnlineRecordingAnchorAndLockoutClear() {
        let recording = world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000))
        let idle = world(phase: .idle, segment: nil)
        var state = IncidentsFeature.State()
        let now = clock.now

        #expect(state.canPress(world: nil, now: now) == false)
        #expect(state.canPress(world: idle, now: now) == false)
        #expect(state.canPress(world: recording, now: now) == false)

        state.hasLoadedStore = true
        state.openSegmentAnchor = anchor(seq: 12, observedAt: now)
        #expect(state.canPress(world: recording, now: now))

        let recordingID = RecordingID(bootTag: "boot-a", session: 7)
        state.runtimeLockout = .init(recordingID: recordingID, deadline: now.advanced(by: .seconds(17)))
        #expect(state.canPress(world: recording, now: now) == false)
        #expect(state.canPress(world: recording, now: now.advanced(by: .seconds(18))))

        state.pendingRecords[recordingID] = record(id: UUID(), markAgeMs: 1_000)
        #expect(state.canPress(world: recording, now: now.advanced(by: .seconds(18))) == false)
        state.pendingRecords[recordingID] = nil
        state.pendingRecords[RecordingID(bootTag: "boot-a", session: 6)] = record(
            id: UUID(),
            markAgeMs: 1_000,
            recordingID: RecordingID(bootTag: "boot-a", session: 6)
        )
        #expect(state.canPress(world: recording, now: now.advanced(by: .seconds(18))))
    }

    @Test func appForwardsSnapshotAndRolloverIntoAnchor() {
        let firstNow = clock.now
        let secondNow = firstNow.advanced(by: .seconds(2))
        let times = InstantSequence([firstNow, secondNow])
        let dependencies = AppDependencies(
            clips: ClipsClient { _ in throw CancellationError() },
            continuousNow: { times.next() }
        )
        var state = AppFeature.State()
        state.link = .connecting(last: nil)
        let firstWorld = world(
            phase: .recording,
            segment: RecorderSegment(id: 12, durMs: 4_500)
        )

        _ = AppFeature.reduce(state: &state, action: .event(.snapshot(firstWorld)), dependencies: dependencies)
        #expect(state.incidents.openSegmentAnchor == IncidentsFeature.OpenSegmentAnchor(
            recordingID: RecordingID(bootTag: "boot-a", session: 7),
            seq: 12,
            seedDurMs: 4_500,
            observedAt: firstNow
        ))

        _ = AppFeature.reduce(
            state: &state,
            action: .event(.segmentOpened(session: 7, id: 13, atMs: 20_000)),
            dependencies: dependencies
        )
        #expect(state.incidents.openSegmentAnchor == IncidentsFeature.OpenSegmentAnchor(
            recordingID: RecordingID(bootTag: "boot-a", session: 7),
            seq: 13,
            seedDurMs: 0,
            observedAt: secondNow
        ))
    }

    @Test func negativeInferenceWaitsForSuccessfulHeadFromCurrentEpoch() async {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000445")!
        let incident = record(
            id: id,
            markSeq: 445,
            markAgeMs: 1_000,
            preMs: 0,
            postMs: 0,
            slackMs: 0
        )
        let idle = world(phase: .idle, segment: nil)
        let staleClips = ClipsFeature.State(
            headEpoch: 2,
            lastSuccessfulHeadEpoch: 1,
            hasLoadedOnce: true
        )
        let staleStore = TestStore(
            initialState: IncidentsFeature.State(incidents: [incident]),
            dependencies: AppDependencies(),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: idle,
                    clipsState: staleClips,
                    dependencies: dependencies
                )
            }
        )

        await staleStore.send(.reconcile)
        #expect(staleStore.state.incidents[0].status == .pending)

        let freshClips = ClipsFeature.State(
            headEpoch: 2,
            lastSuccessfulHeadEpoch: 2,
            hasLoadedOnce: true
        )
        let freshStore = TestStore(
            initialState: IncidentsFeature.State(incidents: [incident]),
            dependencies: AppDependencies(),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: idle,
                    clipsState: freshClips,
                    dependencies: dependencies
                )
            }
        )
        var lost = incident
        lost.wanted[0].markLost(.inferredAbsence)

        await freshStore.send(.reconcile) {
            $0.pendingPersistIDs = [id]
        }
        await freshStore.receive(.recordPersisted(lost, success: true)) {
            $0.incidents = [lost]
            $0.pendingPersistIDs = []
        }
        #expect(freshStore.state.incidents[0].status == .partial)
    }

    @Test func stoppingLifecycleKeepsOpenMarkPendingUntilFinalizationEvidenceArrives() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000445")!
        var state = AppFeature.State()
        state.link = .online(world(
            phase: .recording,
            segment: RecorderSegment(id: 445, durMs: 1_000)
        ))
        state.clips = ClipsFeature.State(
            headEpoch: 1,
            lastSuccessfulHeadEpoch: 1,
            hasLoadedOnce: true
        )
        state.incidents.incidents = [record(
            id: id,
            markSeq: 445,
            markAgeMs: 1_000,
            preMs: 0,
            postMs: 0,
            slackMs: 0
        )]

        _ = AppFeature.reduce(
            state: &state,
            action: .event(.recordingStopping(session: 7, atMs: 1_000)),
            dependencies: .init()
        )

        #expect(state.incidents.incidents[0].status == .pending)
        #expect(state.incidents.pendingPersistIDs.isEmpty)
    }

    @Test(arguments: [RecorderEndWitness.failed, .differentSession])
    func recorderEndWitnessesAreForwardedToReconciliation(witness: RecorderEndWitness) {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000445")!
        var state = AppFeature.State()
        state.link = .online(world(
            phase: .recording,
            segment: RecorderSegment(id: 445, durMs: 1_000)
        ))
        state.clips = ClipsFeature.State(
            headEpoch: 1,
            lastSuccessfulHeadEpoch: 1,
            hasLoadedOnce: true
        )
        state.incidents.incidents = [record(
            id: id,
            markSeq: 445,
            markAgeMs: 1_000,
            postMs: 0,
            slackMs: 0
        )]
        let event: CameraEvent = switch witness {
        case .failed:
            .recorderFailed(session: 7, detail: "camera", atMs: 1_000)
        case .differentSession:
            .recordingStarting(session: 8, atMs: 1_000)
        }

        _ = AppFeature.reduce(state: &state, action: .event(event), dependencies: .init())

        #expect(state.incidents.pendingPersistIDs == [id])
    }

    @Test func persistedRecordPrecedesAuthNudgeAndReconcile() async throws {
        let ledger = IncidentEffectLedger()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let now = clock.now
        var state = IncidentsFeature.State()
        state.hasLoadedStore = true
        state.openSegmentAnchor = anchor(seq: 12, seedDurMs: 2_000, observedAt: now)
        let recording = world(
            phase: .recording,
            segment: RecorderSegment(id: 12, durMs: nil)
        )
        let store = TestStore(
            initialState: state,
            dependencies: AppDependencies(
                incidentStore: IncidentStore(
                    list: { [] },
                    create: { record in await ledger.append("persist:\(record.id)") },
                    update: { _ in },
                    delete: { _ in },
                    deleteUnreadable: { _ in },
                    directoryURL: { _ in URL(filePath: "/tmp") }
                ),
                incidentNotifier: IncidentNotifier(
                    requestProvisionalAuth: { await ledger.append("auth") },
                    scheduleNudge: { _, fireIn in
                        await ledger.append("nudge:\(fireIn == .seconds(180))")
                    },
                    cancelNudge: { _ in }
                ),
                continuousNow: { now.advanced(by: .seconds(1)) },
                wallNow: { Date(timeIntervalSince1970: 1_784_480_523) },
                uuid: { id }
            ),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: recording,
                    dependencies: dependencies
                )
            }
        )

        await store.send(.pressTapped) {
            let record = self.record(id: id, markAgeMs: 3_000)
            $0.pendingRecords[record.recordingID] = record
            $0.runtimeLockout = .init(
                recordingID: record.recordingID,
                deadline: now.advanced(by: .seconds(18))
            )
            $0.hasRequestedProvisionalAuth = true
            $0.pendingProvisionalAuthRecordID = id
        }
        await store.receive(.createResponded(record(id: id, markAgeMs: 3_000), success: true)) {
            $0.pendingRecords = [:]
            $0.incidents = [self.record(id: id, markAgeMs: 3_000)]
            $0.pendingProvisionalAuthRecordID = nil
        }
        await store.receive(.reconcile)
        await ledger.waitForCount(3)

        let events = await ledger.events()
        #expect(events == ["persist:\(id)", "auth", "nudge:true"])
        await store.finishEffects()
    }

    @Test func backgroundEnsuresNudgeForEachPendingIncidentOnly() async {
        let ledger = IncidentEffectLedger()
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let savedID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        var state = IncidentsFeature.State()
        state.hasLoadedStore = true
        state.incidents = [
            record(id: firstID, markAgeMs: 1_000),
            record(id: secondID, markAgeMs: 1_000),
            record(id: savedID, markAgeMs: 1_000, status: .saved),
        ]
        let store = makeLifecycleStore(state: state, ledger: ledger)

        await store.send(.backgrounded)
        await store.finishEffects()

        #expect(await ledger.events() == ["schedule:\(firstID):true", "schedule:\(secondID):true"])
    }

    @Test func durableTerminalTransitionCancelsNudge() async {
        let ledger = IncidentEffectLedger()
        let id = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        var pending = record(id: id, markAgeMs: 1_000)
        var state = IncidentsFeature.State()
        state.incidents = [pending]
        let store = makeLifecycleStore(state: state, ledger: ledger)
        pending.wanted[0].markClipped()

        await store.send(.recordPersisted(pending, success: true)) {
            $0.incidents = [pending]
        }
        await store.finishEffects()

        #expect(await ledger.events().isEmpty)
    }

    @Test func deletingPendingIncidentCancelsNudgeAfterDeleteSucceeds() async {
        let ledger = IncidentEffectLedger()
        let id = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        var state = IncidentsFeature.State()
        state.incidents = [record(id: id, markAgeMs: 1_000)]
        let store = makeLifecycleStore(state: state, ledger: ledger)

        await store.send(.deleteTapped(.readable(id)))
        await store.receive(.deleteResponded(.readable(id), success: true)) {
            $0.incidents = []
        }
        await store.finishEffects()

        #expect(await ledger.events() == ["delete:\(id)", "cancel:\(id)"])
    }

    @Test func rolloverRaceKeepsPreviousSegmentWithAgePastItsDuration() async {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let observedAt = clock.now
        let saved = IncidentRecordBox()
        var state = IncidentsFeature.State()
        state.hasLoadedStore = true
        state.openSegmentAnchor = anchor(seq: 41, seedDurMs: 29_500, observedAt: observedAt)
        let recording = world(
            phase: .recording,
            segment: RecorderSegment(id: 41, durMs: nil)
        )
        let dependencies = AppDependencies(
            incidentStore: IncidentStore(
                list: { [] },
                create: { await saved.set($0) },
                update: { _ in },
                delete: { _ in },
                deleteUnreadable: { _ in },
                directoryURL: { _ in URL(filePath: "/tmp") }
            ),
            sleep: { _ in },
            continuousNow: { observedAt.advanced(by: .seconds(2)) },
            wallNow: { Date(timeIntervalSince1970: 1_784_480_523) },
            uuid: { id }
        )
        let store = TestStore(
            initialState: state,
            dependencies: dependencies,
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: recording,
                    dependencies: dependencies
                )
            }
        )

        await store.send(.pressTapped) {
            let record = self.record(id: id, markSeq: 41, markAgeMs: 31_500)
            $0.pendingRecords[record.recordingID] = record
            $0.runtimeLockout = .init(
                recordingID: record.recordingID,
                deadline: observedAt.advanced(by: .seconds(19))
            )
            $0.hasRequestedProvisionalAuth = true
            $0.pendingProvisionalAuthRecordID = id
        }
        await store.receive(.createResponded(record(id: id, markSeq: 41, markAgeMs: 31_500), success: true)) {
            $0.pendingRecords = [:]
            $0.incidents = [self.record(id: id, markSeq: 41, markAgeMs: 31_500)]
            $0.pendingProvisionalAuthRecordID = nil
        }
        await store.receive(.reconcile)
        await store.finishEffects()

        let persisted = await saved.value()
        #expect(persisted?.markSeq == 41)
        #expect(persisted?.markAgeMs == 31_500)
    }

    @Test func activeLockoutRequiresMatchingIdentityAndFutureDeadline() {
        let now = clock.now
        let current = RecordingID(bootTag: "boot-a", session: 7)
        let other = RecordingID(bootTag: "boot-a", session: 8)
        var state = IncidentsFeature.State()

        #expect(state.activeLockout(for: current, now: now) == nil)
        state.runtimeLockout = .init(
            recordingID: current,
            deadline: now.advanced(by: .seconds(17))
        )
        #expect(state.activeLockout(for: current, now: now) == now.advanced(by: .seconds(17)))
        #expect(state.activeLockout(for: current, now: now.advanced(by: .seconds(17))) == nil)
        #expect(state.activeLockout(for: other, now: now) == nil)
    }

    @Test func relaunchReconstructsLatestMatchingFixedWindowOnlyOnce() {
        let continuousNow = clock.now
        let wallNow = Date(timeIntervalSince1970: 10_000)
        let recordingID = RecordingID(bootTag: "boot-a", session: 7)
        let records = [
            record(
                id: UUID(),
                markAgeMs: 1_000,
                recordingID: recordingID,
                pressedAtMs: UInt64((wallNow.timeIntervalSince1970 - 9) * 1_000)
            ),
            record(
                id: UUID(),
                markAgeMs: 1_000,
                recordingID: recordingID,
                pressedAtMs: UInt64((wallNow.timeIntervalSince1970 - 5) * 1_000)
            ),
        ]
        let expectedDeadline = continuousNow.advanced(by: .seconds(12))
        for input in [records, records.reversed()] {
            var state = loadedState(now: continuousNow)
            state.incidents = Array(input)
            state.resolveLockoutIfNeeded(
                world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
                wallNow: wallNow,
                continuousNow: continuousNow
            )

            #expect(state.runtimeLockout?.deadline == expectedDeadline)
            #expect(state.lockoutResolvedRecordingID == recordingID)
            #expect(state.canPress(
                world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
                now: expectedDeadline.advanced(by: .seconds(-1))
            ) == false)

            state.resolveLockoutIfNeeded(
                world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
                wallNow: wallNow.addingTimeInterval(-86_400),
                continuousNow: continuousNow.advanced(by: .seconds(1))
            )
            #expect(state.runtimeLockout?.deadline == expectedDeadline)
        }
    }

    @Test func reconstructionIgnoresOtherRecordingAndBadWallWindows() {
        let continuousNow = clock.now
        let wallNow = Date(timeIntervalSince1970: 200_000)
        let current = RecordingID(bootTag: "boot-a", session: 7)
        let previous = RecordingID(bootTag: "boot-a", session: 6)

        for pressedAtMs in [
            UInt64((wallNow.timeIntervalSince1970 - 86_400) * 1_000),
            UInt64((wallNow.timeIntervalSince1970 + 86_400) * 1_000),
        ] {
            var state = loadedState(now: continuousNow)
            state.incidents = [record(
                id: UUID(),
                markAgeMs: 1_000,
                recordingID: current,
                pressedAtMs: pressedAtMs
            )]
            state.resolveLockoutIfNeeded(
                world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
                wallNow: wallNow,
                continuousNow: continuousNow
            )
            #expect(state.runtimeLockout == nil)
            #expect(state.lockoutResolvedRecordingID == current)
        }

        var isolated = loadedState(now: continuousNow)
        isolated.incidents = [record(
            id: UUID(),
            markAgeMs: 1_000,
            recordingID: previous,
            pressedAtMs: UInt64((wallNow.timeIntervalSince1970 - 5) * 1_000)
        )]
        isolated.resolveLockoutIfNeeded(
            world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
            wallNow: wallNow,
            continuousNow: continuousNow
        )
        #expect(isolated.runtimeLockout == nil)
        #expect(isolated.canPress(
            world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
            now: continuousNow
        ))
    }

    @Test func corruptPersistedDurationsCannotExtendReconstructedLockout() {
        let continuousNow = clock.now
        let wallNow = Date(timeIntervalSince1970: 30_000)
        var state = loadedState(now: continuousNow)
        state.incidents = [record(
            id: UUID(),
            markAgeMs: 1_000,
            pressedAtMs: UInt64((wallNow.timeIntervalSince1970 - 5) * 1_000),
            postMs: .max,
            slackMs: 1
        )]

        state.resolveLockoutIfNeeded(
            world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
            wallNow: wallNow,
            continuousNow: continuousNow
        )

        #expect(state.runtimeLockout?.deadline == continuousNow.advanced(by: .seconds(12)))
    }

    @Test func captureStaysUnavailableUntilStoreLoadThenReconstructsMidWindow() {
        let continuousNow = clock.now
        let wallNow = Date(timeIntervalSince1970: 40_000)
        let recording = world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000))
        var state = IncidentsFeature.State()
        state.openSegmentAnchor = anchor(seq: 12, observedAt: continuousNow)

        #expect(state.captureRecordingID(world: recording) == nil)

        state.incidents = [record(
            id: UUID(),
            markAgeMs: 1_000,
            pressedAtMs: UInt64((wallNow.timeIntervalSince1970 - 5) * 1_000)
        )]
        state.hasLoadedStore = true
        state.resolveLockoutIfNeeded(
            world: recording,
            wallNow: wallNow,
            continuousNow: continuousNow
        )

        #expect(state.captureRecordingID(world: recording) == RecordingID(bootTag: "boot-a", session: 7))
        #expect(state.runtimeLockout?.deadline == continuousNow.advanced(by: .seconds(12)))
    }

    @Test func reducerRejectsPressUntilMonotonicDeadlineExpires() async {
        let start = clock.now
        let now = InstantBox(start.advanced(by: .seconds(16)))
        let id = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        let recording = world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000))
        var state = loadedState(now: start)
        state.runtimeLockout = .init(
            recordingID: RecordingID(bootTag: "boot-a", session: 7),
            deadline: start.advanced(by: .seconds(17))
        )
        let store = TestStore(
            initialState: state,
            dependencies: AppDependencies(
                incidentStore: .noop,
                continuousNow: { now.value() },
                wallNow: { Date(timeIntervalSince1970: 50_000) },
                uuid: { id }
            ),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: recording,
                    dependencies: dependencies
                )
            }
        )

        await store.send(.pressTapped)
        store.expectNoReceivedActions()

        now.set(start.advanced(by: .seconds(17.1)))
        await store.send(.pressTapped) {
            let record = self.record(
                id: id,
                markAgeMs: 18_100,
                pressedAtMs: 50_000_000
            )
            $0.pendingRecords[record.recordingID] = record
            $0.runtimeLockout = .init(
                recordingID: record.recordingID,
                deadline: start.advanced(by: .seconds(34.1))
            )
            $0.hasRequestedProvisionalAuth = true
            $0.pendingProvisionalAuthRecordID = id
        }
        await store.receive(.createResponded(
            record(id: id, markAgeMs: 18_100, pressedAtMs: 50_000_000),
            success: true
        )) {
            $0.pendingRecords = [:]
            $0.incidents = [self.record(id: id, markAgeMs: 18_100, pressedAtMs: 50_000_000)]
            $0.pendingProvisionalAuthRecordID = nil
        }
        await store.receive(.reconcile)
        await store.finishEffects()
    }

    @Test func persistenceFailureClearsOnlyMatchingCreateAndLockoutForImmediateRetry() async {
        let now = clock.now
        let current = RecordingID(bootTag: "boot-a", session: 7)
        let other = RecordingID(bootTag: "boot-a", session: 6)
        let currentRecord = record(id: UUID(), markAgeMs: 1_000, recordingID: current)
        let otherRecord = record(id: UUID(), markAgeMs: 1_000, recordingID: other)
        var state = loadedState(now: now)
        state.pendingRecords = [current: currentRecord, other: otherRecord]
        state.runtimeLockout = .init(recordingID: current, deadline: now.advanced(by: .seconds(17)))

        _ = IncidentsFeature.reduce(
            state: &state,
            action: .createResponded(currentRecord, success: false),
            world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
            dependencies: .init()
        )

        #expect(state.pendingRecords[current] == nil)
        #expect(state.pendingRecords[other] == otherRecord)
        #expect(state.runtimeLockout == nil)
        #expect(state.persistenceFailed)
        #expect(state.canPress(
            world: world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000)),
            now: now
        ))
    }

    @Test func storeLoadFailureRetriesAndOnlySuccessfulLoadArmsCapture() async {
        let now = clock.now
        let recording = world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000))
        let loads = IncidentListSequence()
        var state = IncidentsFeature.State()
        state.openSegmentAnchor = anchor(seq: 12, observedAt: now)
        let store = TestStore(
            initialState: state,
            dependencies: AppDependencies(
                incidentStore: IncidentStore(
                    list: { try await loads.next() },
                    create: { _ in },
                    update: { _ in },
                    delete: { _ in },
                    deleteUnreadable: { _ in },
                    directoryURL: { _ in URL(filePath: "/tmp") }
                ),
                continuousNow: { now },
                wallNow: { Date(timeIntervalSince1970: 60_000) }
            ),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: recording,
                    dependencies: dependencies
                )
            }
        )

        await store.send(.foregrounded) {
            $0.isLoadingStore = true
            $0.isForeground = true
        }
        await store.receive(.storeLoaded(nil)) { $0.isLoadingStore = false }
        #expect(store.state.captureRecordingID(world: recording) == nil)

        await store.send(.foregrounded) { $0.isLoadingStore = true }
        await store.receive(.storeLoaded([])) {
            $0.isLoadingStore = false
            $0.hasLoadedStore = true
            $0.lockoutResolvedRecordingID = RecordingID(bootTag: "boot-a", session: 7)
        }
        #expect(await loads.callCount() == 2)
        #expect(store.state.captureRecordingID(world: recording) != nil)
        await store.finishEffects()
    }

    @Test func suspendedCreatePastDeadlineStillRejectsCurrentRecordingPress() {
        let start = clock.now
        let recordingID = RecordingID(bootTag: "boot-a", session: 7)
        let pending = record(id: UUID(), markAgeMs: 1_000)
        var state = loadedState(now: start)
        state.pendingRecords[recordingID] = pending
        state.runtimeLockout = .init(
            recordingID: recordingID,
            deadline: start.advanced(by: .seconds(17))
        )
        let afterWindow = start.advanced(by: .seconds(18))
        let recording = world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000))

        #expect(state.activeLockout(for: recordingID, now: afterWindow) == nil)
        #expect(state.canPress(world: recording, now: afterWindow) == false)
        _ = IncidentsFeature.reduce(
            state: &state,
            action: .pressTapped,
            world: recording,
            dependencies: AppDependencies(continuousNow: { afterWindow })
        )
        #expect(state.pendingRecords == [recordingID: pending])
    }

    @Test func suspendedCreatesRemainIndependentAcrossRecordingSessions() async {
        let start = clock.now
        let firstID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
        let ids = UUIDSequence([firstID, secondID])
        let creates = IncidentCreateGate()
        let firstWorld = world(
            phase: .recording,
            segment: RecorderSegment(id: 12, durMs: 1_000),
            session: 7
        )
        let secondWorld = world(
            phase: .recording,
            segment: RecorderSegment(id: 20, durMs: 2_000),
            session: 8
        )
        let currentWorld = WorldBox(firstWorld)
        let state = loadedState(now: start)
        let store = TestStore(
            initialState: state,
            dependencies: AppDependencies(
                incidentStore: IncidentStore(
                    list: { [] },
                    create: { await creates.create($0) },
                    update: { _ in },
                    delete: { _ in },
                    deleteUnreadable: { _ in },
                    directoryURL: { _ in URL(filePath: "/tmp") }
                ),
                continuousNow: { start },
                wallNow: { Date(timeIntervalSince1970: 70_000) },
                uuid: { ids.next() }
            ),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: currentWorld.value(),
                    dependencies: dependencies
                )
            }
        )
        let firstRecord = record(id: firstID, markAgeMs: 1_000, pressedAtMs: 70_000_000)
        let secondRecordingID = RecordingID(bootTag: "boot-a", session: 8)
        let secondRecord = record(
            id: secondID,
            markSeq: 20,
            markAgeMs: 2_000,
            recordingID: secondRecordingID,
            pressedAtMs: 70_000_000
        )

        await store.send(.pressTapped) {
            $0.pendingRecords[firstRecord.recordingID] = firstRecord
            $0.runtimeLockout = .init(
                recordingID: firstRecord.recordingID,
                deadline: start.advanced(by: .seconds(17))
            )
            $0.hasRequestedProvisionalAuth = true
            $0.pendingProvisionalAuthRecordID = firstID
        }
        await creates.waitUntilStarted(firstRecord.recordingID)

        currentWorld.set(secondWorld)
        await store.send(.worldObserved(secondWorld)) {
            $0.openSegmentAnchor = self.anchor(
                seq: 20,
                seedDurMs: 2_000,
                observedAt: start,
                session: 8
            )
            $0.runtimeLockout = nil
            $0.lockoutResolvedRecordingID = secondRecordingID
        }
        #expect(store.state.canPress(world: secondWorld, now: start))

        await store.send(.pressTapped) {
            $0.pendingRecords[secondRecordingID] = secondRecord
            $0.runtimeLockout = .init(
                recordingID: secondRecordingID,
                deadline: start.advanced(by: .seconds(17))
            )
        }
        await creates.waitUntilStarted(secondRecordingID)
        #expect(store.state.pendingRecords.count == 2)

        await creates.release(secondRecordingID)
        await store.receive(.createResponded(secondRecord, success: true)) {
            $0.pendingRecords[secondRecordingID] = nil
            $0.incidents = [secondRecord]
        }
        await store.receive(.reconcile)

        await creates.release(firstRecord.recordingID)
        await store.receive(.createResponded(firstRecord, success: true)) {
            $0.pendingRecords[firstRecord.recordingID] = nil
            $0.incidents = [secondRecord, firstRecord]
            $0.pendingProvisionalAuthRecordID = nil
        }
        await store.receive(.reconcile)
        #expect(store.state.pendingRecords.isEmpty)
        #expect(Set(store.state.incidents.map(\.id)) == Set([firstID, secondID]))
        await store.finishEffects()
    }

    @Test func inProcessWallClockChangesCannotAlterRuntimeDeadline() {
        let start = clock.now
        let deadline = start.advanced(by: .seconds(17))
        let recordingID = RecordingID(bootTag: "boot-a", session: 7)
        let recording = world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000))
        var state = loadedState(now: start)
        state.runtimeLockout = .init(recordingID: recordingID, deadline: deadline)
        state.lockoutResolvedRecordingID = recordingID

        for wallNow in [
            Date(timeIntervalSince1970: 1),
            Date(timeIntervalSince1970: 9_999_999_999),
        ] {
            state.resolveLockoutIfNeeded(
                world: recording,
                wallNow: wallNow,
                continuousNow: start.advanced(by: .seconds(5))
            )
            #expect(state.runtimeLockout?.deadline == deadline)
            #expect(state.canPress(world: recording, now: start.advanced(by: .seconds(5))) == false)
        }
    }

    private func loadedState(now: ContinuousClock.Instant) -> IncidentsFeature.State {
        var state = IncidentsFeature.State()
        state.hasLoadedStore = true
        state.openSegmentAnchor = anchor(seq: 12, seedDurMs: 1_000, observedAt: now)
        return state
    }

    private func world(
        phase: RecorderPhase,
        segment: RecorderSegment?,
        session: UInt64 = 7
    ) -> World {
        CameraSamples.world(
            phase: phase,
            session: session,
            currentSegment: segment,
            bootTag: "boot-a"
        )
    }

    private func anchor(
        seq: Int,
        seedDurMs: UInt64 = 0,
        observedAt: ContinuousClock.Instant,
        session: UInt64 = 7
    ) -> IncidentsFeature.OpenSegmentAnchor {
        IncidentsFeature.OpenSegmentAnchor(
            recordingID: RecordingID(bootTag: "boot-a", session: session),
            seq: seq,
            seedDurMs: seedDurMs,
            observedAt: observedAt
        )
    }

    private func record(
        id: UUID,
        markSeq: Int = 12,
        markAgeMs: UInt64,
        status: IncidentStatus = .pending,
        recordingID: RecordingID = RecordingID(bootTag: "boot-a", session: 7),
        pressedAtMs: UInt64 = 1_784_480_523_000,
        preMs: UInt64 = IncidentRecord.defaultPreMs,
        postMs: UInt64 = IncidentRecord.defaultPostMs,
        slackMs: UInt64 = IncidentRecord.defaultSlackMs
    ) -> IncidentRecord {
        var record = IncidentRecord(
            id: id,
            pressedAtMs: pressedAtMs,
            recordingID: recordingID,
            markSeq: markSeq,
            markAgeMs: markAgeMs,
            preMs: preMs,
            postMs: postMs,
            slackMs: slackMs
        )
        switch status {
        case .pending:
            break
        case .saved:
            record.wanted[0].markClipped()
        case .partial:
            record.wanted[0].markLost(.inferredAbsence)
        }
        return record
    }

    private func makeLifecycleStore(
        state: IncidentsFeature.State,
        ledger: IncidentEffectLedger
    ) -> TestStore<IncidentsFeature.State, IncidentsFeature.Action, AppDependencies> {
        TestStore(
            initialState: state,
            dependencies: AppDependencies(
                incidentStore: IncidentStore(
                    list: { [] },
                    create: { _ in },
                    update: { _ in },
                    delete: { id in await ledger.append("delete:\(id)") },
                    deleteUnreadable: { _ in },
                    directoryURL: { _ in URL(filePath: "/tmp") }
                ),
                incidentNotifier: IncidentNotifier(
                    requestProvisionalAuth: {},
                    scheduleNudge: { id, fireIn in
                        await ledger.append("schedule:\(id):\(fireIn == .seconds(180))")
                    },
                    cancelNudge: { id in await ledger.append("cancel:\(id)") }
                )
            ),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: nil,
                    dependencies: dependencies
                )
            }
        )
    }
}

enum RecorderEndWitness: Sendable {
    case failed
    case differentSession
}

private final class InstantSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ContinuousClock.Instant]

    init(_ values: [ContinuousClock.Instant]) {
        self.values = values
    }

    func next() -> ContinuousClock.Instant {
        lock.withLock { values.removeFirst() }
    }
}

private final class InstantBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant

    init(_ instant: ContinuousClock.Instant) {
        self.instant = instant
    }

    func value() -> ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func set(_ instant: ContinuousClock.Instant) {
        lock.withLock { self.instant = instant }
    }
}

private actor IncidentEffectLedger {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func events() -> [String] { values }

    func waitForCount(_ count: Int) async {
        while values.count < count {
            await Task.yield()
        }
    }
}

private actor IncidentRecordBox {
    private var record: IncidentRecord?

    func set(_ record: IncidentRecord) { self.record = record }
    func value() -> IncidentRecord? { record }
}

private actor IncidentListSequence {
    private var calls = 0

    func next() throws -> [StoredIncident] {
        calls += 1
        if calls == 1 { throw IncidentListError.failed }
        return []
    }

    func callCount() -> Int { calls }
}

private enum IncidentListError: Error {
    case failed
}

private actor IncidentCreateGate {
    private var started: Set<RecordingID> = []
    private var continuations: [RecordingID: CheckedContinuation<Void, Never>] = [:]

    func create(_ record: IncidentRecord) async {
        started.insert(record.recordingID)
        await withCheckedContinuation { continuation in
            continuations[record.recordingID] = continuation
        }
    }

    func waitUntilStarted(_ recordingID: RecordingID) async {
        while started.contains(recordingID) == false {
            await Task.yield()
        }
    }

    func release(_ recordingID: RecordingID) {
        continuations.removeValue(forKey: recordingID)?.resume()
    }
}

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock { values.removeFirst() }
    }
}

private final class WorldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var world: World

    init(_ world: World) {
        self.world = world
    }

    func value() -> World {
        lock.withLock { world }
    }

    func set(_ world: World) {
        lock.withLock { self.world = world }
    }
}
