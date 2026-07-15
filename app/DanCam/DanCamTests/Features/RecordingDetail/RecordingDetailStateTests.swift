import Testing
@testable import DanCam

struct RecordingDetailStateTests {
    private let target = RecordingID(bootTag: "target", session: 7)

    @Test func filtersTargetRecordingAndKeepsNewestFirstOrder() {
        let state = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: "other"),
                clip(id: 7, bootTag: "target"),
                clip(id: 6, bootTag: nil),
            ],
            nextCursor: nil,
            recordingID: target
        )

        #expect(state.clips.map(\.id) == [9, 7])
        #expect(state.paginationFrontier == 6)
        #expect(state.canLoadMore == false)
    }

    @Test func filtersKeepsOnlyRequestedRecordingAcrossSameBootDifferentSession() {
        // Two sessions of the same boot: the RecordingID filter keeps only the requested one,
        // where the old bootTag filter would have kept both.
        let state = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target", session: 7),
                clip(id: 8, bootTag: "target", session: 8),
                clip(id: 7, bootTag: "target", session: 7),
            ],
            nextCursor: nil,
            recordingID: target
        )

        #expect(state.clips.map(\.id) == [9, 7])
    }

    @Test func canLoadMoreStaysTrueUntilAnOlderDifferentStampedRecordingIsLoaded() {
        let targetTail = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: "target"),
            ],
            nextCursor: ClipCursor(8),
            recordingID: target
        )
        let bareTail = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: nil),
            ],
            nextCursor: ClipCursor(8),
            recordingID: target
        )
        let emptyLoadedSet = RecordingDetailState(
            allClips: [],
            nextCursor: ClipCursor(8),
            recordingID: target
        )
        let differentStampedTail = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
                clip(id: 8, bootTag: "other"),
            ],
            nextCursor: ClipCursor(8),
            recordingID: target
        )
        let noCursor = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target"),
            ],
            nextCursor: nil,
            recordingID: target
        )

        #expect(targetTail.canLoadMore)
        #expect(bareTail.canLoadMore)
        #expect(emptyLoadedSet.canLoadMore)
        #expect(differentStampedTail.canLoadMore == false)
        #expect(noCursor.canLoadMore == false)
    }

    @Test func paginationStopsOnSameBootDifferentSessionTail() {
        let differentSessionTail = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target", session: 7),
                clip(id: 8, bootTag: "target", session: 8),
            ],
            nextCursor: ClipCursor(8),
            recordingID: target
        )
        let bareTail = RecordingDetailState(
            allClips: [
                clip(id: 9, bootTag: "target", session: 7),
                clip(id: 8, bootTag: nil),
            ],
            nextCursor: ClipCursor(8),
            recordingID: target
        )

        // A same-boot different-session tail is a resolved boundary -> stop paging, even with a
        // cursor; a bare (nil-facts) tail is still indeterminate -> keep paging.
        #expect(differentSessionTail.canLoadMore == false)
        #expect(bareTail.canLoadMore)
    }

    @Test func bareGapPagingKeepsTargetClipsAndStopsOnlyAfterDifferentStampedTail() {
        let throughBareGap = RecordingDetailState(
            allClips: [
                clip(id: 10, bootTag: "target"),
                clip(id: 9, bootTag: nil),
                clip(id: 8, bootTag: "target"),
            ],
            nextCursor: ClipCursor(8),
            recordingID: target
        )
        let unresolvedBareTail = RecordingDetailState(
            allClips: [
                clip(id: 10, bootTag: "target"),
                clip(id: 9, bootTag: nil),
            ],
            nextCursor: ClipCursor(9),
            recordingID: target
        )
        let provenDifferentTail = RecordingDetailState(
            allClips: [
                clip(id: 10, bootTag: "target"),
                clip(id: 9, bootTag: nil),
                clip(id: 8, bootTag: "target"),
                clip(id: 7, bootTag: "other"),
            ],
            nextCursor: ClipCursor(7),
            recordingID: target
        )

        #expect(throughBareGap.clips.map(\.id) == [10, 8])
        #expect(throughBareGap.canLoadMore)
        #expect(unresolvedBareTail.clips.map(\.id) == [10])
        #expect(unresolvedBareTail.canLoadMore)
        #expect(provenDifferentTail.clips.map(\.id) == [10, 8])
        #expect(provenDifferentTail.canLoadMore == false)
    }

    private func clip(id: Int, bootTag: String?, session: UInt64? = 7) -> Clip {
        CameraSamples.clip(
            id: id,
            durMs: 30_000,
            timeApproximate: false,
            bootTag: bootTag,
            session: bootTag == nil ? nil : session
        )
    }
}
