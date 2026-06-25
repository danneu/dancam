import Foundation

nonisolated enum HealthError: Error, Equatable {
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

nonisolated struct HealthClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var fetch: @Sendable () async throws -> HealthResponse

    static func live(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        pinning: InterfacePinning = .disabled
    ) -> HealthClient {
        live(baseURL: baseURL, pinning: pinning) { url, request in
            try await NWByteStream.open(url: url, request: request, pinning: pinning)
        }
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning = .disabled,
        openByteStream: @escaping OpenByteStream
    ) -> HealthClient {
        HealthClient {
            let requestURL = baseURL.appending(path: "v1/health")

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
                throw HealthError.transport(error.localizedDescription)
            }

            guard (200...299).contains(head.statusCode) else {
                throw HealthError.http(head.statusCode)
            }

            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(HealthResponse.self, from: data)
            } catch {
                throw HealthError.decoding(error.localizedDescription)
            }
        }
    }
}
