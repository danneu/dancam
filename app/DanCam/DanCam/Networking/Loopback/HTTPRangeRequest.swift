import Foundation

nonisolated struct HTTPRequestLine: Equatable, Sendable {
    var method: String
    var path: String
}

nonisolated struct HTTPByteRange: Equatable, Sendable {
    var start: UInt64
    var end: UInt64

    var length: UInt64 {
        end >= start ? end - start + 1 : 0
    }
}

nonisolated enum HTTPRangeResolution: Equatable, Sendable {
    case full
    case partial(HTTPByteRange)
    case unsatisfiable
}

nonisolated enum HTTPRangeRequest {
    static func requestLine(from request: String) -> HTTPRequestLine? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            return nil
        }

        return HTTPRequestLine(method: String(parts[0]), path: String(parts[1]))
    }

    static func headerValue(_ name: String, in request: String) -> String? {
        let wantedName = name.lowercased()
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard line.isEmpty == false else { break }
            guard let separator = line.firstIndex(of: ":") else { continue }

            let headerName = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard headerName == wantedName else { continue }

            return line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    static func resolveRange(
        _ rawRange: String?,
        totalSize: UInt64
    ) -> HTTPRangeResolution {
        guard let rawRange else {
            return .full
        }
        guard totalSize > 0 else {
            return .unsatisfiable
        }
        guard
            rawRange.hasPrefix("bytes="),
            rawRange.contains(",") == false
        else {
            return .unsatisfiable
        }

        let spec = rawRange.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else {
            return .unsatisfiable
        }

        let rawStart = spec[..<dash]
        let rawEnd = spec[spec.index(after: dash)...]

        if rawStart.isEmpty {
            guard let suffixLength = UInt64(rawEnd), suffixLength > 0 else {
                return .unsatisfiable
            }

            let start = suffixLength >= totalSize ? 0 : totalSize - suffixLength
            return .partial(HTTPByteRange(start: start, end: totalSize - 1))
        }

        guard let start = UInt64(rawStart), start < totalSize else {
            return .unsatisfiable
        }

        if rawEnd.isEmpty {
            return .partial(HTTPByteRange(start: start, end: totalSize - 1))
        }

        guard let requestedEnd = UInt64(rawEnd), requestedEnd >= start else {
            return .unsatisfiable
        }

        return .partial(HTTPByteRange(start: start, end: min(requestedEnd, totalSize - 1)))
    }

    static func okHead(
        contentLength: UInt64,
        contentType: String
    ) -> Data {
        head(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                ("Content-Type", contentType),
                ("Content-Length", "\(contentLength)"),
                ("Accept-Ranges", "bytes"),
                ("Connection", "close"),
            ]
        )
    }

    static func partialContentHead(
        range: HTTPByteRange,
        totalSize: UInt64,
        contentType: String
    ) -> Data {
        head(
            statusCode: 206,
            reasonPhrase: "Partial Content",
            headers: [
                ("Content-Type", contentType),
                ("Content-Length", "\(range.length)"),
                ("Content-Range", "bytes \(range.start)-\(range.end)/\(totalSize)"),
                ("Accept-Ranges", "bytes"),
                ("Connection", "close"),
            ]
        )
    }

    static func rangeNotSatisfiableHead(totalSize: UInt64) -> Data {
        head(
            statusCode: 416,
            reasonPhrase: "Range Not Satisfiable",
            headers: [
                ("Content-Length", "0"),
                ("Content-Range", "bytes */\(totalSize)"),
                ("Connection", "close"),
            ]
        )
    }

    static func notFoundHead() -> Data {
        head(
            statusCode: 404,
            reasonPhrase: "Not Found",
            headers: [
                ("Content-Length", "0"),
                ("Connection", "close"),
            ]
        )
    }

    private static func head(
        statusCode: Int,
        reasonPhrase: String,
        headers: [(String, String)]
    ) -> Data {
        var lines = ["HTTP/1.1 \(statusCode) \(reasonPhrase)"]
        lines.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
        lines.append("")
        lines.append("")

        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
