import Foundation

nonisolated enum HTTPRequestEncodingError: Error, Equatable {
    case missingHost
    case invalidPort
}

nonisolated enum HTTPRequestEncoder {
    static func get(
        url: URL,
        extraHeaders: [(String, String)] = []
    ) throws -> Data {
        guard let host = url.host else {
            throw HTTPRequestEncodingError.missingHost
        }

        let path = requestPath(for: url)
        let hostHeader = try hostHeader(host: host, port: url.port, scheme: url.scheme)

        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
        ]
        lines.append(contentsOf: extraHeaders.map { "\($0.0): \($0.1)" })
        lines.append("")
        lines.append("")

        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func requestPath(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? url.path
        if path.isEmpty {
            path = "/"
        }

        if let query = components?.percentEncodedQuery {
            path += "?\(query)"
        }

        return path
    }

    private static func hostHeader(host: String, port: Int?, scheme: String?) throws -> String {
        let formattedHost = host.contains(":") ? "[\(host)]" : host

        guard let port else {
            return formattedHost
        }

        guard (1...65535).contains(port) else {
            throw HTTPRequestEncodingError.invalidPort
        }

        if port == defaultPort(for: scheme) {
            return formattedHost
        }

        return "\(formattedHost):\(port)"
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http":
            80
        case "https":
            443
        default:
            nil
        }
    }
}
