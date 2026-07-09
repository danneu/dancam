import Foundation

nonisolated struct DriveDetailState: Equatable, Sendable {
    var bootTag: String
    var clips: [Clip]
    var canLoadMore: Bool
    var paginationFrontier: Int?

    init(allClips: [Clip], nextCursor: String?, bootTag: String) {
        self.bootTag = bootTag
        clips = allClips
            .filter { $0.bootTag == bootTag }
            .sorted { $0.id > $1.id }
        paginationFrontier = allClips.last?.id
        canLoadMore = nextCursor != nil && Self.tailKeepsDriveIndeterminate(
            allClips: allClips,
            bootTag: bootTag
        )
    }

    private static func tailKeepsDriveIndeterminate(allClips: [Clip], bootTag: String) -> Bool {
        guard let oldestBootTag = allClips.last?.bootTag else { return true }
        return oldestBootTag == bootTag
    }
}
