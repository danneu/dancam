import Foundation
import Testing
@testable import DanCam

struct RecordingClientTests {
    @Test(.tags(.networking))
    func startBuildsPostRequestWithIdempotencyKeyAndDecodesSuccess() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let capture = RequestCapture()
        let wire = MJPEGWireBuilder.response(
            headers: [("Content-Length", "0")],
            body: Data()
        )
        let client = RecordingClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" }
        ) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        try await client.start()
        let request = try #require(await capture.values().first)

        #expect(String(decoding: request, as: UTF8.self) == """
        POST /v1/recording/start HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Content-Type: application/json\r
        Idempotency-Key: fixed-key\r
        Connection: close\r
        Content-Length: 2\r
        \r
        {}
        """)
    }

    @Test(.tags(.networking))
    func stopMapsNon2xxResponseToHTTPError() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let wire = MJPEGWireBuilder.response(
            statusCode: 503,
            headers: [("Content-Length", "0")],
            body: Data()
        )
        let client = RecordingClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" }
        ) { _, _ in
            AsyncStreamHelpers.byteStream([wire])
        }

        do {
            try await client.stop()
            Issue.record("Expected RecordingError.http.")
        } catch let error as RecordingError {
            #expect(error == .http(503))
        } catch {
            Issue.record("Expected RecordingError.http, got \(error).")
        }
    }

    @Test(.tags(.networking))
    func cancelledTransportErrorIsRethrownUnwrapped() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = RecordingClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" }
        ) { _, _ in
            throw URLError(.cancelled)
        }

        do {
            try await client.start()
            Issue.record("Expected URLError.cancelled.")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected URLError.cancelled, got \(error).")
        }
    }
}
