import Foundation

nonisolated enum StatusError: Error, Equatable {
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

nonisolated struct StatusClient {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var fetch: @Sendable () async throws -> StatusResponse

    static func live(
        baseURL: URL,
        pinning: InterfacePinning
    ) -> StatusClient {
        live(baseURL: baseURL, pinning: pinning) { url, request in
            try await NWByteStream.open(url: url, request: request, pinning: pinning)
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
                return try decoder.decode(StatusResponse.self, from: data)
            } catch {
                throw StatusError.decoding(error.localizedDescription)
            }
        }
    }

    static let noop = StatusClient {
        StatusResponse(
            recording: false,
            cameraState: .offline,
            bootId: "",
            uptimeS: 0,
            storage: nil,
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil
        )
    }
}
