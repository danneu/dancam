import Testing
@testable import DanCam

struct HomeRowTests {
    @Test func composeShowsLiveRowOnlyWhenRecordingWithSegmentId() {
        let clock = ContinuousClock()
        let clip = Clip.sample(id: 4)

        #expect(HomeRow.compose(
            clips: [clip],
            recording: false,
            currentSegmentId: 7,
            currentSegmentDurMs: 1_000,
            previousLive: nil,
            now: clock.now
        ) == [.finished(clip)])

        #expect(HomeRow.compose(
            clips: [clip],
            recording: true,
            currentSegmentId: nil,
            currentSegmentDurMs: 1_000,
            previousLive: nil,
            now: clock.now
        ) == [.finished(clip)])

        let rows = HomeRow.compose(
            clips: [clip],
            recording: true,
            currentSegmentId: 7,
            currentSegmentDurMs: 1_000,
            previousLive: nil,
            now: clock.now
        )

        #expect(rows.count == 2)
        #expect(rows.first?.liveSegment?.id == 7)
        #expect(Array(rows.dropFirst()) == [.finished(clip)])
    }

    @Test func composePreservesAnchorWhenSameSegmentHasNoPiDuration() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = LiveSegment(id: 7, seedDurMs: 5_000, anchor: anchor)

        let rows = HomeRow.compose(
            clips: [],
            recording: true,
            currentSegmentId: 7,
            currentSegmentDurMs: nil,
            previousLive: previous,
            now: anchor.advanced(by: .seconds(3))
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.id == 7)
        #expect(live.seedDurMs == 5_000)
        #expect(live.anchor == anchor)
    }

    @Test func composeReseedsWhenSegmentIdChanges() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = LiveSegment(id: 7, seedDurMs: 5_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let rows = HomeRow.compose(
            clips: [],
            recording: true,
            currentSegmentId: 8,
            currentSegmentDurMs: 400,
            previousLive: previous,
            now: now
        )

        let live = try #require(rows.first?.liveSegment)
        #expect(live.id == 8)
        #expect(live.seedDurMs == 400)
        #expect(live.anchor == now)
    }

    @Test func composeReseedsSameSegmentFromPiDurationWithoutTickingBackward() throws {
        let clock = ContinuousClock()
        let anchor = clock.now
        let previous = LiveSegment(id: 7, seedDurMs: 10_000, anchor: anchor)
        let now = anchor.advanced(by: .seconds(3))

        let clampedRows = HomeRow.compose(
            clips: [],
            recording: true,
            currentSegmentId: 7,
            currentSegmentDurMs: 12_000,
            previousLive: previous,
            now: now
        )
        let clamped = try #require(clampedRows.first?.liveSegment)
        #expect(clamped.seedDurMs == 13_000)
        #expect(clamped.anchor == now)

        let advancedRows = HomeRow.compose(
            clips: [],
            recording: true,
            currentSegmentId: 7,
            currentSegmentDurMs: 15_000,
            previousLive: previous,
            now: now
        )
        let advanced = try #require(advancedRows.first?.liveSegment)
        #expect(advanced.seedDurMs == 15_000)
        #expect(advanced.anchor == now)
    }
}

private extension Clip {
    static func sample(id: Int) -> Clip {
        Clip(
            id: id,
            startMs: nil,
            durMs: nil,
            bytes: UInt64(id * 100),
            locked: false,
            etag: "\(id)-\(id * 100)",
            timeApproximate: true
        )
    }
}
