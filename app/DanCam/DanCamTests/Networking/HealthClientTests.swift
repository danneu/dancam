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
        var capturedRequest: URLRequest?
        let client = HealthClient.live(baseURL: baseURL) { request in
            capturedRequest = request
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-Dancam-Proto": "1",
                    "X-Dancam-Boot-Id": "boot-123",
                ]
            ))
            return (payload, response)
        }

        let response = try await client.fetch()
        let request = try #require(capturedRequest)

        #expect(request.url?.path == "/v1/health")
        #expect(request.httpMethod == "GET")
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
        let client = HealthClient.live(baseURL: baseURL) { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(), response)
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
        let client = HealthClient.live(baseURL: baseURL) { _ in
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
