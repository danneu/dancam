import Testing
@testable import DanCam

struct HomeRowTests {
    @Test func composeShowsLiveRowOnlyWhenRecorderHasCurrentSegment() {
        let clock = ContinuousClock()
        let clip = CameraSamples.clip(id: 4)

        #expect(HomeRow.compose(
            clips: [clip],
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: nil,
                detail: nil
            ),
            previousLive: nil,
            now: clock.now
        ) == [.finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recorder: RecorderSnapshot(
                phase: .idle,
                session: 7,
                currentSegment: nil,
                detail: nil
            ),
            previousLive: LiveSegment(
                sessionId: 7,
                id: 7,
                seedDurMs: 1_000,
                anchor: clock.now
            ),
            now: clock.now
        ) == [.finished(clip)])

        let rows = HomeRow.compose(
            clips: [clip],
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 7, durMs: 1_000),
                detail: nil
            ),
            previousLive: nil,
            now: clock.now
        )

        #expect(rows.count == 2)
        #expect(rows.first?.liveSegment?.sessionId == 7)
        #expect(rows.first?.liveSegment?.id == 7)
        #expect(Array(rows.dropFirst()) == [.finished(clip)])
    }

    @Test func composePreservesAnchorWhenSameSegmentHasNoPiDuration() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = LiveSegment(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)

        let rows = HomeRow.compose(
            clips: [],
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 7, durMs: nil),
                detail: nil
            ),
            previousLive: previous,
            now: anchor.advanced(by: .seconds(3))
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.sessionId == 7)
        #expect(live.id == 7)
        #expect(live.seedDurMs == 5_000)
        #expect(live.anchor == anchor)
    }

    @Test func composeReseedsWhenSegmentIdChanges() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = LiveSegment(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let rows = HomeRow.compose(
            clips: [],
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 8, durMs: 400),
                detail: nil
            ),
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.sessionId == 7)
        #expect(live.id == 8)
        #expect(live.seedDurMs == 400)
        #expect(live.anchor == now)
    }

    @Test func composeReseedsWhenSessionChanges() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = LiveSegment(sessionId: 7, id: 7, seedDurMs: 5_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let rows = HomeRow.compose(
            clips: [],
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 8,
                currentSegment: RecorderSegment(id: 7, durMs: 200),
                detail: nil
            ),
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.sessionId == 8)
        #expect(live.id == 7)
        #expect(live.seedDurMs == 200)
        #expect(live.anchor == now)
    }

    @Test func composeReseedsSameSegmentFromPiDurationWithoutTickingBackward() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = LiveSegment(sessionId: 7, id: 7, seedDurMs: 10_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let clampedRows = HomeRow.compose(
            clips: [],
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 7, durMs: 12_000),
                detail: nil
            ),
            previousLive: previous,
            now: now
        )
        let clamped = try #require(clampedRows.first?.liveSegment)
        #expect(clamped.seedDurMs == 13_000)
        #expect(clamped.anchor == now)

        let advancedRows = HomeRow.compose(
            clips: [],
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 7, durMs: 15_000),
                detail: nil
            ),
            previousLive: previous,
            now: now
        )
        let advanced = try #require(advancedRows.first?.liveSegment)
        #expect(advanced.seedDurMs == 15_000)
        #expect(advanced.anchor == now)
    }
}
