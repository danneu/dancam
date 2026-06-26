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

    var fetch: @Sendable () async throws -> ClipsResponse

    static func live(
        baseURL: URL,
        pinning: InterfacePinning
    ) -> ClipsClient {
        live(baseURL: baseURL, pinning: pinning) { url, request in
            try await NWByteStream.open(url: url, request: request, pinning: pinning)
        }
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning = .disabled,
        openByteStream: @escaping OpenByteStream
    ) -> ClipsClient {
        ClipsClient {
            let requestURL = baseURL.appending(path: "v1/clips")

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

    static let noop = ClipsClient {
        ClipsResponse(clips: [], serverTimeMs: 0, nextCursor: nil)
    }
}
