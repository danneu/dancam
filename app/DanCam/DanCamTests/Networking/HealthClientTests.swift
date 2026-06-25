import Foundation
import Testing
@testable import DanCam

extension Tag {
    @Tag static var networking: Self
}

struct HealthClientTests {
    @Test(.tags(.networking))
    func liveClientBuildsRequestAndDecodesHealthResponse() async throws {
        let payload = Data("""
        {
          "boot_id": "boot-123",
          "uptime_s": 42,
          "recording": true,
          "t_ms": 123456789
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
        let client = HealthClient.live(baseURL: baseURL) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        let response = try await client.fetch()
        let request = try #require(await capture.values().first)

        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/health HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Connection: close\r
        \r

        """)
        #expect(response == HealthResponse(
            bootId: "boot-123",
            uptimeS: 42,
            recording: true,
            tMs: 123456789
        ))
    }

    @Test(.tags(.networking))
    func non2xxResponseThrowsHTTPError() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let wire = MJPEGWireBuilder.response(statusCode: 503, headers: [("Content-Length", "0")], body: Data())
        let client = HealthClient.live(baseURL: baseURL) { _, _ in
            AsyncStreamHelpers.byteStream([wire])
        }

        do {
            _ = try await client.fetch()
            Issue.record("Expected HealthError.http.")
        } catch let error as HealthError {
            #expect(error == .http(503))
        } catch {
            Issue.record("Expected HealthError.http, got \(error).")
        }
    }

    @Test(.tags(.networking))
    func cancelledTransportErrorIsRethrownUnwrapped() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = HealthClient.live(baseURL: baseURL) { _, _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await client.fetch()
            Issue.record("Expected URLError.cancelled.")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected URLError.cancelled, got \(error).")
        }
    }
}
