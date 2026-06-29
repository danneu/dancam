import Foundation

nonisolated enum RecordingError: Error, Equatable {
    case http(Int)
    case transport(String)

    var displayMessage: String {
        switch self {
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .transport(let message):
            "Transport error: \(message)"
        }
    }
}

nonisolated struct RecordingClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var start: @Sendable () async throws -> Void
    var stop: @Sendable () async throws -> Void

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        makeIdempotencyKey: @escaping @Sendable () -> String = { UUID().uuidString }
    ) -> RecordingClient {
        live(
            baseURL: baseURL,
            pinning: pinning,
            makeIdempotencyKey: makeIdempotencyKey
        ) { url, request in
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
        pinning: InterfacePinning = .disabled,
        makeIdempotencyKey: @escaping @Sendable () -> String = { UUID().uuidString },
        openByteStream: @escaping OpenByteStream
    ) -> RecordingClient {
        RecordingClient(
            start: {
                try await sendRecordingCommand(
                    baseURL: baseURL,
                    path: "v1/recording/start",
                    makeIdempotencyKey: makeIdempotencyKey,
                    openByteStream: openByteStream
                )
            },
            stop: {
                try await sendRecordingCommand(
                    baseURL: baseURL,
                    path: "v1/recording/stop",
                    makeIdempotencyKey: makeIdempotencyKey,
                    openByteStream: openByteStream
                )
            }
        )
    }

    static let noop = RecordingClient(start: {}, stop: {})

    private static func sendRecordingCommand(
        baseURL: URL,
        path: String,
        makeIdempotencyKey: @Sendable () -> String,
        openByteStream: @escaping OpenByteStream
    ) async throws {
        let requestURL = baseURL.appending(path: path)
        let body = Data("{}".utf8)

        let head: HTTPResponseHead

        do {
            (head, _) = try await HTTPRequestResponse.post(
                url: requestURL,
                body: body,
                extraHeaders: [
                    ("Content-Type", "application/json"),
                    ("Idempotency-Key", makeIdempotencyKey()),
                ],
                openByteStream: openByteStream
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw RecordingError.transport(error.localizedDescription)
        }

        guard (200...299).contains(head.statusCode) else {
            throw RecordingError.http(head.statusCode)
        }
    }
}
