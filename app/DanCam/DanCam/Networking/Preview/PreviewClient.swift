import Foundation

nonisolated struct PreviewFrame: Equatable, Sendable, CustomStringConvertible {
    var sequence: Int
    var jpeg: Data

    var description: String {
        "PreviewFrame(seq: \(sequence), \(jpeg.count) bytes)"
    }
}

nonisolated enum PreviewError: Error, Equatable {
    case connectionFailed(String)
    case http(Int)
    case notMultipart(String)
    case missingBoundary
    case malformedResponse(String)

    var displayMessage: String {
        switch self {
        case .connectionFailed(let message):
            "Connection failed: \(message)"
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .notMultipart(let contentType):
            "Unexpected preview content type: \(contentType)"
        case .missingBoundary:
            "Preview stream is missing a multipart boundary."
        case .malformedResponse(let message):
            "Malformed preview stream: \(message)"
        }
    }
}

nonisolated struct PreviewClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var connect: @Sendable () -> AsyncThrowingStream<PreviewFrame, Error>

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration
    ) -> PreviewClient {
        live(baseURL: baseURL, pinning: pinning) { url, request in
            try await NWByteStream.open(
                url: url,
                request: request,
                pinning: pinning,
                connectTimeout: connectTimeout
            )
        }
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        openByteStream: @escaping OpenByteStream
    ) -> PreviewClient {
        let previewURL = baseURL.appending(path: "v1/preview/live.mjpeg")

        return PreviewClient {
            let (stream, continuation) = AsyncThrowingStream.makeStream(
                of: PreviewFrame.self,
                throwing: Error.self,
                bufferingPolicy: .bufferingNewest(1)
            )

            let producerTask = Task.detached {
                await produceFrames(
                    previewURL: previewURL,
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

    static let noop = PreviewClient {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    private static func produceFrames(
        previewURL: URL,
        openByteStream: @escaping OpenByteStream,
        continuation: AsyncThrowingStream<PreviewFrame, Error>.Continuation
    ) async {
        do {
            let request = try HTTPRequestEncoder.get(url: previewURL)
            let byteStream = try await openByteStream(previewURL, request)
            var headParser = HTTPResponseHeadParser()
            var bodyDecoder: HTTPBodyDecoder?
            var multipartParser: MultipartMJPEGParser?
            var sequence = 0

            for try await chunk in byteStream {
                try Task.checkCancellation()

                if bodyDecoder == nil {
                    switch try headParser.append(chunk) {
                    case .needsMoreData:
                        continue
                    case .complete(let head, let leftoverBody):
                        try validate(head: head)
                        let contentType = head.headerValue("content-type") ?? ""
                        let boundary = try requireBoundary(contentType: contentType)
                        bodyDecoder = HTTPBodyDecoder(head: head)
                        multipartParser = MultipartMJPEGParser(boundary: boundary)
                        try emitFrames(
                            from: leftoverBody,
                            decoder: &bodyDecoder!,
                            parser: &multipartParser!,
                            sequence: &sequence,
                            continuation: continuation
                        )
                    }
                } else {
                    try emitFrames(
                        from: chunk,
                        decoder: &bodyDecoder!,
                        parser: &multipartParser!,
                        sequence: &sequence,
                        continuation: continuation
                    )
                }

                if bodyDecoder?.isComplete == true {
                    break
                }
            }

            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch let error as PreviewError {
            continuation.finish(throwing: error)
        } catch let error as HTTPResponseHeadError {
            continuation.finish(throwing: PreviewError.malformedResponse(String(describing: error)))
        } catch let error as HTTPBodyDecodingError {
            continuation.finish(throwing: PreviewError.malformedResponse(String(describing: error)))
        } catch {
            continuation.finish(throwing: PreviewError.connectionFailed(error.localizedDescription))
        }
    }

    private static func validate(head: HTTPResponseHead) throws {
        guard (200...299).contains(head.statusCode) else {
            throw PreviewError.http(head.statusCode)
        }

        let contentType = head.headerValue("content-type") ?? ""
        guard ContentType.mediaType(from: contentType) == "multipart/x-mixed-replace" else {
            throw PreviewError.notMultipart(contentType)
        }
    }

    private static func requireBoundary(contentType: String) throws -> String {
        guard let boundary = ContentType.boundary(from: contentType) else {
            throw PreviewError.missingBoundary
        }

        return boundary
    }

    private static func emitFrames(
        from data: Data,
        decoder: inout HTTPBodyDecoder,
        parser: inout MultipartMJPEGParser,
        sequence: inout Int,
        continuation: AsyncThrowingStream<PreviewFrame, Error>.Continuation
    ) throws {
        for decodedChunk in try decoder.append(data) {
            for jpeg in try parser.append(decodedChunk) {
                continuation.yield(PreviewFrame(sequence: sequence, jpeg: jpeg))
                sequence += 1
            }
        }
    }
}
