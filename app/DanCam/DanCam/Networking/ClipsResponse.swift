import Foundation

nonisolated struct ClipsResponse: Codable, Equatable, Sendable {
    var clips: [Clip]
    var serverTimeMs: UInt64
    var nextCursor: String?
}

nonisolated struct Clip: Codable, Equatable, Sendable {
    var id: Int
    var startMs: UInt64?
    var durMs: UInt64?
    var bytes: UInt64
    var locked: Bool
    var etag: String
    var timeApproximate: Bool
}
