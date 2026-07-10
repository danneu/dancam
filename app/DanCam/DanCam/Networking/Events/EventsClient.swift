import Foundation

nonisolated enum EventsError: Error, Equatable {
    case transport(TransportFailure)
    case http(Int)
    case notEventStream(String)
    case malformedResponse(String)
    case decoding(String)

    var displayMessage: String {
        switch self {
        case .transport(let failure):
            failure.displayMessage
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .notEventStream(let contentType):
            "Unexpected events content type: \(contentType)"
        case .malformedResponse(let message):
            "Malformed events stream: \(message)"
        case .decoding(let message):
            "Event decode error: \(message)"
        }
    }
}

nonisolated struct EventsClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var connect: @Sendable () -> AsyncThrowingStream<CameraEvent, Error>

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration
    ) -> EventsClient {
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
        openByteStream: @escaping OpenByteStream
    ) -> EventsClient {
        let eventsURL = baseURL.appending(path: "v1/events")

        return EventsClient {
            let (stream, continuation) = AsyncThrowingStream.makeStream(
                of: CameraEvent.self,
                throwing: Error.self
            )

            let producerTask = Task.detached {
                await produceEvents(
                    eventsURL: eventsURL,
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

    static let noop = EventsClient {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    private static func produceEvents(
        eventsURL: URL,
        openByteStream: @escaping OpenByteStream,
        continuation: AsyncThrowingStream<CameraEvent, Error>.Continuation
    ) async {
        do {
            let request = try HTTPRequestEncoder.get(
                url: eventsURL,
                extraHeaders: [("Accept", "text/event-stream")]
            )
            let byteStream = try await openByteStream(eventsURL, request)
            var headParser = HTTPResponseHeadParser()
            var bodyDecoder: HTTPBodyDecoder?
            var eventParser = SSEEventParser()
            let jsonDecoder = JSONDecoder()
            jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase

            for try await chunk in byteStream {
                try Task.checkCancellation()

                if bodyDecoder == nil {
                    switch try headParser.append(chunk) {
                    case .needsMoreData:
                        continue
                    case .complete(let head, let leftoverBody):
                        try validate(head: head)
                        bodyDecoder = HTTPBodyDecoder(head: head)
                        try emitEvents(
                            from: leftoverBody,
                            decoder: &bodyDecoder!,
                            parser: &eventParser,
                            jsonDecoder: jsonDecoder,
                            continuation: continuation
                        )
                    }
                } else {
                    try emitEvents(
                        from: chunk,
                        decoder: &bodyDecoder!,
                        parser: &eventParser,
                        jsonDecoder: jsonDecoder,
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
        } catch let error as EventsError {
            continuation.finish(throwing: error)
        } catch let error as HTTPResponseHeadError {
            continuation.finish(throwing: EventsError.malformedResponse(String(describing: error)))
        } catch let error as HTTPBodyDecodingError {
            continuation.finish(throwing: EventsError.malformedResponse(String(describing: error)))
        } catch let error as DecodingError {
            continuation.finish(throwing: EventsError.decoding(String(describing: error)))
        } catch {
            continuation.finish(throwing: EventsError.transport(.wrapping(error)))
        }
    }

    private static func validate(head: HTTPResponseHead) throws {
        guard (200...299).contains(head.statusCode) else {
            throw EventsError.http(head.statusCode)
        }

        let contentType = head.headerValue("content-type") ?? ""
        guard ContentType.mediaType(from: contentType) == "text/event-stream" else {
            throw EventsError.notEventStream(contentType)
        }
    }

    private static func emitEvents(
        from data: Data,
        decoder: inout HTTPBodyDecoder,
        parser: inout SSEEventParser,
        jsonDecoder: JSONDecoder,
        continuation: AsyncThrowingStream<CameraEvent, Error>.Continuation
    ) throws {
        for decodedChunk in try decoder.append(data) {
            for payload in parser.append(decodedChunk) {
                continuation.yield(try jsonDecoder.decode(CameraEvent.self, from: payload))
            }
        }
    }
}
