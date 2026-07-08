import Testing
@testable import DanCam

struct HomeRowTests {
    @Test func composeShowsLiveRowOnlyWhenRecorderTruthHasCurrentSegment() throws {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)
        let now = clock.now

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .idle,
            recorder: .unknown,
            previousLive: nil,
            now: now
        ) == [.finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .idle,
            recorder: .live(recorder(currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.pending, .finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: nil)),
            previousLive: ticking(sessionId: 7, id: 7, seedDurMs: 1_000, anchor: now),
            now: now
        ) == [.finished(clip)])

        let rows = HomeRow.compose(
            clips: [clip],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 1_000))),
            previousLive: nil,
            now: now
        )

        #expect(rows.count == 2)
        let live = try #require(rows.first?.liveSegment)
        #expect(live.sessionId == 7)
        #expect(live.id == 7)
        #expect(live.elapsed == .ticking(seedDurMs: 1_000, anchor: now))
        #expect(Array(rows.dropFirst()) == [.finished(clip)])
    }

    @Test func composePreservesAnchorWhenSameTickingSegmentHasNoPiDuration() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)

        let rows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: nil))),
            previousLive: previous,
            now: anchor.advanced(by: .seconds(3))
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.sessionId == 7)
        #expect(live.id == 7)
        #expect(live.elapsed == .ticking(seedDurMs: 5_000, anchor: anchor))
    }

    @Test func composeReseedsWhenSegmentIdChanges() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let rows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 8, durMs: 400))),
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.sessionId == 7)
        #expect(live.id == 8)
        #expect(live.elapsed == .ticking(seedDurMs: 400, anchor: now))
    }

    @Test func composeReseedsWhenSessionChanges() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let rows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(session: 8, currentSegment: RecorderSegment(id: 7, durMs: 200))),
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.sessionId == 8)
        #expect(live.id == 7)
        #expect(live.elapsed == .ticking(seedDurMs: 200, anchor: now))
    }

    @Test func composeReseedsSameTickingSegmentFromPiDurationWithoutTickingBackward() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 10_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let clampedRows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            previousLive: previous,
            now: now
        )
        let clamped = try #require(clampedRows.first?.liveSegment)
        #expect(clamped.elapsed == .ticking(seedDurMs: 13_000, anchor: now))

        let advancedRows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 15_000))),
            previousLive: previous,
            now: now
        )
        let advanced = try #require(advancedRows.first?.liveSegment)
        #expect(advanced.elapsed == .ticking(seedDurMs: 15_000, anchor: now))
    }

    @Test func lastKnownFreezesFromTickingAtElapsedNow() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let now = anchor.advanced(by: .seconds(3))
        let previous = ticking(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)

        let rows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 7, durMs: 6_000))),
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.elapsed == .frozen(durMs: 8_000))
        #expect(live.isTicking == false)
    }

    @Test func frozenLiveRowStaysFrozenAcrossRepeatedLastKnownComposes() throws {
        let clock = ContinuousClock()
        let now = clock.now.advanced(by: .seconds(3))
        let previous = frozen(sessionId: 7, id: 7, durMs: 8_000)

        let rows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.elapsed == .frozen(durMs: 8_000))
        #expect(live.isTicking == false)
    }

    @Test func lastKnownWithoutPreviousLiveFreezesAtSegmentDurationOrZero() throws {
        let clock = ContinuousClock()
        let now = clock.now

        let explicitRows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            previousLive: nil,
            now: now
        )
        let explicit = try #require(explicitRows.first?.liveSegment)
        #expect(explicit.elapsed == .frozen(durMs: 12_000))

        let missingRows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .lastKnown(recorder(currentSegment: RecorderSegment(id: 8, durMs: nil))),
            previousLive: nil,
            now: now
        )
        let missing = try #require(missingRows.first?.liveSegment)
        #expect(missing.elapsed == .frozen(durMs: 0))
    }

    @Test func liveThawsFrozenWithDurationUsingMaxSeedAtNow() throws {
        let clock = ContinuousClock()
        let now = clock.now
        let previous = frozen(sessionId: 7, id: 7, durMs: 10_000)

        let clampedRows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 9_000))),
            previousLive: previous,
            now: now
        )
        let clamped = try #require(clampedRows.first?.liveSegment)
        #expect(clamped.elapsed == .ticking(seedDurMs: 10_000, anchor: now))
        #expect(clamped.isTicking)

        let advancedRows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: 12_000))),
            previousLive: previous,
            now: now
        )
        let advanced = try #require(advancedRows.first?.liveSegment)
        #expect(advanced.elapsed == .ticking(seedDurMs: 12_000, anchor: now))
        #expect(advanced.isTicking)
    }

    @Test func liveThawsFrozenWithoutDurationUsingFrozenValueAtNow() throws {
        let clock = ContinuousClock()
        let now = clock.now
        let previous = frozen(sessionId: 7, id: 7, durMs: 10_000)

        let rows = HomeRow.compose(
            clips: [],
            recording: .idle,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 7, durMs: nil))),
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.elapsed == .ticking(seedDurMs: 10_000, anchor: now))
        #expect(live.isTicking)
    }

    @Test func composeShowsPendingRowWhileCommandStartsBeforeWorldReacts() {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .starting,
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            previousLive: nil,
            now: clock.now
        ) == [.pending, .finished(clip)])
    }

    @Test func composeShowsPendingRowWhenStartSucceedsBeforeEventsFold() {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .recording,
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            previousLive: nil,
            now: clock.now
        ) == [.pending, .finished(clip)])
    }

    @Test func composeShowsPendingRowForWorldStartGapWithoutLocalCommand() {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)
        let now = clock.now

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .idle,
            recorder: .live(recorder(phase: .starting, currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.pending, .finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .unknown,
            recorder: .live(recorder(phase: .recording, currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.pending, .finished(clip)])
    }

    @Test func composeHidesPendingRowWhenOffline() throws {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)
        let now = clock.now

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .starting,
            recorder: .lastKnown(recorder(phase: .recording, currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .starting,
            recorder: .unknown,
            previousLive: nil,
            now: now
        ) == [.finished(clip)])

        let rows = HomeRow.compose(
            clips: [clip],
            recording: .starting,
            recorder: .lastKnown(recorder(
                phase: .recording,
                currentSegment: RecorderSegment(id: 7, durMs: 1_000)
            )),
            previousLive: nil,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.elapsed == .frozen(durMs: 1_000))
        #expect(Array(rows.dropFirst()) == [.finished(clip)])
    }

    @Test func composeHidesPendingRowOnFailedStart() {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)
        let now = clock.now

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .failed("HTTP 503"),
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .failed("Recorder failed"),
            recorder: .live(recorder(phase: .error, currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.finished(clip)])
    }

    @Test func composeHidesPendingRowDuringStopFlow() {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)
        let now = clock.now

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .stopping,
            recorder: .live(recorder(phase: .stopping, currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recording: .idle,
            recorder: .live(recorder(phase: .idle, currentSegment: nil)),
            previousLive: nil,
            now: now
        ) == [.finished(clip)])
    }

    @Test func composeNeverShowsPendingAndLiveTogether() throws {
        let clock = ContinuousClock()
        let rows = HomeRow.compose(
            clips: [CameraSamples.clip(id: 4)],
            recording: .starting,
            recorder: .live(recorder(
                phase: .recording,
                currentSegment: RecorderSegment(id: 7, durMs: 1_000)
            )),
            previousLive: nil,
            now: clock.now
        )

        _ = try #require(rows.first?.liveSegment)
        #expect(rows.contains(.pending) == false)
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
