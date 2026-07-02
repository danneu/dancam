import Testing
@testable import DanCam

struct HomeRowDiffTests {
    @Test func identicalListsHaveNoReconfigures() {
        let rows: [HomeRow] = [
            .finished(CameraSamples.clip(id: 4, durMs: 1_000)),
            .finished(CameraSamples.clip(id: 3, durMs: 2_000)),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: rows, new: rows) == [])
    }

    @Test func changedFinishedClipReconfiguresItsExistingID() {
        let old: [HomeRow] = [
            .finished(CameraSamples.clip(id: 4, durMs: 1_000)),
            .finished(CameraSamples.clip(id: 3, durMs: 2_000)),
        ]
        let new: [HomeRow] = [
            .finished(CameraSamples.clip(id: 4, durMs: 2_000)),
            .finished(CameraSamples.clip(id: 3, durMs: 2_000)),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: old, new: new) == [.finished(4)])
    }

    @Test func appendedFinishedClipIsAnInsertNotAReconfigure() {
        let old: [HomeRow] = [
            .finished(CameraSamples.clip(id: 4, durMs: 1_000)),
        ]
        let new: [HomeRow] = [
            .finished(CameraSamples.clip(id: 5, durMs: 1_000)),
            .finished(CameraSamples.clip(id: 4, durMs: 1_000)),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: old, new: new) == [])
    }

    @Test func removedFinishedClipIsNotReconfigured() {
        let old: [HomeRow] = [
            .finished(CameraSamples.clip(id: 5, durMs: 1_000)),
            .finished(CameraSamples.clip(id: 4, durMs: 1_000)),
        ]
        let new: [HomeRow] = [
            .finished(CameraSamples.clip(id: 4, durMs: 1_000)),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: old, new: new) == [])
    }

    @Test func reorderedSameContentDoesNotReconfigure() {
        let old: [HomeRow] = [
            .finished(CameraSamples.clip(id: 5, durMs: 1_000)),
            .finished(CameraSamples.clip(id: 4, durMs: 2_000)),
        ]
        let new: [HomeRow] = [
            .finished(CameraSamples.clip(id: 4, durMs: 2_000)),
            .finished(CameraSamples.clip(id: 5, durMs: 1_000)),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: old, new: new) == [])
    }

    @Test func stableLiveRowDoesNotReconfigureAndSegmentChangeIsInsertRemove() {
        let clock = ContinuousClock()
        let live = LiveSegment(sessionId: 7, id: 4, seedDurMs: 1_000, anchor: clock.now)
        let nextLive = LiveSegment(sessionId: 7, id: 5, seedDurMs: 1_000, anchor: clock.now)

        #expect(HomeRowDiff.reconfiguredIDs(old: [.live(live)], new: [.live(live)]) == [])
        #expect(HomeRowDiff.reconfiguredIDs(old: [.live(live)], new: [.live(nextLive)]) == [])
    }

    @Test func liveAndFinishedRowsWithSameNumericIDHaveDistinctIdentifiers() {
        let clock = ContinuousClock()
        let rows: [HomeRow] = [
            .live(LiveSegment(sessionId: 7, id: 4, seedDurMs: nil, anchor: clock.now)),
            .finished(CameraSamples.clip(id: 4)),
        ]
        let ids = rows.map(\.id)

        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(.live(session: 7, id: 4)))
        #expect(ids.contains(.finished(4)))
    }
}
