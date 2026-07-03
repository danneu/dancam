import Foundation
import Testing
@testable import DanCam

struct ClipsClientTests {
    @Test(.tags(.networking))
    func liveClientBuildsBareRequestAndDecodesClipsResponse() async throws {
        let payload = Data("""
        {
          "clips": [
            { "id": 7, "start_ms": null, "dur_ms": null, "bytes": 39123456,
              "locked": false, "etag": "7-39123456", "time_approximate": true }
          ],
          "server_time_ms": 1719338400000,
          "next_cursor": "7"
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

        let response = try await client.fetch(nil)
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
            nextCursor: "7"
        ))
    }

    @Test(.tags(.networking))
    func liveClientAddsCursorQueryItem() async throws {
        let payload = Data("""
        {
          "clips": [],
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

        _ = try await client.fetch("42")
        let request = try #require(await capture.values().first)

        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/clips?cursor=42 HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Connection: close\r
        \r

        """)
    }

    @Test(.tags(.networking))
    func liveClientDecodesNullServerTime() async throws {
        let payload = Data("""
        {
          "clips": [],
          "server_time_ms": null,
          "next_cursor": null
        }
        """.utf8)
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let wire = MJPEGWireBuilder.response(
            headers: [
                ("Content-Type", "application/json"),
                ("Content-Length", "\(payload.count)"),
            ],
            body: payload
        )
        let client = ClipsClient.live(baseURL: baseURL) { _, _ in
            AsyncStreamHelpers.byteStream([wire])
        }

        let response = try await client.fetch(nil)

        #expect(response.serverTimeMs == nil)
    }

    @Test(.tags(.networking))
    func deleteBuildsRequestWithIdempotencyKeyAndDecodesSuccess() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let capture = RequestCapture()
        let wire = MJPEGWireBuilder.response(
            headers: [("Content-Length", "0")],
            body: Data()
        )
        let client = ClipsClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" }
        ) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        try await client.delete(7)
        let request = try #require(await capture.values().first)

        #expect(String(decoding: request, as: UTF8.self) == """
        DELETE /v1/clips/7 HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Content-Type: application/json\r
        Idempotency-Key: fixed-key\r
        Connection: close\r
        \r

        """)
    }

    @Test(.tags(.networking))
    func deleteMapsNon2xxResponseToHTTPError() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let wire = MJPEGWireBuilder.response(
            statusCode: 503,
            headers: [("Content-Length", "0")],
            body: Data()
        )
        let client = ClipsClient.live(baseURL: baseURL) { _, _ in
            AsyncStreamHelpers.byteStream([wire])
        }

        do {
            try await client.delete(7)
            Issue.record("Expected ClipsError.http.")
        } catch let error as ClipsError {
            #expect(error == .http(503))
        } catch {
            Issue.record("Expected ClipsError.http, got \(error).")
        }
    }

    @Test(.tags(.networking))
    func deleteRethrowsCancellationUnwrapped() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = ClipsClient.live(baseURL: baseURL) { _, _ in
            throw URLError(.cancelled)
        }

        do {
            try await client.delete(7)
            Issue.record("Expected URLError.cancelled.")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected URLError.cancelled, got \(error).")
        }
    }
}
