import Foundation
import Testing
@testable import DanCam

struct ClipsClientTests {
    @Test(.tags(.networking))
    func liveClientBuildsRequestAndDecodesClipsResponse() async throws {
        let payload = Data("""
        {
          "clips": [
            { "id": 7, "start_ms": null, "dur_ms": null, "bytes": 39123456,
              "locked": false, "etag": "7-39123456", "time_approximate": true }
          ],
          "server_time_ms": 1719338400000,
          "next_cursor": null
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
        let client = ClipsClient.live(baseURL: baseURL) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        let response = try await client.fetch()
        let request = try #require(await capture.values().first)

        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/clips HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Connection: close\r
        \r

        """)
        #expect(response == ClipsResponse(
            clips: [
                Clip(
                    id: 7,
                    startMs: nil,
                    durMs: nil,
                    bytes: 39123456,
                    locked: false,
                    etag: "7-39123456",
                    timeApproximate: true
                ),
            ],
            serverTimeMs: 1719338400000,
            nextCursor: nil
        ))
    }
}
