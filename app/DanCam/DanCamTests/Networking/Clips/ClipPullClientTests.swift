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
                ("ETag", "\"1-12\""),
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
        #expect(result.resolvedETag == "\"1-12\"")
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
        #expect(result.resolvedETag == "\"1-12\"")
    }

    @Test(.tags(.networking))
    func retriesFromResumeWhenServerReturns503() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call1 = ok200(total: full.count, etag: etag, body: Data(full.prefix(5)))
        let call3 = partial206(
            start: 5,
            end: 11,
            total: full.count,
            etag: etag,
            body: Data(full.dropFirst(5))
        )

        let responder = ScriptedResponder([.drop([call1]), .finish([wire503()]), .finish([call3])])
        let client = try makeClient(responder)

        let events = try await collect(client.pull(116, etag))
        let requests = await responder.requests
        try #require(requests.count == 3)

        let resumeAfterDrop = String(decoding: requests[1], as: UTF8.self)
        let resumeAfter503 = String(decoding: requests[2], as: UTF8.self)
        #expect(resumeAfterDrop.contains("\r\nRange: bytes=5-\r\n"))
        #expect(resumeAfterDrop.contains("\r\nIf-Range: \"1-12\"\r\n"))
        #expect(resumeAfter503.contains("\r\nRange: bytes=5-\r\n"))
        #expect(resumeAfter503.contains("\r\nIf-Range: \"1-12\"\r\n"))

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == full)
        #expect(result.bytes == UInt64(full.count))
        #expect(result.resolvedETag == "\"1-12\"")
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
    func retriesFromHeadWhenServerReturns503() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call2 = ok200(total: full.count, etag: etag, body: full)

        let responder = ScriptedResponder([.finish([wire503()]), .finish([call2])])
        let client = try makeClient(responder)

        let events = try await collect(client.pull(117, etag))
        let requests = await responder.requests
        try #require(requests.count == 2)

        let requestTexts = requests.map { String(decoding: $0, as: UTF8.self) }
        #expect(requestTexts.allSatisfy { $0.contains("\r\nRange:") == false })
        #expect(requestTexts.allSatisfy { $0.contains("\r\nIf-Range:") == false })

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == full)
        #expect(result.bytes == UInt64(full.count))
        #expect(result.resolvedETag == "\"1-12\"")
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
    func manyProgressingDropsStillCompleteAfterStallBudget() async throws {
        let full = Data("abcdefghijklmnop".utf8)
        let etag = "1-16"
        var steps: [ScriptedResponder.Step] = [
            .drop([ok200(total: full.count, etag: etag, body: Data(full.prefix(1)))]),
        ]

        for start in 1...8 {
            steps.append(.drop([
                partial206(
                    start: start,
                    end: full.count - 1,
                    total: full.count,
                    etag: etag,
                    body: Data(full.dropFirst(start).prefix(1)),
                    contentLength: full.count - start
                ),
            ]))
        }

        steps.append(.finish([
            partial206(
                start: 9,
                end: full.count - 1,
                total: full.count,
                etag: etag,
                body: Data(full.dropFirst(9)),
                contentLength: full.count - 9
            ),
        ]))

        let responder = ScriptedResponder(steps)
        let client = try makeClient(responder)

        let events = try await collect(client.pull(108, etag))
        let requests = await responder.requests
        try #require(requests.count == 10)

        let resumeRequests = requests.dropFirst().map { String(decoding: $0, as: UTF8.self) }
        #expect(resumeRequests.enumerated().allSatisfy { index, request in
            request.contains("\r\nRange: bytes=\(index + 1)-\r\n")
        })
        #expect(progressValues(events).map(\.bytesWritten) == Array(1...9).map(UInt64.init) + [16])

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == full)
        #expect(result.bytes == UInt64(full.count))
    }

    @Test(.tags(.networking))
    func consecutiveStallsExhaustBudget() async throws {
        let maxConsecutiveStalls = 3
        let responder = ScriptedResponder(Array(repeating: .drop([]), count: maxConsecutiveStalls))
        let client = try makeClient(responder, maxConsecutiveStalls: maxConsecutiveStalls)

        let error = await pullError(client.pull(109, "1-12"))
        let requests = await responder.requests

        expectExhausted(error, reason: .consecutiveStalls)
        #expect(requests.count == maxConsecutiveStalls)
        #expect(tempClipFiles(clipID: 109).isEmpty)
    }

    @Test(.tags(.networking))
    func persistent503ExhaustsConsecutiveStallBudget() async throws {
        let maxConsecutiveStalls = 3
        let responder = ScriptedResponder(Array(
            repeating: .finish([wire503()]),
            count: maxConsecutiveStalls
        ))
        let client = try makeClient(responder, maxConsecutiveStalls: maxConsecutiveStalls)

        let error = await pullError(client.pull(118, "1-12"))
        let requests = await responder.requests

        expectExhausted(error, reason: .consecutiveStalls)
        #expect(requests.count == maxConsecutiveStalls)
        #expect(tempClipFiles(clipID: 118).isEmpty)
    }

    @Test(.tags(.networking))
    func progressResetsConsecutiveStallBudget() async throws {
        let full = Data("abcdef".utf8)
        let etag = "1-6"
        let responder = ScriptedResponder([
            .drop([]),
            .drop([ok200(total: full.count, etag: etag, body: Data(full.prefix(2)))]),
            .drop([]),
            .drop([partial206(
                start: 2,
                end: full.count - 1,
                total: full.count,
                etag: etag,
                body: Data(full.dropFirst(2).prefix(2)),
                contentLength: full.count - 2
            )]),
            .drop([]),
            .finish([partial206(
                start: 4,
                end: full.count - 1,
                total: full.count,
                etag: etag,
                body: Data(full.dropFirst(4)),
                contentLength: full.count - 4
            )]),
        ])
        let client = try makeClient(responder, maxConsecutiveStalls: 2)

        let events = try await collect(client.pull(110, etag))
        let requests = await responder.requests
        try #require(requests.count == 6)

        #expect(progressValues(events).map(\.bytesWritten) == [2, 4, 6])

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == full)
    }

    @Test(.tags(.networking))
    func totalReconnectCeilingStopsForeverProgressingLink() async throws {
        let maxTotalReconnects = 3
        var steps: [ScriptedResponder.Step] = [
            .drop([ok200(total: 100, etag: "initial", body: Data([0]))]),
        ]
        for index in 1...maxTotalReconnects {
            steps.append(.drop([partial206(
                start: index,
                end: 99,
                total: 100,
                etag: "initial",
                body: Data([UInt8(index)]),
                contentLength: 100 - index
            )]))
        }
        let responder = ScriptedResponder(steps)
        let client = try makeClient(
            responder,
            maxConsecutiveStalls: 2,
            maxTotalReconnects: maxTotalReconnects
        )

        let error = await pullError(client.pull(111, "initial"))
        let requests = await responder.requests

        expectExhausted(error, reason: .totalReconnects)
        #expect(requests.count == maxTotalReconnects + 1)
        #expect(tempClipFiles(clipID: 111).isEmpty)
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
    func ranged200WithSameValidatorIsMalformed() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call1 = ok200(total: full.count, etag: etag, body: Data(full.prefix(5)))
        let call2 = ok200(total: full.count, etag: etag, body: full)

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(112, etag))
        let requests = await responder.requests

        expectMalformed(error)
        #expect(requests.count == 2)
        #expect(tempClipFiles(clipID: 112).isEmpty)
    }

    @Test(.tags(.networking))
    func http404StaysTerminal() async throws {
        let responder = ScriptedResponder([.finish([wire404()])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(119, "1-12"))
        let requests = await responder.requests

        expectHTTP(error, status: 404)
        #expect(requests.count == 1)
        #expect(tempClipFiles(clipID: 119).isEmpty)
    }

    @Test(.tags(.networking))
    func http500StaysTerminal() async throws {
        let responder = ScriptedResponder([.finish([wire500()])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(120, "1-12"))
        let requests = await responder.requests

        expectHTTP(error, status: 500)
        #expect(requests.count == 1)
        #expect(tempClipFiles(clipID: 120).isEmpty)
    }

    @Test(.tags(.networking))
    func ranged200WithoutValidatorIsMalformed() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call1 = ok200(total: full.count, etag: etag, body: Data(full.prefix(5)))
        let call2 = ok200WithoutETag(total: full.count, body: full)

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(113, etag))
        let requests = await responder.requests

        expectMalformed(error)
        #expect(requests.count == 2)
        #expect(tempClipFiles(clipID: 113).isEmpty)
    }

    @Test(.tags(.networking))
    func receiveIdleTimeoutAfterProgressRetriesAndResumes() async throws {
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let call1 = ok200(total: full.count, etag: etag, body: Data(full.prefix(5)))
        let call2 = partial206(
            start: 5,
            end: full.count - 1,
            total: full.count,
            etag: etag,
            body: Data(full.dropFirst(5))
        )

        let responder = ScriptedResponder([
            .throwAfter([call1], NWByteStreamError.receiveIdleTimedOut),
            .finish([call2]),
        ])
        let client = try makeClient(responder, maxConsecutiveStalls: 1)

        let events = try await collect(client.pull(114, etag))
        let requests = await responder.requests
        try #require(requests.count == 2)

        let resume = String(decoding: requests[1], as: UTF8.self)
        #expect(resume.contains("\r\nRange: bytes=5-\r\n"))

        let result = try requireCompleted(events)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == full)
    }

    @Test(.tags(.networking))
    func receiveIdleTimeoutBeforeBodyCountsAsNoProgressStall() async throws {
        let maxConsecutiveStalls = 3
        let full = Data("abcdefghijkl".utf8)
        let etag = "1-12"
        let headOnly = ok200(total: full.count, etag: etag, body: Data())
        let responder = ScriptedResponder(Array(
            repeating: .throwAfter([headOnly], NWByteStreamError.receiveIdleTimedOut),
            count: maxConsecutiveStalls
        ))
        let client = try makeClient(responder, maxConsecutiveStalls: maxConsecutiveStalls)

        let error = await pullError(client.pull(115, etag))
        let requests = await responder.requests

        expectExhausted(error, reason: .consecutiveStalls)
        #expect(requests.count == maxConsecutiveStalls)
        #expect(tempClipFiles(clipID: 115).isEmpty)
    }

    @Test(.tags(.networking))
    func changedValidatorMakesResumedDemandStale() async throws {
        let oldBytes = Data("abcdefghij".utf8) // 10 bytes
        let call1 = ok200(total: 12, etag: "old", body: oldBytes)
        let call2 = ok200(total: 6, etag: "new", body: Data("AB".utf8))

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(106, "old"))
        let requests = await responder.requests
        #expect(requests.count == 2)
        #expect(error as? ClipPullError == .staleRepresentation)
        #expect(tempClipFiles(clipID: 106).isEmpty)
    }

    @Test(.tags(.networking))
    func changedValidatorOnPartialResponseMakesResumedDemandStale() async throws {
        let oldBytes = Data("abcdefghij".utf8)
        let call1 = ok200(total: 12, etag: "old", body: oldBytes)
        let call2 = partial206(
            start: 10,
            end: 11,
            total: 12,
            etag: "new",
            body: Data("kl".utf8)
        )
        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        var openedURL: URL?
        var pullFailure: Error?
        do {
            for try await event in client.pull(116, "old") {
                if case .opened(let url) = event { openedURL = url }
            }
        } catch {
            pullFailure = error
        }

        #expect(pullFailure as? ClipPullError == .staleRepresentation)
        #expect(openedURL.map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }

    @Test(.tags(.networking))
    func changedValidatorNeverPublishesRestartOrReplacementProgress() async throws {
        let oldPrefix = Data("ab".utf8)
        let newBytes = Data("ABCDEF".utf8)
        let call1 = ok200(total: 4, etag: "old", body: oldPrefix)
        let call2 = ok200(total: newBytes.count, etag: "new", body: newBytes)

        let responder = ScriptedResponder([.drop([call1]), .finish([call2])])
        let client = try makeClient(responder)

        let error = await pullError(client.pull(107, "old"))
        let requests = await responder.requests
        #expect(requests.count == 2)
        #expect(error as? ClipPullError == .staleRepresentation)
        #expect(tempClipFiles(clipID: 107).isEmpty)
    }

    // MARK: - Helpers

    private func makeClient(
        _ responder: ScriptedResponder,
        maxConsecutiveStalls: Int = 6,
        maxTotalReconnects: Int = 256
    ) throws -> ClipPullClient {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        return ClipPullClient.live(
            baseURL: baseURL,
            sleep: { _ in },
            maxConsecutiveStalls: maxConsecutiveStalls,
            maxTotalReconnects: maxTotalReconnects
        ) { _, request in
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

    private func wire503() -> Data {
        MJPEGWireBuilder.response(
            statusCode: 503,
            headers: [("Content-Length", "0")],
            body: Data()
        )
    }

    private func wire404() -> Data {
        MJPEGWireBuilder.response(
            statusCode: 404,
            headers: [("Content-Length", "0")],
            body: Data()
        )
    }

    private func wire500() -> Data {
        MJPEGWireBuilder.response(
            statusCode: 500,
            headers: [("Content-Length", "0")],
            body: Data()
        )
    }

    private func partial206(
        start: Int,
        end: Int,
        total: Int,
        etag: String,
        body: Data,
        contentLength: Int? = nil
    ) -> Data {
        MJPEGWireBuilder.response(
            statusCode: 206,
            headers: [
                ("Content-Type", "application/mp2t"),
                ("Content-Length", "\(contentLength ?? body.count)"),
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

    private func expectHTTP(_ error: Error?, status: Int) {
        guard case .http(let actualStatus) = error as? ClipPullError else {
            Issue.record("Expected ClipPullError.http(\(status)), got \(String(describing: error)).")
            return
        }
        #expect(actualStatus == status)
    }

    private func expectExhausted(_ error: Error?, reason: ClipPullError.ExhaustionReason) {
        guard case .exhausted(let actualReason) = error as? ClipPullError else {
            Issue.record("Expected ClipPullError.exhausted(\(reason)), got \(String(describing: error)).")
            return
        }
        #expect(actualReason == reason)
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
        case throwAfter([Data], Error) // yield the chunks, then finish with the given error
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
        case .throwAfter(let chunks, let error):
            return AsyncStreamHelpers.droppingByteStream(chunks, error: error)
        }
    }
}
