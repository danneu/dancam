import Foundation

nonisolated enum ClipsError: Error, Equatable {
    case http(Int)
    case transport(String)
    case decoding(String)

    var displayMessage: String {
        switch self {
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .transport(let message):
            "Transport error: \(message)"
        case .decoding(let message):
            "Decode error: \(message)"
        }
    }
}

nonisolated struct ClipsClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var fetch: @Sendable (_ cursor: String?) async throws -> ClipsResponse

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration
    ) -> ClipsClient {
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
    ) -> ClipsClient {
        ClipsClient { cursor in
            let requestURL = if let cursor {
                baseURL
                    .appending(path: "v1/clips")
                    .appending(queryItems: [URLQueryItem(name: "cursor", value: cursor)])
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
                throw ClipsError.transport(error.localizedDescription)
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
        }
    }

    static let noop = ClipsClient { _ in
        ClipsResponse(clips: [], serverTimeMs: 0, nextCursor: nil)
    }
}
