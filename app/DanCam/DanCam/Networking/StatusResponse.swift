import Foundation

nonisolated struct StatusResponse: Codable, Equatable, Sendable {
    var recording: Bool
    var cameraState: CameraState
    var bootId: String
    var uptimeS: UInt64
    var storage: Storage?
    var tempC: TempC
    var mem: Mem?
}

nonisolated enum CameraState: String, Codable, Equatable, Sendable {
    case starting
    case running
    case restarting
    case offline
}

nonisolated struct Storage: Codable, Equatable, Sendable {
    var used: UInt64
    var total: UInt64
}

nonisolated struct TempC: Codable, Equatable, Sendable {
    var soc: Double?
    var sensor: Double?
}

nonisolated struct Mem: Codable, Equatable, Sendable {
    var total: UInt64
    var available: UInt64
    var swapTotal: UInt64
    var swapUsed: UInt64
}
