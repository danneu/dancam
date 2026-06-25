import Foundation

nonisolated struct MultipartMJPEGParser {
    private enum State {
        case seekingBoundary
        case readingHeaders
        case readingBody(contentLength: Int?)
    }

    private struct PartHeaders {
        var contentLength: Int?
    }

    private let boundary: Data
    private let maxPartBytes: Int
    private var state = State.seekingBoundary
    private var buffer = Data()

    init(boundary: String, maxPartBytes: Int = 2 * 1024 * 1024) {
        self.boundary = Data("--\(boundary)".utf8)
        self.maxPartBytes = maxPartBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while true {
            switch state {
            case .seekingBoundary:
                guard try seekBoundary() else {
                    return frames
                }
                state = .readingHeaders

            case .readingHeaders:
                guard let headers = try parseHeadersIfComplete() else {
                    return frames
                }
                state = .readingBody(contentLength: headers.contentLength)

            case .readingBody(let contentLength):
                guard let frame = try parseBodyIfComplete(contentLength: contentLength) else {
                    return frames
                }
                frames.append(frame)
                state = .seekingBoundary
            }
        }
    }

    private mutating func seekBoundary() throws -> Bool {
        guard let range = buffer.range(of: boundary) else {
            let keepBytes = boundary.count + 4
            if buffer.count > keepBytes {
                buffer.removeFirst(buffer.count - keepBytes)
            }
            return false
        }

        buffer.removeSubrange(..<range.upperBound)

        if buffer.count < 2 {
            return false
        }

        if buffer.starts(with: Data([45, 45])) {
            buffer.removeFirst(2)
            return false
        }

        guard buffer.starts(with: Data([13, 10])) else {
            throw PreviewError.malformedResponse("Malformed multipart boundary.")
        }

        buffer.removeFirst(2)
        return true
    }

    private mutating func parseHeadersIfComplete() throws -> PartHeaders? {
        let delimiter = Data([13, 10, 13, 10])
        guard let delimiterRange = buffer.range(of: delimiter) else {
            guard buffer.count <= 16 * 1024 else {
                throw PreviewError.malformedResponse("Multipart part headers are too large.")
            }
            return nil
        }

        let headerData = buffer[..<delimiterRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw PreviewError.malformedResponse("Multipart part headers are not UTF-8.")
        }

        buffer.removeSubrange(..<delimiterRange.upperBound)

        var contentLength: Int?
        for line in headerText.components(separatedBy: "\r\n") where line.isEmpty == false {
            guard let separator = line.firstIndex(of: ":") else {
                throw PreviewError.malformedResponse("Malformed multipart part header.")
            }

            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if name == "content-length" {
                guard let parsed = Int(value), parsed >= 0 else {
                    throw PreviewError.malformedResponse("Invalid multipart Content-Length.")
                }
                guard parsed <= maxPartBytes else {
                    throw PreviewError.malformedResponse("Multipart part is too large.")
                }
                contentLength = parsed
            }
        }

        return PartHeaders(contentLength: contentLength)
    }

    private mutating func parseBodyIfComplete(contentLength: Int?) throws -> Data? {
        if let contentLength {
            guard buffer.count >= contentLength else {
                return nil
            }

            let frame = Data(buffer.prefix(contentLength))
            buffer.removeFirst(contentLength)
            return frame
        }

        let delimiter = Data("\r\n".utf8) + boundary
        guard let delimiterRange = buffer.range(of: delimiter) else {
            guard buffer.count <= maxPartBytes else {
                throw PreviewError.malformedResponse("Multipart part is too large.")
            }
            return nil
        }

        let frame = Data(buffer[..<delimiterRange.lowerBound])
        buffer.removeSubrange(..<(delimiterRange.lowerBound + 2))
        return frame
    }
}
