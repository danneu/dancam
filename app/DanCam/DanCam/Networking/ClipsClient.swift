import Foundation

nonisolated enum ClipsError: Error, Equatable {
    case http(Int)
    case transport(TransportFailure)
    case decoding(String)

    var displayMessage: String {
        switch self {
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .transport(let failure):
            failure.displayMessage
        case .decoding(let message):
            "Decode error: \(message)"
        }
    }
}

extension ClipsError {
    var isRetryable: Bool {
        switch self {
        case .transport:
            true
        case .http(let code):
            (500...599).contains(code)
        case .decoding:
            false
        }
    }
}

nonisolated struct ClipsClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var fetch: @Sendable (_ cursor: ClipCursor?) async throws -> ClipsResponse
    var delete: @Sendable (_ clipID: Int) async throws -> Void

    init(
        fetch: @escaping @Sendable (_ cursor: ClipCursor?) async throws -> ClipsResponse,
        delete: @escaping @Sendable (_ clipID: Int) async throws -> Void = { _ in }
    ) {
        self.fetch = fetch
        self.delete = delete
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration,
        makeIdempotencyKey: @escaping @Sendable () -> String = { UUID().uuidString }
    ) -> ClipsClient {
        live(baseURL: baseURL, pinning: pinning, makeIdempotencyKey: makeIdempotencyKey) { url, request in
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
        openByteStream: @escaping OpenByteStream
    ) -> ClipsClient {
        ClipsClient(fetch: { cursor in
            let requestURL = if let cursor {
                baseURL
                    .appending(path: "v1/clips")
                    .appending(queryItems: [URLQueryItem(name: "cursor", value: String(cursor.rawValue))])
            } else {
                baseURL.appending(path: "v1/clips")
            }

            let head: HTTPResponseHead
            let data: Data

            do {
                (head, data) = try await HTTPRequestResponse.get(
                    url: requestURL,
                    openByteStream: openByteStream
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                throw ClipsError.transport(.wrapping(error))
            }

            guard (200...299).contains(head.statusCode) else {
                throw ClipsError.http(head.statusCode)
            }

            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(ClipsResponse.self, from: data)
            } catch {
                throw ClipsError.decoding(error.localizedDescription)
            }
        }, delete: { clipID in
            let requestURL = baseURL.appending(path: "v1/clips/\(clipID)")
            let head: HTTPResponseHead

            do {
                (head, _) = try await HTTPRequestResponse.delete(
                    url: requestURL,
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
                throw ClipsError.transport(.wrapping(error))
            }

            guard (200...299).contains(head.statusCode) else {
                throw ClipsError.http(head.statusCode)
            }
        })
    }

    static let noop = ClipsClient(
        fetch: { _ in ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil) },
        delete: { _ in }
    )
}
