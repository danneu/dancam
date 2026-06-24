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
    var fetch: () async throws -> HealthResponse

    static func live(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) -> HealthClient {
        HealthClient {
            let requestURL = baseURL.appending(path: "v1/health")
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"

            let data: Data
            let response: URLResponse

            do {
                (data, response) = try await transport(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                throw HealthError.transport(error.localizedDescription)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw HealthError.transport("Missing HTTP response")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw HealthError.http(httpResponse.statusCode)
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
