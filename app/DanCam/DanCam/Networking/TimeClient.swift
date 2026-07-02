import Foundation

nonisolated enum TimeSyncError: Error, Equatable {
    case http(Int)
    case transport(String)
    case encoding(String)

    var displayMessage: String {
        switch self {
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .transport(let message):
            "Transport error: \(message)"
        case .encoding(let message):
            "Encoding error: \(message)"
        }
    }
}

nonisolated struct TimeClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var sync: @Sendable () async throws -> Void

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration,
        makeIdempotencyKey: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) -> TimeClient {
        live(
            baseURL: baseURL,
            pinning: pinning,
            makeIdempotencyKey: makeIdempotencyKey,
            now: now
        ) { url, request in
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
        makeIdempotencyKey: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        },
        openByteStream: @escaping OpenByteStream
    ) -> TimeClient {
        TimeClient {
            try await sendTimeSync(
                baseURL: baseURL,
                epochMs: now(),
                makeIdempotencyKey: makeIdempotencyKey,
                openByteStream: openByteStream
            )
        }
    }

    static let noop = TimeClient(sync: {})

    private struct TimeSyncRequest: Encodable {
        var epochMs: UInt64
    }

    private static func sendTimeSync(
        baseURL: URL,
        epochMs: UInt64,
        makeIdempotencyKey: @Sendable () -> String,
        openByteStream: @escaping OpenByteStream
    ) async throws {
        let requestURL = baseURL.appending(path: "v1/time")

        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            body = try encoder.encode(TimeSyncRequest(epochMs: epochMs))
        } catch {
            throw TimeSyncError.encoding(error.localizedDescription)
        }

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
        } catch let error as TimeSyncError {
            throw error
        } catch {
            throw TimeSyncError.transport(error.localizedDescription)
        }

        guard (200...299).contains(head.statusCode) else {
            throw TimeSyncError.http(head.statusCode)
        }
    }
}
