import Testing
@testable import DanCam

struct LiveRecordingStatusTests {
    @Test func fromDerivesNonePendingAndLiveFromRecorderTruth() throws {
        let clock = ContinuousClock()
        let now = clock.now

        #expect(status(recording: .idle, recorder: .unknown, now: now) == .none)
        #expect(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: nil)),
            now: now
        ) == .pending)
        #expect(status(
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: nil)),
            previous: ticking(sessionId: 7, id: 7, seedDurMs: 1_000, anchor: now),
            now: now
        ) == .none)

        let live = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 1_000))),
            now: now
        ).liveSegment)
        #expect(live.sessionId == 7)
        #expect(live.id == 7)
        #expect(live.elapsed == .ticking(seedDurMs: 1_000, anchor: now))
    }

    @Test func fromPreservesAnchorWhenSameTickingSegmentHasNoPiDuration() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)

        let live = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: nil))),
            previous: previous,
            now: anchor.advanced(by: .seconds(3))
        ).liveSegment)

        #expect(live.sessionId == 7)
        #expect(live.id == 7)
        #expect(live.elapsed == .ticking(seedDurMs: 5_000, anchor: anchor))
    }

    @Test func fromReseedsWhenSegmentIdChanges() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let live = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 8, durMs: 400))),
            previous: previous,
            now: now
        ).liveSegment)

        #expect(live.sessionId == 7)
        #expect(live.id == 8)
        #expect(live.elapsed == .ticking(seedDurMs: 400, anchor: now))
    }

    @Test func fromReseedsWhenSessionChanges() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let live = try #require(status(
            recording: .idle,
            recorder: .live(recorder(session: 8, currentSegment: RecorderSegment(id: 7, durMs: 200))),
            previous: previous,
            now: now
        ).liveSegment)

        #expect(live.sessionId == 8)
        #expect(live.id == 7)
        #expect(live.elapsed == .ticking(seedDurMs: 200, anchor: now))
    }

    @Test func fromReseedsSameTickingSegmentFromPiDurationWithoutTickingBackward() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 10_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let clamped = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            previous: previous,
            now: now
        ).liveSegment)
        #expect(clamped.elapsed == .ticking(seedDurMs: 13_000, anchor: now))

        let advanced = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 15_000))),
            previous: previous,
            now: now
        ).liveSegment)
        #expect(advanced.elapsed == .ticking(seedDurMs: 15_000, anchor: now))
    }

    @Test func lastKnownFreezesFromTickingAtElapsedNow() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let now = anchor.advanced(by: .seconds(3))
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)

        let live = try #require(status(
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 7, durMs: 6_000))),
            previous: previous,
            now: now
        ).liveSegment)

        #expect(live.elapsed == .frozen(durMs: 8_000))
        #expect(live.isTicking == false)
    }

    @Test func frozenStatusStaysFrozenAcrossRepeatedLastKnownDerivations() throws {
        let clock = ContinuousClock()
        let now = clock.now.advanced(by: .seconds(3))
        let previous = frozen(sessionId: 7, id: 7, durMs: 8_000)

        let live = try #require(status(
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            previous: previous,
            now: now
        ).liveSegment)

        #expect(live.elapsed == .frozen(durMs: 8_000))
        #expect(live.isTicking == false)
    }

    @Test func lastKnownWithoutPreviousLiveFreezesAtSegmentDurationOrZero() throws {
        let clock = ContinuousClock()
        let now = clock.now

        let explicit = try #require(status(
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            now: now
        ).liveSegment)
        #expect(explicit.elapsed == .frozen(durMs: 12_000))

        let missing = try #require(status(
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 8, durMs: nil))),
            now: now
        ).liveSegment)
        #expect(missing.elapsed == .frozen(durMs: 0))
    }

    @Test func liveThawsFrozenWithDurationUsingMaxSeedAtNow() throws {
        let clock = ContinuousClock()
        let now = clock.now
        let previous = frozen(sessionId: 7, id: 7, durMs: 10_000)

        let clamped = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 9_000))),
            previous: previous,
            now: now
        ).liveSegment)
        #expect(clamped.elapsed == .ticking(seedDurMs: 10_000, anchor: now))
        #expect(clamped.isTicking)

        let advanced = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            previous: previous,
            now: now
        ).liveSegment)
        #expect(advanced.elapsed == .ticking(seedDurMs: 12_000, anchor: now))
        #expect(advanced.isTicking)
    }

    @Test func liveThawsFrozenWithoutDurationUsingFrozenValueAtNow() throws {
        let clock = ContinuousClock()
        let now = clock.now
        let previous = frozen(sessionId: 7, id: 7, durMs: 10_000)

        let live = try #require(status(
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: nil))),
            previous: previous,
            now: now
        ).liveSegment)

        #expect(live.elapsed == .ticking(seedDurMs: 10_000, anchor: now))
        #expect(live.isTicking)
    }

    @Test func fromShowsPendingWhileCommandStartsBeforeWorldReacts() {
        let clock = ContinuousClock()

        #expect(status(
            recording: .starting,
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            now: clock.now
        ) == .pending)
    }

    @Test func fromShowsPendingWhenStartSucceedsBeforeEventsFold() {
        let clock = ContinuousClock()

        #expect(status(
            recording: .recording,
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            now: clock.now
        ) == .pending)
    }

    @Test func fromShowsPendingForWorldStartGapWithoutLocalCommand() {
        let clock = ContinuousClock()
        let now = clock.now

        #expect(status(
            recording: .idle,
            recorder: .live(recorder(phase: .starting, currentSegment: nil)),
            now: now
        ) == .pending)

        #expect(status(
            recording: .unknown,
            recorder: .live(recorder(phase: .recording, currentSegment: nil)),
            now: now
        ) == .pending)
    }

    @Test func fromHidesPendingWhenOffline() throws {
        let clock = ContinuousClock()
        let now = clock.now

        #expect(status(
            recording: .starting,
            recorder: .lastKnown(recorder(phase: .recording, currentSegment: nil)),
            now: now
        ) == .none)

        #expect(status(recording: .starting, recorder: .unknown, now: now) == .none)

        let live = try #require(status(
            recording: .starting,
            recorder: .lastKnown(recorder(
                phase: .recording,
                currentSegment: RecorderSegment(id: 7, durMs: 1_000)
            )),
            now: now
        ).liveSegment)

        #expect(live.elapsed == .frozen(durMs: 1_000))
    }

    @Test func fromHidesPendingOnFailedStart() {
        let clock = ContinuousClock()
        let now = clock.now

        #expect(status(
            recording: .failed("HTTP 503"),
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            now: now
        ) == .none)

        #expect(status(
            recording: .failed("Recorder failed"),
            recorder: .live(recorder(phase: .error, currentSegment: nil)),
            now: now
        ) == .none)
    }

    @Test func fromHidesPendingDuringStopFlow() {
        let clock = ContinuousClock()
        let now = clock.now

        #expect(status(
            recording: .stopping,
            recorder: .live(recorder(phase: .stopping, currentSegment: nil)),
            now: now
        ) == .none)

        #expect(status(
            recording: .idle,
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            now: now
        ) == .none)
    }

    @Test func fromPrefersLiveOverPending() throws {
        let clock = ContinuousClock()
        let live = try #require(status(
            recording: .starting,
            recorder: .live(recorder(
                phase: .recording,
                currentSegment: RecorderSegment(id: 7, durMs: 1_000)
            )),
            now: clock.now
        ).liveSegment)

        #expect(live.id == 7)
    }

    @Test func recordingAttributionPairsBootTagWithFreshnessAndSession() {
        let clock = ContinuousClock()
        let tickingSegment = ticking(sessionId: 5, id: 7, seedDurMs: 1_000, anchor: clock.now)
        let frozenSegment = frozen(sessionId: 6, id: 7, durMs: 1_000)
        let liveRecorder = RecorderTruth.live(recorder(session: 9, currentSegment: nil))

        // No world boot tag, or a .none status -> no attribution regardless of recorder.
        #expect(RecordingAttribution.from(status: .pending, worldBootTag: nil, recorder: liveRecorder) == nil)
        #expect(RecordingAttribution.from(status: .none, worldBootTag: "7f3a91c2b0d4", recorder: liveRecorder) == nil)

        // Pending pairs the world boot tag with the live recorder snapshot's session.
        #expect(RecordingAttribution.from(
            status: .pending,
            worldBootTag: "7f3a91c2b0d4",
            recorder: liveRecorder
        ) == RecordingAttribution(id: RecordingID(bootTag: "7f3a91c2b0d4", session: 9), freshness: .live))

        // A non-live recorder cannot source a session, so pending degrades to no attribution.
        #expect(RecordingAttribution.from(
            status: .pending,
            worldBootTag: "7f3a91c2b0d4",
            recorder: .unknown
        ) == nil)

        // Ticking/frozen pair the world boot tag with the live segment's own session.
        #expect(RecordingAttribution.from(
            status: .live(tickingSegment),
            worldBootTag: "7f3a91c2b0d4",
            recorder: liveRecorder
        ) == RecordingAttribution(id: RecordingID(bootTag: "7f3a91c2b0d4", session: 5), freshness: .live))
        #expect(RecordingAttribution.from(
            status: .live(frozenSegment),
            worldBootTag: "7f3a91c2b0d4",
            recorder: liveRecorder
        ) == RecordingAttribution(id: RecordingID(bootTag: "7f3a91c2b0d4", session: 6), freshness: .lastKnown))
    }

    @Test func liveRecordingInputsUseLastKnownWorldBootTag() {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 7, durMs: 1_000),
            bootTag: "7f3a91c2b0d4"
        )
        let state = AppFeature.State(
            link: .offline(last: world),
            recording: .recording
        )

        #expect(LiveRecordingInputs.from(state) == LiveRecordingInputs(
            recording: .recording,
            recorder: .lastKnown(world.recorder),
            worldBootTag: "7f3a91c2b0d4"
        ))
    }

    private func status(
        recording: RecordingFeature.State,
        recorder: RecorderTruth,
        previous: LiveSegment? = nil,
        now: ContinuousClock.Instant
    ) -> LiveRecordingStatus {
        LiveRecordingStatus.from(
            recording: recording,
            recorder: recorder,
            previous: previous,
            now: now
        )
    }

    private func recorder(
        phase: RecorderPhase = .recording,
        session: UInt64 = 7,
        currentSegment: RecorderSegment?,
        detail: String? = nil
    ) -> RecorderSnapshot {
        RecorderSnapshot(
            phase: phase,
            session: session,
            currentSegment: currentSegment,
            detail: detail
        )
    }

    private func ticking(
        sessionId: UInt64,
        id: Int,
        seedDurMs: UInt64?,
        anchor: ContinuousClock.Instant
    ) -> LiveSegment {
        LiveSegment(
            sessionId: sessionId,
            id: id,
            elapsed: .ticking(seedDurMs: seedDurMs, anchor: anchor)
        )
    }

    private func frozen(
        sessionId: UInt64,
        id: Int,
        durMs: UInt64
    ) -> LiveSegment {
        LiveSegment(
            sessionId: sessionId,
            id: id,
            elapsed: .frozen(durMs: durMs)
        )
    }
}
