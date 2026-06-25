import Foundation

nonisolated enum HTTPResponseHeadError: Error, Equatable {
    case headTooLarge
    case malformedResponse
}

nonisolated struct HTTPResponseHead: Equatable, Sendable {
    var statusCode: Int
    var reasonPhrase: String
    private var headers: [String: [String]]

    init(statusCode: Int, reasonPhrase: String, headers: [String: [String]]) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
    }

    func headerValue(_ name: String) -> String? {
        headers[name.lowercased()]?.first
    }

    func headerValues(_ name: String) -> [String] {
        headers[name.lowercased()] ?? []
    }
}

nonisolated enum HTTPResponseHeadParseResult: Equatable {
    case needsMoreData
    case complete(HTTPResponseHead, leftoverBody: Data)
}

nonisolated struct HTTPResponseHeadParser {
    private var buffer = Data()
    private let maxHeadBytes: Int

    init(maxHeadBytes: Int = 64 * 1024) {
        self.maxHeadBytes = maxHeadBytes
    }

    mutating func append(_ data: Data) throws -> HTTPResponseHeadParseResult {
        buffer.append(data)

        let delimiter = Data([13, 10, 13, 10])
        guard let delimiterRange = buffer.range(of: delimiter) else {
            guard buffer.count <= maxHeadBytes else {
                throw HTTPResponseHeadError.headTooLarge
            }

            return .needsMoreData
        }

        let headData = buffer[..<delimiterRange.lowerBound]
        let leftover = Data(buffer[delimiterRange.upperBound...])
        buffer.removeAll(keepingCapacity: false)

        guard let headText = String(data: headData, encoding: .utf8) else {
            throw HTTPResponseHeadError.malformedResponse
        }

        return .complete(try parseHead(headText), leftoverBody: leftover)
    }

    private func parseHead(_ headText: String) throws -> HTTPResponseHead {
        var lines = headText.components(separatedBy: "\r\n")
        guard lines.isEmpty == false else {
            throw HTTPResponseHeadError.malformedResponse
        }

        let statusLine = lines.removeFirst()
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard
            statusParts.count >= 2,
            statusParts[0].hasPrefix("HTTP/"),
            let statusCode = Int(statusParts[1])
        else {
            throw HTTPResponseHeadError.malformedResponse
        }

        let reasonPhrase = statusParts.count == 3 ? String(statusParts[2]) : ""
        var headers: [String: [String]] = [:]

        for line in lines where line.isEmpty == false {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPResponseHeadError.malformedResponse
            }

            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

            guard name.isEmpty == false else {
                throw HTTPResponseHeadError.malformedResponse
            }

            headers[name, default: []].append(value)
        }

        return HTTPResponseHead(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: headers
        )
    }
}
