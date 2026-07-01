import Foundation
@testable import DanCam

enum CameraSamples {
    static func world(
        phase: RecorderPhase = .idle,
        session: UInt64 = 7,
        currentSegment: RecorderSegment? = nil,
        detail: String? = nil,
        cameraState: CameraState = .running,
        storage: Storage? = Storage(used: 100, total: 1_000),
        tempC: TempC = TempC(soc: nil, sensor: nil),
        mem: Mem? = nil,
        uptimeS: UInt64 = 1
    ) -> World {
        World(
            recorder: RecorderSnapshot(
                phase: phase,
                session: session,
                currentSegment: currentSegment,
                detail: detail
            ),
            cameraState: cameraState,
            bootId: "boot-123",
            uptimeS: uptimeS,
            storage: storage,
            tempC: tempC,
            mem: mem
        )
    }

    static func clip(id: Int, durMs: UInt64? = nil) -> Clip {
        Clip(
            id: id,
            startMs: nil,
            durMs: durMs,
            bytes: UInt64(id * 100),
            locked: false,
            etag: "\(id)-\(id * 100)",
            timeApproximate: true
        )
    }

    static func clipsResponse(ids: [Int], nextCursor: String? = nil) -> ClipsResponse {
        ClipsResponse(
            clips: ids.map { clip(id: $0) },
            serverTimeMs: 123456789,
            nextCursor: nextCursor
        )
    }
}
