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

        let events = try await collect(client.pull(42, "1-12"))
        let request = try #require(await capture.values().first)

        // Attempt 1 is a plain GET -- no Range / If-Range until bytes land.
        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/clips/42 HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        Connection: close\r
        \r

        """)

        try #require(events.count == 5)
        let openedURL = try requireOpenedURL(events)
        #expect(events[0] == .opened(fileURL: openedURL))
        #expect(events[1] == .progress(bytesWritten: 4, expected: UInt64(body.count)))
        #expect(events[2] == .progress(bytesWritten: 7, expected: UInt64(body.count)))
        #expect(events[3] == .progress(bytesWritten: 12, expected: UInt64(body.count)))

        let result = try requireCompleted(events)
        defer {
            try? FileManager.default.removeItem(at: result.fileURL)
        }

        #expect(openedURL == result.fileURL)
        #expect(try Data(contentsOf: result.fileURL) == body)
        #expect(result.bytes == UInt64(body.count))
        #expect(result.throughputMbps >= 0)
    }

    @Test(.tags(.networking))
    func resumesFromLastByteAfterMidPullDrop() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call1 = ok200(total: full.count, etag: etag, body: Data(full.prefix(5)))
        let call2 = partial206(
            start: 5,
            end: 11,
            total: full.count,
            etag: etag,
            body: Data(full.dropFirst(5))
        )

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let events = try await collect(client.pull(101, etag))
        let requests = await responder.requests
        try #require(requests.count == 2)

        // The resume request carries the open-ended Range and the *quoted* validator,
        // unchanged because the 200's ETag matched the list etag.
        let resume = String(decoding: requests[1], as: UTF8.self)
        #expect(resume.contains("\r\nRange: bytes=5-\r\n"))
        #expect(resume.contains("\r\nIf-Range: \"1-12\"\r\n"))

        let progress = progressValues(events)
        #expect(progress.map(\.bytesWritten) == [5, 12])
        #expect(progress.allSatisfy { $0.expected == UInt64(full.count) })

        let openedURL = try requireOpenedURL(events)
        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(openedURL == result.fileURL)
        #expect(try Data(contentsOf: result.fileURL) == full)
        #expect(result.bytes == UInt64(full.count))
    }

    @Test(.tags(.networking))
    func retriesFromHeadWhenDropLandsBeforeAnyBody() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        // Call 1 drops just after the head, before a single body byte (bytesWritten == 0).
        let call1 = ok200(total: full.count, etag: etag, body: Data())
        let call2 = ok200(total: full.count, etag: etag, body: full)

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let events = try await collect(client.pull(102, etag))
        let requests = await responder.requests
        try #require(requests.count == 2)

        // Still at byte 0, so the retry is a plain GET -- no Range / If-Range.
        let retry = String(decoding: requests[1], as: UTF8.self)
        #expect(retry.contains("Range:") == false)

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == full)
    }

    @Test(.tags(.networking))
    func ridesOutAConnectionOpenFailure() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call2 = ok200(total: full.count, etag: etag, body: full)
        // Call 1 throws before returning a stream -- the connect-failure shape, a
        // distinct path from a returned stream that drops.
        let responder = ScriptedResponder([.throwOnOpen, .finish([call2])])
        let client = try makeClient(responder)

        let events = try await collect(client.pull(103, etag))
        let requests = await responder.requests
        try #require(requests.count == 2)

        let retry = String(decoding: requests[1], as: UTF8.self)
        #expect(retry.contains("Range:") == false)

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == full)
    }

    @Test(.tags(.networking))
    func rejectsAResumeWithAMismatchedStart() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call1 = ok200(total: full.count, etag: etag, body: Data(full.prefix(5)))
        // start (0) != bytesWritten (5): a stale / wrong-offset partial.
        let call2 = partial206(start: 0, end: 11, total: full.count, etag: etag, body: full)

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(104, etag))
        expectMalformed(error)
        #expect(tempClipFiles(clipID: 104).isEmpty)
    }

    @Test(.tags(.networking))
    func rejectsAResumeWithAShortEnd() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call1 = ok200(total: full.count, etag: etag, body: Data(full.prefix(5)))
        // Matching start/total but a truncated end (end + 1 < total), with a
        // Content-Length that *would* frame a complete-looking body. The guard must
        // still reject it before the truncated tail is appended.
        let call2 = partial206(
            start: 5,
            end: 9,
            total: full.count,
            etag: etag,
            body: Data(full[5..<10])
        )

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(105, etag))
        expectMalformed(error)
        #expect(tempClipFiles(clipID: 105).isEmpty)
    }

    @Test(.tags(.networking))
    func restartsAndTracksTheNewValidatorWhenItChanges() async throws {
        let oldBytes = Data("abcdefghij".utf8) // 10 bytes
        let newBytes = Data("ABCDEF".utf8) // 6 bytes
        let call1 = ok200(total: 12, etag: "old", body: oldBytes)
        // Validator changed -> the server ignores If-Range and re-200s the new
        // representation; it drops again partway.
        let call2 = ok200(total: newBytes.count, etag: "new", body: Data(newBytes.prefix(2)))
        let call3 = partial206(
            start: 2,
            end: 5,
            total: newBytes.count,
            etag: "new",
            body: Data(newBytes.dropFirst(2))
        )

        let responder = ScriptedResponder([.drop([call1]), .drop([call2]), .finish([call3])])
        let client = try makeClient(responder)

        let events = try await collect(client.pull(106, "old"))
        let requests = await responder.requests
        try #require(requests.count == 3)

        // The third request resumes against the *new* validator, not the stale list etag.
        let resume = String(decoding: requests[2], as: UTF8.self)
        #expect(resume.contains("\r\nRange: bytes=2-\r\n"))
        #expect(resume.contains("\r\nIf-Range: \"new\"\r\n"))

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        let restartIndex = try requireSingleRestartIndex(events)
        let firstPostRestartProgress = try #require(firstProgressIndex(in: events, after: restartIndex))

        #expect(progressValues(events).map(\.bytesWritten) == [10, 2, 6])
        #expect(firstPostRestartProgress > restartIndex)
        // Truncated and rewritten -- no stale tail from the 10-byte old representation.
        #expect(try Data(contentsOf: result.fileURL) == newBytes)
        #expect(result.bytes == UInt64(newBytes.count))
    }

    @Test(.tags(.networking))
    func restartedPrecedesPostTruncationProgressEvenWhenProgressDoesNotRewind() async throws {
        let oldPrefix = Data("ab".utf8)
        let newBytes = Data("ABCDEF".utf8)
        let call1 = ok200(total: 4, etag: "old", body: oldPrefix)
        let call2 = ok200(total: newBytes.count, etag: "new", body: newBytes)

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let events = try await collect(client.pull(107, "old"))
        let requests = await responder.requests
        try #require(requests.count == 2)

        let progress = progressValues(events)
        #expect(progress.map(\.bytesWritten) == [2, 6])
        try #require(progress.count == 2)
        try #require(progress[1].bytesWritten >= progress[0].bytesWritten)

        let restartIndex = try requireSingleRestartIndex(events)
        let firstPostRestartProgress = try #require(firstProgressIndex(in: events, after: restartIndex))
        let completedIndex = try #require(events.firstIndex { event in
            if case .completed = event {
                return true
            }
            return false
        })

        #expect(firstPostRestartProgress > restartIndex)
        #expect(firstPostRestartProgress < completedIndex)

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == newBytes)
    }

    // MARK: - Helpers

    private func makeClient(_ responder: ScriptedResponder) throws -> ClipPullClient {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        return ClipPullClient.live(baseURL: baseURL, sleep: { _ in }) { _, request in
            try await responder.open(request: request)
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

    private func collect(
        _ stream: AsyncThrowingStream<ClipPullEvent, Error>
    ) async throws -> [ClipPullEvent] {
        var events: [ClipPullEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func pullError(_ stream: AsyncThrowingStream<ClipPullEvent, Error>) async -> Error? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    private func expectMalformed(_ error: Error?) {
        guard case .malformedResponse = error as? ClipPullError else {
            Issue.record("Expected ClipPullError.malformedResponse, got \(String(describing: error)).")
            return
        }
    }

    private func progressValues(
        _ events: [ClipPullEvent]
    ) -> [(bytesWritten: UInt64, expected: UInt64?)] {
        events.compactMap { event in
            if case .progress(let bytesWritten, let expected) = event {
                return (bytesWritten, expected)
            }
            return nil
        }
    }

    private func requireOpenedURL(_ events: [ClipPullEvent]) throws -> URL {
        let opened = events.compactMap { event -> URL? in
            if case .opened(let fileURL) = event {
                return fileURL
            }
            return nil
        }
        #expect(opened.count == 1)
        return try #require(opened.first)
    }

    private func requireSingleRestartIndex(_ events: [ClipPullEvent]) throws -> Int {
        let indices = events.indices.filter { index in
            if case .restarted = events[index] {
                return true
            }
            return false
        }
        #expect(indices.count == 1)
        return try #require(indices.first)
    }

    private func firstProgressIndex(
        in events: [ClipPullEvent],
        after index: Int
    ) -> Int? {
        events.indices.drop(while: { $0 <= index }).first { eventIndex in
            if case .progress = events[eventIndex] {
                return true
            }
            return false
        }
    }

    private func requireCompleted(_ events: [ClipPullEvent]) throws -> ClipPullResult {
        let completed = events.compactMap { event -> ClipPullResult? in
            if case .completed(let result) = event {
                return result
            }
            return nil
        }
        return try #require(completed.last)
    }

    private func tempClipFiles(clipID: Int) -> [URL] {
        let directory = FileManager.default.temporaryDirectory
        let prefix = "clip-\(clipID)-"
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "ts"
        }
    }
}

private actor ScriptedResponder {
    enum Step {
        case drop([Data]) // yield the chunks, then finish(throwing:) -- a link drop
        case finish([Data]) // yield the chunks, then finish() cleanly
        case throwOnOpen // throw before returning a stream -- a connect failure
    }

    private var steps: [Step]
    private(set) var requests: [Data] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func open(request: Data) throws -> AsyncThrowingStream<Data, Error> {
        requests.append(request)
        let step = steps.isEmpty ? .finish([]) : steps.removeFirst()
        switch step {
        case .throwOnOpen:
            throw URLError(.cannotConnectToHost)
        case .drop(let chunks):
            return AsyncStreamHelpers.droppingByteStream(chunks)
        case .finish(let chunks):
            return AsyncStreamHelpers.byteStream(chunks)
        }
    }
}
