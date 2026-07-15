import Foundation
@testable import DanCam

enum CameraSamples {
    static func world(
        phase: RecorderPhase = .idle,
        session: UInt64 = 7,
        currentSegment: RecorderSegment? = nil,
        detail: String? = nil,
        cameraState: CameraState = .running,
        recordingReadiness: RecordingReadiness = .ready,
        storage: Storage? = Storage(used: 100, total: 1_000),
        tempC: TempC = TempC(),
        mem: Mem? = nil,
        cpu: CPU = CPU(),
        uptimeS: UInt64 = 1,
        bootTag: String? = nil,
        time: TimeStatus? = TimeStatus(synced: true)
    ) -> World {
        World(
            recorder: RecorderSnapshot(
                phase: phase,
                session: session,
                currentSegment: currentSegment,
                detail: detail
            ),
            cameraState: cameraState,
            recordingReadiness: recordingReadiness,
            bootId: "boot-123",
            bootTag: bootTag,
            uptimeS: uptimeS,
            storage: storage,
            tempC: tempC,
            mem: mem,
            cpu: cpu,
            time: time
        )
    }

    static func clip(
        id: Int,
        startMs: UInt64? = nil,
        durMs: UInt64? = nil,
        timeApproximate: Bool = true,
        bootTag: String? = nil,
        session: UInt64? = 7
    ) -> Clip {
        Clip(
            id: id,
            startMs: startMs,
            durMs: durMs,
            bytes: UInt64(id * 100),
            locked: false,
            etag: "\(id)-\(id * 100)",
            timeApproximate: timeApproximate,
            bootTag: bootTag,
            session: session
        )
    }

    static func clipsResponse(ids: [Int], nextCursor: ClipCursor? = nil) -> ClipsResponse {
        ClipsResponse(
            clips: ids.map { clip(id: $0) },
            serverTimeMs: 123456789,
            nextCursor: nextCursor
        )
    }
}
