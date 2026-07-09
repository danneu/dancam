import Foundation

nonisolated enum CameraEvent: Decodable, Equatable, Sendable {
    case snapshot(World)
    case recordingStarting(session: UInt64, atMs: UInt64)
    case recordingStarted(session: UInt64, atMs: UInt64)
    case segmentOpened(session: UInt64, id: Int, atMs: UInt64)
    case clipFinalized(Clip)
    case clipRemoved(id: Int)
    case recordingStopping(session: UInt64, atMs: UInt64)
    case recordingStopped(session: UInt64, atMs: UInt64)
    case recorderFailed(session: UInt64, detail: String, atMs: UInt64)
    case cameraStateChanged(state: CameraState)
    case storageChanged(used: UInt64, total: UInt64)
    case tempChanged(soc: Double?, sensor: Double?)
    case memChanged(total: UInt64, available: UInt64, swapTotal: UInt64, swapUsed: UInt64)
    case timeSynced(atMs: UInt64)
    case heartbeat(tMs: UInt64)
    case unknown(type: String)
}

extension CameraEvent {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    nonisolated private struct TypeEnvelope: Decodable {
        var type: String
    }

    nonisolated private struct SessionPayload: Decodable {
        var session: UInt64
        var atMs: UInt64
    }

    nonisolated private struct SegmentOpenedPayload: Decodable {
        var session: UInt64
        var id: Int
        var atMs: UInt64
    }

    nonisolated private struct ClipRemovedPayload: Decodable {
        var id: Int
    }

    nonisolated private struct RecorderFailedPayload: Decodable {
        var session: UInt64
        var detail: String
        var atMs: UInt64
    }

    nonisolated private struct CameraStateChangedPayload: Decodable {
        var state: CameraState
    }

    nonisolated private struct StorageChangedPayload: Decodable {
        var used: UInt64
        var total: UInt64
    }

    nonisolated private struct TempChangedPayload: Decodable {
        var soc: Double?
        var sensor: Double?
    }

    nonisolated private struct MemChangedPayload: Decodable {
        var total: UInt64
        var available: UInt64
        var swapTotal: UInt64
        var swapUsed: UInt64
    }

    nonisolated private struct HeartbeatPayload: Decodable {
        var tMs: UInt64
    }

    nonisolated private struct TimeSyncedPayload: Decodable {
        var atMs: UInt64
    }

    nonisolated init(from decoder: Decoder) throws {
        let type = try TypeEnvelope(from: decoder).type

        switch type {
        case "snapshot":
            self = .snapshot(try World(from: decoder))
        case "recording_starting":
            let payload = try SessionPayload(from: decoder)
            self = .recordingStarting(session: payload.session, atMs: payload.atMs)
        case "recording_started":
            let payload = try SessionPayload(from: decoder)
            self = .recordingStarted(session: payload.session, atMs: payload.atMs)
        case "segment_opened":
            let payload = try SegmentOpenedPayload(from: decoder)
            self = .segmentOpened(session: payload.session, id: payload.id, atMs: payload.atMs)
        case "clip_finalized":
            self = .clipFinalized(try Clip(from: decoder))
        case "clip_removed":
            self = .clipRemoved(id: try ClipRemovedPayload(from: decoder).id)
        case "recording_stopping":
            let payload = try SessionPayload(from: decoder)
            self = .recordingStopping(session: payload.session, atMs: payload.atMs)
        case "recording_stopped":
            let payload = try SessionPayload(from: decoder)
            self = .recordingStopped(session: payload.session, atMs: payload.atMs)
        case "recorder_failed":
            let payload = try RecorderFailedPayload(from: decoder)
            self = .recorderFailed(session: payload.session, detail: payload.detail, atMs: payload.atMs)
        case "camera_state_changed":
            self = .cameraStateChanged(state: try CameraStateChangedPayload(from: decoder).state)
        case "storage_changed":
            let payload = try StorageChangedPayload(from: decoder)
            self = .storageChanged(used: payload.used, total: payload.total)
        case "temp_changed":
            let payload = try TempChangedPayload(from: decoder)
            self = .tempChanged(soc: payload.soc, sensor: payload.sensor)
        case "mem_changed":
            let payload = try MemChangedPayload(from: decoder)
            self = .memChanged(
                total: payload.total,
                available: payload.available,
                swapTotal: payload.swapTotal,
                swapUsed: payload.swapUsed
            )
        case "time_synced":
            self = .timeSynced(atMs: try TimeSyncedPayload(from: decoder).atMs)
        case "heartbeat":
            self = .heartbeat(tMs: try HeartbeatPayload(from: decoder).tMs)
        default:
            self = .unknown(type: type)
        }
    }
}

nonisolated struct World: Codable, Equatable, Sendable {
    var recorder: RecorderSnapshot
    var cameraState: CameraState
    var bootId: String
    var bootTag: String? = nil
    var uptimeS: UInt64
    var storage: Storage?
    var tempC: TempC
    var mem: Mem?
    var time: TimeStatus? = nil
}

extension World {
    nonisolated static func folding(_ world: World, _ event: CameraEvent) -> World {
        var next = world

        switch event {
        case .snapshot(let snapshot):
            next = snapshot
        case .recordingStarting(let session, _):
            next.recorder.phase = .starting
            next.recorder.session = session
            next.recorder.currentSegment = nil
            next.recorder.detail = nil
        case .recordingStarted(let session, _):
            next.recorder.phase = .recording
            next.recorder.session = session
            next.recorder.detail = nil
        case .segmentOpened(let session, let id, _):
            next.recorder.phase = .recording
            next.recorder.session = session
            next.recorder.currentSegment = RecorderSegment(id: id, durMs: nil)
            next.recorder.detail = nil
        case .clipFinalized, .clipRemoved:
            break
        case .recordingStopping(let session, _):
            next.recorder.phase = .stopping
            next.recorder.session = session
        case .recordingStopped(let session, _):
            next.recorder.phase = .idle
            next.recorder.session = session
            next.recorder.currentSegment = nil
            next.recorder.detail = nil
        case .recorderFailed(let session, let detail, _):
            next.recorder.phase = .error
            next.recorder.session = session
            next.recorder.currentSegment = nil
            next.recorder.detail = detail
        case .cameraStateChanged(let state):
            next.cameraState = state
        case .storageChanged(let used, let total):
            next.storage = Storage(used: used, total: total)
        case .tempChanged(let soc, let sensor):
            next.tempC = TempC(soc: soc, sensor: sensor)
        case .memChanged(let total, let available, let swapTotal, let swapUsed):
            next.mem = Mem(total: total, available: available, swapTotal: swapTotal, swapUsed: swapUsed)
        case .timeSynced:
            next.time = TimeStatus(synced: true)
        case .heartbeat(let tMs):
            next.uptimeS = tMs / 1_000
        case .unknown:
            break
        }

        return next
    }
}

nonisolated struct RecorderSnapshot: Codable, Equatable, Sendable {
    var phase: RecorderPhase
    var session: UInt64
    var currentSegment: RecorderSegment?
    var detail: String?
}

nonisolated enum RecorderPhase: String, Codable, Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case error

    var isActive: Bool {
        switch self {
        case .starting, .recording, .stopping:
            return true
        case .idle, .error:
            return false
        }
    }

    var claimsRecording: Bool {
        switch self {
        case .starting, .recording:
            return true
        case .idle, .stopping, .error:
            return false
        }
    }
}

nonisolated struct RecorderSegment: Codable, Equatable, Sendable {
    var id: Int
    var durMs: UInt64?
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

nonisolated struct TimeStatus: Codable, Equatable, Sendable {
    var synced: Bool
}
