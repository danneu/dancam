import Foundation
import Testing
@testable import DanCam

@MainActor
struct IncidentsFeatureTests {
    private let clock = ContinuousClock()

    @Test func enablementRequiresOnlineRecordingAnchorAndNoCooldown() {
        let recording = world(phase: .recording, segment: RecorderSegment(id: 12, durMs: 1_000))
        let idle = world(phase: .idle, segment: nil)
        var state = IncidentsFeature.State()

        #expect(state.canPress(world: nil) == false)
        #expect(state.canPress(world: idle) == false)
        #expect(state.canPress(world: recording) == false)

        state.openSegmentAnchor = anchor(seq: 12, observedAt: clock.now)
        #expect(state.canPress(world: recording))

        state.isPressFeedbackVisible = true
        #expect(state.canPress(world: recording) == false)
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

    @Test func persistedRecordPrecedesAuthNudgeAndReconcile() async throws {
        let ledger = IncidentEffectLedger()
        let sleepGate = IncidentSleepGate()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let now = clock.now
        var state = IncidentsFeature.State()
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
                    scheduleNudge: { _, _ in await ledger.append("nudge") },
                    cancelNudge: { _ in }
                ),
                sleep: { duration in await sleepGate.sleep(duration) },
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
            $0.pendingRecord = self.record(id: id, markAgeMs: 3_000)
            $0.isPressFeedbackVisible = true
        }
        await store.receive(.createResponded(record(id: id, markAgeMs: 3_000), success: true)) {
            $0.pendingRecord = nil
            $0.incidents = [self.record(id: id, markAgeMs: 3_000)]
            $0.hasRequestedProvisionalAuth = true
        }
        await store.receive(.reconcile)
        await ledger.waitForCount(3)

        let events = await ledger.events()
        #expect(events == ["persist:\(id)", "auth", "nudge"])
        #expect(store.state.isPressFeedbackVisible)

        await sleepGate.release()
        await store.receive(.cooldownFinished) {
            $0.isPressFeedbackVisible = false
        }
        await store.finishEffects()
    }

    @Test func rolloverRaceKeepsPreviousSegmentWithAgePastItsDuration() async {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let observedAt = clock.now
        let saved = IncidentRecordBox()
        var state = IncidentsFeature.State()
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
            $0.pendingRecord = self.record(id: id, markSeq: 41, markAgeMs: 31_500)
            $0.isPressFeedbackVisible = true
        }
        await store.receive(.createResponded(record(id: id, markSeq: 41, markAgeMs: 31_500), success: true)) {
            $0.pendingRecord = nil
            $0.incidents = [self.record(id: id, markSeq: 41, markAgeMs: 31_500)]
            $0.hasRequestedProvisionalAuth = true
        }
        await store.receive(.reconcile)
        await store.receive(.cooldownFinished) {
            $0.isPressFeedbackVisible = false
        }
        await store.finishEffects()

        let persisted = await saved.value()
        #expect(persisted?.markSeq == 41)
        #expect(persisted?.markAgeMs == 31_500)
    }

    private func world(phase: RecorderPhase, segment: RecorderSegment?) -> World {
        CameraSamples.world(
            phase: phase,
            currentSegment: segment,
            bootTag: "boot-a"
        )
    }

    private func anchor(
        seq: Int,
        seedDurMs: UInt64 = 0,
        observedAt: ContinuousClock.Instant
    ) -> IncidentsFeature.OpenSegmentAnchor {
        IncidentsFeature.OpenSegmentAnchor(
            recordingID: RecordingID(bootTag: "boot-a", session: 7),
            seq: seq,
            seedDurMs: seedDurMs,
            observedAt: observedAt
        )
    }

    private func record(
        id: UUID,
        markSeq: Int = 12,
        markAgeMs: UInt64
    ) -> IncidentRecord {
        IncidentRecord(
            id: id,
            pressedAtMs: 1_784_480_523_000,
            recordingID: RecordingID(bootTag: "boot-a", session: 7),
            markSeq: markSeq,
            markAgeMs: markAgeMs
        )
    }
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

private actor IncidentSleepGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func sleep(_ duration: Duration) async {
        guard duration == .seconds(3), released == false else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor IncidentRecordBox {
    private var record: IncidentRecord?

    func set(_ record: IncidentRecord) { self.record = record }
    func value() -> IncidentRecord? { record }
}
