import Foundation
import OSLog

nonisolated struct ClipPullResult: Equatable, Sendable {
    var fileURL: URL
    var bytes: UInt64
    var elapsed: Duration
    var throughputMbps: Double
}

nonisolated enum ClipPullEvent: Equatable, Sendable {
    case progress(bytesWritten: UInt64, expected: UInt64?)
    case completed(ClipPullResult)
}

nonisolated enum ClipPullError: Error, Equatable {
    case http(Int)
    case malformedResponse(String)
    case file(String)
    case transport(String)
}

nonisolated struct ClipPullClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var pull: @Sendable (_ clipID: Int) -> AsyncThrowingStream<ClipPullEvent, Error>

    static func live(
        baseURL: URL,
        pinning: InterfacePinning
    ) -> ClipPullClient {
        live(baseURL: baseURL, pinning: pinning) { url, request in
            try await NWByteStream.open(url: url, request: request, pinning: pinning)
        }
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning = .disabled,
        openByteStream: @escaping OpenByteStream
    ) -> ClipPullClient {
        ClipPullClient { clipID in
            let (stream, continuation) = AsyncThrowingStream.makeStream(
                of: ClipPullEvent.self,
                throwing: Error.self
            )
            let clipURL = baseURL.appending(path: "v1/clips/\(clipID)")
            let producerTask = Task.detached {
                await producePull(
                    clipID: clipID,
                    clipURL: clipURL,
                    openByteStream: openByteStream,
                    continuation: continuation
                )
            }

            continuation.onTermination = { _ in
                producerTask.cancel()
            }

            return stream
        }
    }

    static let noop = ClipPullClient { _ in
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    private static let logger = Logger(subsystem: "com.danneu.dancam", category: "pull")
    private static let signposter = OSSignposter(logger: logger)

    private static func producePull(
        clipID: Int,
        clipURL: URL,
        openByteStream: @escaping OpenByteStream,
        continuation: AsyncThrowingStream<ClipPullEvent, Error>.Continuation
    ) async {
        var outputURL: URL?
        var fileHandle: FileHandle?
        var shouldKeepOutput = false

        do {
            let request = try HTTPRequestEncoder.get(
                url: clipURL,
                extraHeaders: [("Connection", "close")]
            )
            outputURL = try prepareOutputURL(clipID: clipID)
            guard let outputURL else {
                throw ClipPullError.file("Missing output URL.")
            }

            let outputHandle = try FileHandle(forWritingTo: outputURL)
            fileHandle = outputHandle

            let clock = ContinuousClock()
            let signpostID = signposter.makeSignpostID()
            let signpostState = signposter.beginInterval("Clip pull", id: signpostID)
            defer {
                signposter.endInterval("Clip pull", signpostState)
            }
            let start = clock.now
            let byteStream = try await openByteStream(clipURL, request)
            var headParser = HTTPResponseHeadParser()
            var bodyDecoder: HTTPBodyDecoder?
            var expectedBytes: UInt64?
            var bytesWritten: UInt64 = 0

            for try await chunk in byteStream {
                try Task.checkCancellation()

                if bodyDecoder == nil {
                    switch try headParser.append(chunk) {
                    case .needsMoreData:
                        continue
                    case .complete(let head, let leftoverBody):
                        try validate(head: head)
                        expectedBytes = contentLength(from: head)
                        var parsedDecoder = HTTPBodyDecoder(head: head)
                        try writeDecodedChunks(
                            from: leftoverBody,
                            decoder: &parsedDecoder,
                            fileHandle: outputHandle,
                            bytesWritten: &bytesWritten,
                            expectedBytes: expectedBytes,
                            continuation: continuation
                        )
                        bodyDecoder = parsedDecoder
                    }
                } else {
                    try writeDecodedChunks(
                        from: chunk,
                        decoder: &bodyDecoder!,
                        fileHandle: outputHandle,
                        bytesWritten: &bytesWritten,
                        expectedBytes: expectedBytes,
                        continuation: continuation
                    )
                }

                if bodyDecoder?.isComplete == true {
                    break
                }
            }

            guard bodyDecoder?.isComplete == true else {
                throw ClipPullError.malformedResponse("Response body ended before Content-Length.")
            }

            let elapsed = start.duration(to: clock.now)
            let elapsedSeconds = seconds(in: elapsed)
            let throughput = elapsedSeconds > 0
                ? Double(bytesWritten) * 8.0 / 1_000_000.0 / elapsedSeconds
                : 0
            fileHandle?.closeFile()
            fileHandle = nil
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
            fileHandle?.closeFile()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish()
        } catch let error as ClipPullError {
            fileHandle?.closeFile()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish(throwing: error)
        } catch let error as HTTPResponseHeadError {
            fileHandle?.closeFile()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish(throwing: ClipPullError.malformedResponse(String(describing: error)))
        } catch let error as HTTPBodyDecodingError {
            fileHandle?.closeFile()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish(throwing: ClipPullError.malformedResponse(String(describing: error)))
        } catch {
            fileHandle?.closeFile()
            if shouldKeepOutput == false, let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation.finish(throwing: ClipPullError.transport(error.localizedDescription))
        }
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

    private static func validate(head: HTTPResponseHead) throws {
        guard (200...299).contains(head.statusCode) else {
            throw ClipPullError.http(head.statusCode)
        }
    }

    private static func contentLength(from head: HTTPResponseHead) -> UInt64? {
        guard let value = head.headerValue("content-length") else {
            return nil
        }

        return UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writeDecodedChunks(
        from data: Data,
        decoder: inout HTTPBodyDecoder,
        fileHandle: FileHandle,
        bytesWritten: inout UInt64,
        expectedBytes: UInt64?,
        continuation: AsyncThrowingStream<ClipPullEvent, Error>.Continuation
    ) throws {
        for decodedChunk in try decoder.append(data) where decodedChunk.isEmpty == false {
            fileHandle.write(decodedChunk)
            bytesWritten += UInt64(decodedChunk.count)
            continuation.yield(.progress(bytesWritten: bytesWritten, expected: expectedBytes))
        }
    }

    private static func seconds(in duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}
