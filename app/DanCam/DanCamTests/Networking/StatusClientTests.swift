import Foundation
import Testing
@testable import DanCam

struct StatusClientTests {
    @Test(.tags(.networking))
    func liveClientBuildsRequestAndDecodesWorldSnapshot() async throws {
        let payload = Data("""
        {
          "recorder": {
            "phase": "recording",
            "session": 7,
            "current_segment": { "id": 43, "dur_ms": 1234 },
            "detail": null
          },
          "camera_state": "running",
          "boot_id": "boot-123",
          "uptime_s": 42,
          "storage": { "used": 100, "total": 1000 },
          "temp_c": { "soc": 51.2, "sensor": null },
          "mem": { "total": 536870912, "available": 209715200, "swap_total": 0, "swap_used": 0 }
        }
        """.utf8)
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let capture = RequestCapture()
        let wire = MJPEGWireBuilder.response(
            headers: [
                ("Content-Type", "application/json"),
                ("Content-Length", "\(payload.count)"),
            ],
            body: payload
        )
        let client = StatusClient.live(baseURL: baseURL) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        let response = try await client.fetch()
        let request = try #require(await capture.values().first)

        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/status HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Connection: close\r
        \r

        """)
        #expect(response == World(
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 43, durMs: 1234),
                detail: nil
            ),
            cameraState: .running,
            bootId: "boot-123",
            uptimeS: 42,
            storage: Storage(used: 100, total: 1000),
            tempC: TempC(soc: 51.2, sensor: nil),
            mem: Mem(total: 536870912, available: 209715200, swapTotal: 0, swapUsed: 0)
        ))
    }
}
