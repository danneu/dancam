import Testing
@testable import DanCam

struct DriveDetailStateTests {
    @Test func filtersTargetDriveAndKeepsNewestFirstOrder() {
        let state = DriveDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: "other"),
                clip(id: 7, bootTag: "target"),
                clip(id: 6, bootTag: nil),
            ],
            nextCursor: nil,
            bootTag: "target"
        )

        #expect(state.clips.map(\.id) == [9, 7])
        #expect(state.paginationFrontier == 6)
        #expect(state.canLoadMore == false)
    }

    @Test func canLoadMoreStaysTrueUntilAnOlderDifferentStampedDriveIsLoaded() {
        let targetTail = DriveDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: "target"),
            ],
            nextCursor: "8",
            bootTag: "target"
        )
        let bareTail = DriveDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: nil),
            ],
            nextCursor: "8",
            bootTag: "target"
        )
        let emptyLoadedSet = DriveDetailState(
            allClips: [],
            nextCursor: "8",
            bootTag: "target"
        )
        let differentStampedTail = DriveDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: "other"),
            ],
            nextCursor: "8",
            bootTag: "target"
        )
        let noCursor = DriveDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
            ],
            nextCursor: nil,
            bootTag: "target"
        )

        #expect(targetTail.canLoadMore)
        #expect(bareTail.canLoadMore)
        #expect(emptyLoadedSet.canLoadMore)
        #expect(differentStampedTail.canLoadMore == false)
        #expect(noCursor.canLoadMore == false)
    }

    @Test func bareGapPagingKeepsTargetClipsAndStopsOnlyAfterDifferentStampedTail() {
        let throughBareGap = DriveDetailState(
            allClips: [
                clip(id: 10, bootTag: "target"),
                clip(id: 9, bootTag: nil),
                clip(id: 8, bootTag: "target"),
            ],
            nextCursor: "8",
            bootTag: "target"
        )
        let unresolvedBareTail = DriveDetailState(
            allClips: [
                clip(id: 10, bootTag: "target"),
                clip(id: 9, bootTag: nil),
            ],
            nextCursor: "9",
            bootTag: "target"
        )
        let provenDifferentTail = DriveDetailState(
            allClips: [
                clip(id: 10, bootTag: "target"),
                clip(id: 9, bootTag: nil),
                clip(id: 8, bootTag: "target"),
                clip(id: 7, bootTag: "other"),
            ],
            nextCursor: "7",
            bootTag: "target"
        )

        #expect(throughBareGap.clips.map(\.id) == [10, 8])
        #expect(throughBareGap.canLoadMore)
        #expect(unresolvedBareTail.clips.map(\.id) == [10])
        #expect(unresolvedBareTail.canLoadMore)
        #expect(provenDifferentTail.clips.map(\.id) == [10, 8])
        #expect(provenDifferentTail.canLoadMore == false)
    }

    private func clip(id: Int, bootTag: String?) -> Clip {
        CameraSamples.clip(id: id, durMs: 30_000, timeApproximate: false, bootTag: bootTag)
    }
}
