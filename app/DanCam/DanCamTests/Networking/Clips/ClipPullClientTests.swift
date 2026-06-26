import Foundation
import Testing
@testable import DanCam

struct ClipPullClientTests {
    @Test(.tags(.networking))
    func pullStreamsProgressWritesFileAndBuildsFiniteRequest() async throws {
        let body = Data("abcdefghijkl".utf8)
        let wire = MJPEGWireBuilder.response(
            headers: [
                ("Content-Type", "application/mp2t"),
                ("Content-Length", "\(body.count)"),
            ],
            body: body
        )
        let headEnd = try #require(wire.range(of: Data("\r\n\r\n".utf8))?.upperBound)
        let chunks = [
            Data(wire.prefix(headEnd + 4)),
            Data(wire.dropFirst(headEnd + 4).prefix(3)),
            Data(wire.dropFirst(headEnd + 7)),
        ]
        let capture = RequestCapture()
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = ClipPullClient.live(baseURL: baseURL) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream(chunks)
        }

        let events = try await collect(client.pull(42))
        let request = try #require(await capture.values().first)

        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/clips/42 HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Connection: close\r
        \r

        """)

        try #require(events.count == 4)
        #expect(events[0] == .progress(bytesWritten: 4, expected: UInt64(body.count)))
        #expect(events[1] == .progress(bytesWritten: 7, expected: UInt64(body.count)))
        #expect(events[2] == .progress(bytesWritten: 12, expected: UInt64(body.count)))

        guard case .completed(let result) = events[3] else {
            Issue.record("Expected completed event.")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: result.fileURL)
        }

        let fileBytes = try Data(contentsOf: result.fileURL)
        #expect(fileBytes == body)
        #expect(result.bytes == UInt64(body.count))
        #expect(result.throughputMbps >= 0)
    }

    private func collect(
        _ stream: AsyncThrowingStream<ClipPullEvent, Error>
    ) async throws -> [ClipPullEvent] {
        var events: [ClipPullEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}
