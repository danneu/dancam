import Foundation

nonisolated struct RecordingDetailState: Equatable, Sendable {
    var recordingID: RecordingID
    var clips: [Clip]
    var canLoadMore: Bool
    var paginationFrontier: Int?

    init(allClips: [Clip], nextCursor: String?, recordingID: RecordingID) {
        self.recordingID = recordingID
        clips = allClips
            .filter { $0.recordingID == recordingID }
            .sorted { $0.id > $1.id }
        paginationFrontier = allClips.last?.id
        canLoadMore = nextCursor != nil && Self.tailKeepsRecordingIndeterminate(
            allClips: allClips,
            recordingID: recordingID
        )
    }

    private static func tailKeepsRecordingIndeterminate(allClips: [Clip], recordingID: RecordingID) -> Bool {
        guard let oldestRecordingID = allClips.last?.recordingID else { return true }
        return oldestRecordingID == recordingID
    }
}
