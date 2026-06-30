import Foundation

nonisolated enum StatusError: Error, Equatable {
    case http(Int)
    case transport(String)
    case decoding(String)
    case timedOut

    var displayMessage: String {
        switch self {
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .transport(let message):
            "Transport error: \(message)"
        case .decoding(let message):
            "Decode error: \(message)"
        case .timedOut:
            "Status request timed out."
        }
    }
}

nonisolated struct StatusClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var fetch: @Sendable () async throws -> World

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration
    ) -> StatusClient {
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
        pinning: InterfacePinning = .disabled,
        openByteStream: @escaping OpenByteStream
    ) -> StatusClient {
        StatusClient {
            let requestURL = baseURL.appending(path: "v1/status")

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
                throw StatusError.transport(error.localizedDescription)
            }

            guard (200...299).contains(head.statusCode) else {
                throw StatusError.http(head.statusCode)
            }

            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(World.self, from: data)
            } catch {
                throw StatusError.decoding(error.localizedDescription)
            }
        }
    }

    static let noop = StatusClient {
        World(
            recorder: RecorderSnapshot(
                phase: .idle,
                session: 0,
                currentSegment: nil,
                detail: nil
            ),
            cameraState: .offline,
            bootId: "",
            uptimeS: 0,
            storage: nil,
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil
        )
    }
}
