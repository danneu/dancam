import Foundation
import OSLog

nonisolated struct ClipPullResult: Equatable, Sendable {
    var fileURL: URL
    var bytes: UInt64
    var elapsed: Duration
    var throughputMbps: Double
}

nonisolated enum ClipPullEvent: Equatable, Sendable {
    case opened(fileURL: URL)
    case restarted
    case progress(bytesWritten: UInt64, expected: UInt64?)
    case completed(ClipPullResult)
}

nonisolated enum ClipPullError: Error, Equatable, Sendable {
    enum ExhaustionReason: Equatable, Sendable {
        case consecutiveStalls
        case totalReconnects
    }

    case http(Int)
    case malformedResponse(String)
    case file(String)
    case transport(String)
    case exhausted(ExhaustionReason)
}

extension ClipPullError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .http(let status):
            "Clip pull failed with HTTP \(status)."
        case .malformedResponse(let message):
            "Clip pull response was invalid: \(message)"
        case .file(let message):
            "Could not save clip file: \(message)"
        case .transport(let message):
            "Camera transfer failed: \(message)"
        case .exhausted(.consecutiveStalls):
            "Clip pull stopped after repeated reconnects without progress."
        case .exhausted(.totalReconnects):
            "Clip pull stopped after too many reconnects."
        }
    }
}

nonisolated struct ClipPullClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>
    typealias Sleep = @Sendable (Duration) async throws -> Void

    var pull: @Sendable (_ clipID: Int, _ etag: String) -> AsyncThrowingStream<ClipPullEvent, Error>

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration
    ) -> ClipPullClient {
        live(baseURL: baseURL, pinning: pinning) { url, request in
            try await NWByteStream.open(
                url: url,
                request: request,
                pinning: pinning,
                connectTimeout: connectTimeout,
                receiveIdleTimeout: receiveIdleTimeout
            )
        }
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning = .disabled,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        maxConsecutiveStalls: Int = 6,
        maxTotalReconnects: Int = 256,
        openByteStream: @escaping OpenByteStream
    ) -> ClipPullClient {
        ClipPullClient { clipID, etag in
            let (stream, continuation) = AsyncThrowingStream.makeStream(
                of: ClipPullEvent.self,
                throwing: Error.self
            )
            let clipURL = baseURL.appending(path: "v1/clips/\(clipID)")
            let producerTask = Task.detached {
                await producePull(
                    clipID: clipID,
                    clipURL: clipURL,
                    listETag: etag,
                    openByteStream: openByteStream,
                    sleep: sleep,
                    maxConsecutiveStalls: maxConsecutiveStalls,
                    maxTotalReconnects: maxTotalReconnects,
                    continuation: continuation
                )
            }

            continuation.onTermination = { _ in
                producerTask.cancel()
            }

            return stream
        }
    }

    static let noop = ClipPullClient { _, _ in
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    /// Bounded retry budget for a single `pull()`. A pull rides out drops by
    /// reconnecting and resuming from the last byte; it gives up after repeated
    /// no-progress reconnects or an absolute runaway reconnect ceiling.
    private static let baseBackoff = Duration.milliseconds(250)
    private static let maxBackoff = Duration.seconds(4)

    private static let logger = Logger(subsystem: "com.danneu.dancam", category: "pull")
    private static let signposter = OSSignposter(logger: logger)

    private enum AttemptOutcome {
        case completed
        case retry(madeProgress: Bool)
    }

    private static func producePull(
        clipID: Int,
        clipURL: URL,
        listETag: String,
        openByteStream: @escaping OpenByteStream,
        sleep: @escaping Sleep,
        maxConsecutiveStalls: Int,
        maxTotalReconnects: Int,
        continuation: AsyncThrowingStream<ClipPullEvent, Error>.Continuation
    ) async {
        var outputURL: URL?
        var fileHandle: FileHandle?
        var shouldKeepOutput = false

        do {
            outputURL = try prepareOutputURL(clipID: clipID)
            guard let outputURL else {
                throw ClipPullError.file("Missing output URL.")
            }

            let outputHandle = try FileHandle(forWritingTo: outputURL)
            fileHandle = outputHandle
            continuation.yield(.opened(fileURL: outputURL))

            let clock = ContinuousClock()
            let signpostID = signposter.makeSignpostID()
            let signpostState = signposter.beginInterval("Clip pull", id: signpostID)
            defer {
                signposter.endInterval("Clip pull", signpostState)
            }
            let start = clock.now

            // State that persists across reconnect attempts. `resumeETag` is the
            // quoted validator the next `If-Range` carries; it always describes the
            // bytes currently on disk (initialized from the list etag, replaced by
            // an accepted `200`'s own `ETag` whenever the file is rewritten from 0).
            var bytesWritten: UInt64 = 0
            var expectedBytes: UInt64?
            var resumeETag = httpEntityTag(listETag)
            var consecutiveStalls = 0
            var totalReconnects = 0

            attempts: while true {
                let outcome = try await runAttempt(
                    clipURL: clipURL,
                    openByteStream: openByteStream,
                    fileHandle: outputHandle,
                    bytesWritten: &bytesWritten,
                    expectedBytes: &expectedBytes,
                    resumeETag: &resumeETag,
                    continuation: continuation
                )

                switch outcome {
                case .completed:
                    break attempts
                case .retry(let madeProgress):
                    totalReconnects += 1
                    if madeProgress {
                        consecutiveStalls = 0
                    } else {
                        consecutiveStalls += 1
                    }

                    if consecutiveStalls >= maxConsecutiveStalls {
                        throw ClipPullError.exhausted(.consecutiveStalls)
                    }
                    if totalReconnects > maxTotalReconnects {
                        throw ClipPullError.exhausted(.totalReconnects)
                    }

                    try await sleep(backoffDuration(forConsecutiveStalls: consecutiveStalls))
                }
            }

            let elapsed = start.duration(to: clock.now)
            let elapsedSeconds = seconds(in: elapsed)
            let throughput = elapsedSeconds > 0
                ? Double(bytesWritten) * 8.0 / 1_000_000.0 / elapsedSeconds
                : 0
            fileHandle = nil
            try mappingLocalFileErrors("close clip file") { try outputHandle.close() }
            shouldKeepOutput = true
            logger.info(
                "clip_id=\(clipID, privacy: .public) bytes=\(bytesWritten, privacy: .public) elapsed_s=\(elapsedSeconds, privacy: .public) throughput_mbps=\(throughput, privacy: .public)"
            )

            continuation.yield(.completed(ClipPullResult(
                fileURL: outputURL,
                bytes: bytesWritten,
                elapsed: elapsed,
                throughputMbps: throughput
            )))
            continuation.finish()
        } catch is CancellationError {
            try? fileHandle?.close()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish()
        } catch let error as ClipPullError {
            try? fileHandle?.close()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish(throwing: error)
        } catch {
            try? fileHandle?.close()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish(throwing: ClipPullError.transport(error.localizedDescription))
        }
    }

    /// One connect -> head-parse -> write-body pass. Returns `.completed` only when
    /// the whole file is on disk, `.retry` for a rideable drop (connect failure,
    /// premature EOF, or a mid-stream transport error), and throws a terminal
    /// `ClipPullError`/`CancellationError` for everything else.
    private static func runAttempt(
        clipURL: URL,
        openByteStream: @escaping OpenByteStream,
        fileHandle: FileHandle,
        bytesWritten: inout UInt64,
        expectedBytes: inout UInt64?,
        resumeETag: inout String,
        continuation: AsyncThrowingStream<ClipPullEvent, Error>.Continuation
    ) async throws -> AttemptOutcome {
        let usedRange = bytesWritten > 0
        let request = try makeRequest(
            url: clipURL,
            bytesWritten: bytesWritten,
            resumeETag: resumeETag
        )

        let byteStream: AsyncThrowingStream<Data, Error>
        do {
            byteStream = try await openByteStream(clipURL, request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A connect / open failure before any stream -- ride it out.
            return .retry(madeProgress: false)
        }

        var headParser = HTTPResponseHeadParser()
        var bodyDecoder: HTTPBodyDecoder?
        var wroteBodyBytesThisAttempt = false

        do {
            for try await chunk in byteStream {
                try Task.checkCancellation()

                if bodyDecoder == nil {
                    switch try headParser.append(chunk) {
                    case .needsMoreData:
                        continue
                    case .complete(let head, let leftoverBody):
                        var decoder = try prepareBodyDecoder(
                            head: head,
                            usedRange: usedRange,
                            fileHandle: fileHandle,
                            bytesWritten: &bytesWritten,
                            expectedBytes: &expectedBytes,
                            resumeETag: &resumeETag,
                            continuation: continuation
                        )
                        wroteBodyBytesThisAttempt = try writeDecodedChunks(
                            from: leftoverBody,
                            decoder: &decoder,
                            fileHandle: fileHandle,
                            bytesWritten: &bytesWritten,
                            expectedBytes: expectedBytes,
                            continuation: continuation
                        ) || wroteBodyBytesThisAttempt
                        bodyDecoder = decoder
                    }
                } else {
                    wroteBodyBytesThisAttempt = try writeDecodedChunks(
                        from: chunk,
                        decoder: &bodyDecoder!,
                        fileHandle: fileHandle,
                        bytesWritten: &bytesWritten,
                        expectedBytes: expectedBytes,
                        continuation: continuation
                    ) || wroteBodyBytesThisAttempt
                }

                if bodyDecoder?.isComplete == true {
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPResponseHeadError {
            throw ClipPullError.malformedResponse(String(describing: error))
        } catch let error as HTTPBodyDecodingError {
            throw ClipPullError.malformedResponse(String(describing: error))
        } catch let error as ClipPullError {
            throw error
        } catch {
            // A mid-stream transport drop (`finish(throwing:)`) -- ride it out.
            return .retry(madeProgress: wroteBodyBytesThisAttempt)
        }

        // The stream ended. A framed body that never completed is a premature EOF
        // (a dropped link), which is retryable, not terminal.
        guard bodyDecoder?.isComplete == true else {
            return .retry(madeProgress: wroteBodyBytesThisAttempt)
        }

        // `isComplete` only means *this response's* framed body arrived; for a `206`
        // that is just the requested range. The pull is done only when the whole
        // file is on disk.
        guard let expected = expectedBytes, bytesWritten == expected else {
            throw ClipPullError.malformedResponse("Body framed complete before whole-file length.")
        }

        return .completed
    }

    private static func makeRequest(
        url: URL,
        bytesWritten: UInt64,
        resumeETag: String
    ) throws -> Data {
        // The request depends on progress, not on attempt number: with nothing on
        // disk send a plain `GET` (expect `200`); once bytes have landed resume from
        // the last byte with a validated `Range`.
        if bytesWritten == 0 {
            return try HTTPRequestEncoder.get(
                url: url,
                extraHeaders: [("Connection", "close")]
            )
        }

        return try HTTPRequestEncoder.get(
            url: url,
            extraHeaders: [
                ("Connection", "close"),
                ("Range", "bytes=\(bytesWritten)-"),
                ("If-Range", resumeETag),
            ]
        )
    }

    /// Validate the response head against the on-disk progress and return a decoder
    /// framing the body to append. Mutates the persistent state (`bytesWritten`,
    /// `expectedBytes`, `resumeETag`, the file) as the status dictates, or throws a
    /// terminal error for a stale/buggy partial.
    private static func prepareBodyDecoder(
        head: HTTPResponseHead,
        usedRange: Bool,
        fileHandle: FileHandle,
        bytesWritten: inout UInt64,
        expectedBytes: inout UInt64?,
        resumeETag: inout String,
        continuation: AsyncThrowingStream<ClipPullEvent, Error>.Continuation
    ) throws -> HTTPBodyDecoder {
        let status = head.statusCode

        // No bytes on disk yet: a plain `GET` answered by a full `200`.
        if usedRange == false {
            guard status == 200 else {
                throw ClipPullError.http(status)
            }
            expectedBytes = contentLength(from: head)
            if let etag = head.headerValue("etag") {
                resumeETag = etag
            }
            return HTTPBodyDecoder(head: head)
        }

        switch status {
        case 206:
            // The resume request is always open-ended `bytes=<bytesWritten>-`, so a
            // conformant server returns the file's tail. Reject a wrong offset or a
            // short end before appending -- either would corrupt the file.
            guard
                let contentRange = head.headerValue("content-range"),
                let parsed = HTTPContentRange.parse(contentRange),
                parsed.start == bytesWritten,
                parsed.end + 1 == parsed.total,
                expectedBytes == parsed.total
            else {
                throw ClipPullError.malformedResponse("Invalid 206 Content-Range for resume.")
            }
            return HTTPBodyDecoder(head: head)
        case 200:
            // The validator changed (`If-Range` ignored): the disk now holds the wrong
            // representation. Truncate, rewrite from 0, and track the new validator so
            // a later drop resumes against it rather than the stale list etag.
            guard let etag = head.headerValue("etag"), etag != resumeETag else {
                throw ClipPullError.malformedResponse("Ranged 200 did not carry a new validator.")
            }
            try mappingLocalFileErrors("reset clip file for restart") {
                try fileHandle.truncate(atOffset: 0)
                try fileHandle.seek(toOffset: 0)
            }
            bytesWritten = 0
            expectedBytes = contentLength(from: head)
            resumeETag = etag
            continuation.yield(.restarted)
            return HTTPBodyDecoder(head: head)
        case 416:
            // The drop landed at EOF and the server now sees the request as past the
            // end; only complete if the whole file is already on disk.
            guard let expected = expectedBytes, expected == bytesWritten else {
                throw ClipPullError.malformedResponse("416 with an incomplete file.")
            }
            return HTTPBodyDecoder(head: head)
        default:
            throw ClipPullError.http(status)
        }
    }

    private static func backoffDuration(forConsecutiveStalls consecutiveStalls: Int) -> Duration {
        let exponent = max(consecutiveStalls - 1, 0)
        let multiplier = 1 << min(exponent, 16)
        let scaled = baseBackoff * multiplier
        return scaled < maxBackoff ? scaled : maxBackoff
    }

    private static func prepareOutputURL(clipID: Int) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        let prefix = "clip-\(clipID)-"

        for url in (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "ts" {
            try? fileManager.removeItem(at: url)
        }

        let outputURL = directory.appending(path: "\(prefix)\(UUID().uuidString).ts")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw ClipPullError.file("Could not create \(outputURL.lastPathComponent).")
        }

        return outputURL
    }

    private static func contentLength(from head: HTTPResponseHead) -> UInt64? {
        guard let value = head.headerValue("content-length") else {
            return nil
        }

        return UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Run a local temp-file operation, mapping any failure to a terminal
    /// `ClipPullError.file`. A write/truncate/seek/close failure (disk full, I/O
    /// error, revoked sandbox -- close can surface a deferred write error) is NOT a
    /// transport drop -- reconnecting and resuming cannot fix local storage -- so it
    /// must end the pull, not re-enter the resume loop.
    /// Routing it through `.file` lands it in `runAttempt`'s terminal `ClipPullError`
    /// catch instead of the bare `.retry` catch that rides out network drops.
    private static func mappingLocalFileErrors<T>(
        _ context: String, _ body: () throws -> T
    ) throws -> T {
        do { return try body() }
        catch { throw ClipPullError.file("\(context): \(error.localizedDescription)") }
    }

    private static func writeDecodedChunks(
        from data: Data,
        decoder: inout HTTPBodyDecoder,
        fileHandle: FileHandle,
        bytesWritten: inout UInt64,
        expectedBytes: UInt64?,
        continuation: AsyncThrowingStream<ClipPullEvent, Error>.Continuation
    ) throws -> Bool {
        var didWrite = false
        for decodedChunk in try decoder.append(data) where decodedChunk.isEmpty == false {
            try mappingLocalFileErrors("write clip body") {
                try fileHandle.write(contentsOf: decodedChunk)
            }
            bytesWritten += UInt64(decodedChunk.count)
            didWrite = true
            continuation.yield(.progress(bytesWritten: bytesWritten, expected: expectedBytes))
        }
        return didWrite
    }

    private static func seconds(in duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}
