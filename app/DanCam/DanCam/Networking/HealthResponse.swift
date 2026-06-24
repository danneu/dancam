import Foundation

nonisolated struct HealthResponse: Codable, Equatable, Sendable {
    var bootId: String
    var uptimeS: UInt64
    var recording: Bool
    var tMs: UInt64
}
