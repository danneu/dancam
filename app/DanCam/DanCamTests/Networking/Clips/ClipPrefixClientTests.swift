import Foundation
import Testing
@testable import DanCam

struct ClipPrefixClientTests {
    @Test(.tags(.networking))
    func partial206ReturnsExactBytesAndBuildsBoundedRangedRequest() async throws {
        let body = Data("abcdefgh".utf8) // 8 bytes
        let wire = partial206(start: 0, end: 7, total: 8, etag: "7-10", body: body)
        let capture = RequestCapture()
        let client = try makeClient(wire, capture: capture)

        // Raw expected etag (`7-10`) against a quoted wire ETag (`"7-10"`): pins the
        // wrap-one-side rule.
        let data = try await client.fetchPrefix(42, "7-10", 8)
        let request = try #require(await capture.values().first)

        #expect(data == body)
        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/clips/42 HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Range: bytes=0-7\r
        Connection: close\r
        \r

        """)
    }

    @Test(.tags(.networking))
    func requestOmitsIfRangeSoAMismatchCannotReturnAFullBody() async throws {
        let body = Data("abcd".utf8)
        let wire = partial206(start: 0, end: 3, total: 4, etag: "7-10", body: body)
        let capture = RequestCapture()
        let client = try makeClient(wire, capture: capture)

        _ = try await client.fetchPrefix(42, "7-10", 4)
        let request = String(decoding: try #require(await capture.values().first), as: UTF8.self)

        #expect(request.contains("If-Range") == false)
    }

    @Test(.tags(.networking))
    func whole200BodyLargerThanLimitEarlyBreaksAtLimit() async throws {
        let body = Data("abcdefgh".utf8) // 8 bytes, whole-file 200
        let wire = ok200(total: body.count, etag: "7-10", body: body)
        let client = try makeClient(wire)

        let data = try await client.fetchPrefix(42, "7-10", 4)

        #expect(data == Data(body.prefix(4)))
    }

    @Test(.tags(.networking))
    func mismatchedValidatorThrowsAndReturnsNothing() async throws {
        let body = Data("abcdefgh".utf8)
        let wire = partial206(start: 0, end: 7, total: 8, etag: "8-10", body: body)
        let client = try makeClient(wire)

        await #expect(throws: ClipPrefixError.validatorMismatch) {
            _ = try await client.fetchPrefix(42, "7-10", 8)
        }
    }

    @Test(.tags(.networking))
    func missingValidatorThrows() async throws {
        let body = Data("abcdefgh".utf8)
        let wire = ok200WithoutETag(total: body.count, body: body)
        let client = try makeClient(wire)

        await #expect(throws: ClipPrefixError.validatorMismatch) {
            _ = try await client.fetchPrefix(42, "7-10", 8)
        }
    }

    @Test(.tags(.networking))
    func partial206NotStartingAtByteZeroThrows() async throws {
        let body = Data("cdefghij".utf8)
        let wire = partial206(start: 2, end: 9, total: 10, etag: "7-10", body: body)
        let client = try makeClient(wire)

        await #expect(throws: ClipPrefixError.self) {
            _ = try await client.fetchPrefix(42, "7-10", 8)
        }
    }

    @Test(.tags(.networking))
    func non2xxThrowsHTTP() async throws {
        let wire = MJPEGWireBuilder.response(
            statusCode: 404,
            headers: [("Content-Length", "0")],
            body: Data()
        )
        let client = try makeClient(wire)

        await #expect(throws: ClipPrefixError.http(404)) {
            _ = try await client.fetchPrefix(42, "7-10", 8)
        }
    }

    // MARK: - Helpers

    private func makeClient(_ wire: Data, capture: RequestCapture? = nil) throws -> ClipPrefixClient {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        return ClipPrefixClient.live(baseURL: baseURL) { _, request in
            if let capture {
                await capture.append(request)
            }
            return AsyncStreamHelpers.byteStream([wire])
        }
    }

    private func ok200(total: Int, etag: String, body: Data) -> Data {
        MJPEGWireBuilder.response(
            statusCode: 200,
            headers: [
                ("Content-Type", "application/mp2t"),
                ("Content-Length", "\(total)"),
                ("ETag", "\"\(etag)\""),
            ],
            body: body
        )
    }

    private func ok200WithoutETag(total: Int, body: Data) -> Data {
        MJPEGWireBuilder.response(
            statusCode: 200,
            headers: [
                ("Content-Type", "application/mp2t"),
                ("Content-Length", "\(total)"),
            ],
            body: body
        )
    }

    private func partial206(start: Int, end: Int, total: Int, etag: String, body: Data) -> Data {
        MJPEGWireBuilder.response(
            statusCode: 206,
            headers: [
                ("Content-Type", "application/mp2t"),
                ("Content-Length", "\(body.count)"),
                ("Content-Range", "bytes \(start)-\(end)/\(total)"),
                ("ETag", "\"\(etag)\""),
            ],
            body: body
        )
    }
}
