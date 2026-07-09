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

    @Test func joinedDriveClipReconfiguresStableDriveID() {
        let old: [HomeRow] = [
            .drive(drive("boot-a", clips: [
                CameraSamples.clip(id: 4, durMs: 1_000, bootTag: "boot-a"),
            ])),
        ]
        let new: [HomeRow] = [
            .drive(drive("boot-a", clips: [
                CameraSamples.clip(id: 5, durMs: 1_000, bootTag: "boot-a"),
                CameraSamples.clip(id: 4, durMs: 1_000, bootTag: "boot-a"),
            ])),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: old, new: new) == [.drive(bootTag: "boot-a", occurrence: 0)])
    }

    @Test func changedDriveClipEtagReconfiguresStableDriveID() {
        let old: [HomeRow] = [
            .drive(drive("boot-a", clips: [
                CameraSamples.clip(id: 4, durMs: 1_000, bootTag: "boot-a"),
            ])),
        ]
        let newClip = Clip(
            id: 4,
            startMs: nil,
            durMs: 1_000,
            bytes: 400,
            locked: false,
            etag: "4-updated",
            timeApproximate: true,
            bootTag: "boot-a"
        )
        let new: [HomeRow] = [
            .drive(drive("boot-a", clips: [newClip])),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: old, new: new) == [.drive(bootTag: "boot-a", occurrence: 0)])
    }

    @Test func recordingFreshnessFlipReconfiguresStableDriveID() {
        let clips = [
            CameraSamples.clip(id: 4, durMs: 1_000, bootTag: "boot-a"),
        ]
        let old: [HomeRow] = [
            .drive(drive("boot-a", clips: clips, recording: .live)),
        ]
        let new: [HomeRow] = [
            .drive(drive("boot-a", clips: clips, recording: .lastKnown)),
        ]

        #expect(HomeRowDiff.reconfiguredIDs(old: old, new: new) == [.drive(bootTag: "boot-a", occurrence: 0)])
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

    private func drive(
        _ bootTag: String,
        clips: [Clip],
        occurrence: Int = 0,
        recording: RecordingDrive.Freshness? = nil
    ) -> DriveGroup {
        DriveGroup(bootTag: bootTag, occurrence: occurrence, clips: clips, recording: recording)
    }
}
