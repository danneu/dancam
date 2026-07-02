import Foundation
import Testing
@testable import DanCam

struct TimeClientTests {
    @Test(.tags(.networking))
    func syncBuildsPostRequestWithFreshEpochAndIdempotencyKey() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let capture = RequestCapture()
        let response = Data(#"{"synced":true}"#.utf8)
        let wire = MJPEGWireBuilder.response(
            headers: [("Content-Length", "\(response.count)")],
            body: response
        )
        let epochMs: UInt64 = 1_767_225_600_000
        let client = TimeClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" },
            now: { epochMs }
        ) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        try await client.sync()
        let request = try #require(await capture.values().first)
        let body = #"{"epoch_ms":1767225600000}"#

        #expect(String(decoding: request, as: UTF8.self) == """
        POST /v1/time HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Content-Type: application/json\r
        Idempotency-Key: fixed-key\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """)
    }

    @Test(.tags(.networking))
    func syncMapsNon2xxResponseToHTTPError() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let wire = MJPEGWireBuilder.response(
            statusCode: 503,
            headers: [("Content-Length", "0")],
            body: Data()
        )
        let client = TimeClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" },
            now: { 1_767_225_600_000 }
        ) { _, _ in
            AsyncStreamHelpers.byteStream([wire])
        }

        do {
            try await client.sync()
            Issue.record("Expected TimeSyncError.http.")
        } catch let error as TimeSyncError {
            #expect(error == .http(503))
        } catch {
            Issue.record("Expected TimeSyncError.http, got \(error).")
        }
    }

    @Test(.tags(.networking))
    func cancelledTransportErrorIsRethrownUnwrapped() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = TimeClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" },
            now: { 1_767_225_600_000 }
        ) { _, _ in
            throw URLError(.cancelled)
        }

        do {
            try await client.sync()
            Issue.record("Expected URLError.cancelled.")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected URLError.cancelled, got \(error).")
        }
    }

    @Test(.tags(.networking))
    func eachSyncReadsTheClockAtRequestBuildTime() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let capture = RequestCapture()
        let clock = AdvancingEpochClock(values: [
            1_767_225_600_000,
            1_767_225_601_500,
        ])
        let response = Data(#"{"synced":true}"#.utf8)
        let wire = MJPEGWireBuilder.response(
            headers: [("Content-Length", "\(response.count)")],
            body: response
        )
        let client = TimeClient.live(
            baseURL: baseURL,
            makeIdempotencyKey: { "fixed-key" },
            now: { clock.next() }
        ) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        try await client.sync()
        try await client.sync()

        let bodies = await capture.values().map { request in
            String(decoding: request, as: UTF8.self)
                .components(separatedBy: "\r\n\r\n")
                .last ?? ""
        }
        #expect(bodies == [
            #"{"epoch_ms":1767225600000}"#,
            #"{"epoch_ms":1767225601500}"#,
        ])
    }
}

private final class AdvancingEpochClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}
