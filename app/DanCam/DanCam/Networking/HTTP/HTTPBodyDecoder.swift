import Foundation

nonisolated enum HTTPBodyDecodingError: Error, Equatable {
    case malformedChunkedBody
}

nonisolated struct HTTPBodyDecoder {
    private enum Mode {
        case chunked
        case contentLength(Int)
        case closeDelimited
    }

    private let mode: Mode
    private var buffer = Data()
    private var remainingContentLength: Int?
    private var pendingChunkSize: Int?
    private var awaitingTrailers = false
    private(set) var isComplete = false

    init(head: HTTPResponseHead) {
        if head
            .headerValues("transfer-encoding")
            .contains(where: { $0.lowercased().contains("chunked") }) {
            mode = .chunked
        } else if
            let contentLengthValue = head.headerValue("content-length"),
            let contentLength = Int(contentLengthValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            mode = .contentLength(contentLength)
            remainingContentLength = contentLength
            isComplete = contentLength == 0
        } else {
            mode = .closeDelimited
        }
    }

    mutating func append(_ data: Data) throws -> [Data] {
        guard isComplete == false else {
            return []
        }

        switch mode {
        case .chunked:
            buffer.append(data)
            return try decodeChunked()
        case .contentLength:
            return decodeContentLength(data)
        case .closeDelimited:
            return data.isEmpty ? [] : [data]
        }
    }

    private mutating func decodeContentLength(_ data: Data) -> [Data] {
        guard let remainingContentLength, remainingContentLength > 0 else {
            isComplete = true
            return []
        }

        let byteCount = min(remainingContentLength, data.count)
        guard byteCount > 0 else {
            return []
        }

        let output = Data(data.prefix(byteCount))
        self.remainingContentLength = remainingContentLength - byteCount
        isComplete = self.remainingContentLength == 0
        return [output]
    }

    private mutating func decodeChunked() throws -> [Data] {
        var outputs: [Data] = []

        while isComplete == false {
            if awaitingTrailers {
                guard consumeTrailersIfComplete() else {
                    return outputs
                }
                continue
            }

            if let pendingChunkSize {
                guard buffer.count >= pendingChunkSize + 2 else {
                    return outputs
                }

                let dataEnd = buffer.index(buffer.startIndex, offsetBy: pendingChunkSize)
                let lineFeedIndex = buffer.index(after: dataEnd)
                guard buffer[dataEnd] == 13, buffer[lineFeedIndex] == 10 else {
                    throw HTTPBodyDecodingError.malformedChunkedBody
                }

                if pendingChunkSize > 0 {
                    outputs.append(Data(buffer.prefix(pendingChunkSize)))
                }

                let removeEnd = buffer.index(buffer.startIndex, offsetBy: pendingChunkSize + 2)
                buffer.removeSubrange(buffer.startIndex..<removeEnd)
                self.pendingChunkSize = nil
                continue
            }

            guard let lineRange = buffer.range(of: Data([13, 10])) else {
                return outputs
            }

            let sizeLineData = buffer[..<lineRange.lowerBound]
            guard
                let sizeLine = String(data: sizeLineData, encoding: .ascii),
                let size = parseChunkSize(sizeLine)
            else {
                throw HTTPBodyDecodingError.malformedChunkedBody
            }

            buffer.removeSubrange(..<lineRange.upperBound)

            if size == 0 {
                awaitingTrailers = true
            } else {
                pendingChunkSize = size
            }
        }

        return outputs
    }

    private func parseChunkSize(_ line: String) -> Int? {
        let rawSize = line
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rawSize, rawSize.isEmpty == false else {
            return nil
        }

        return Int(rawSize, radix: 16)
    }

    private mutating func consumeTrailersIfComplete() -> Bool {
        if buffer.starts(with: Data([13, 10])) {
            buffer.removeFirst(2)
            isComplete = true
            awaitingTrailers = false
            return true
        }

        let delimiter = Data([13, 10, 13, 10])
        guard let delimiterRange = buffer.range(of: delimiter) else {
            return false
        }

        buffer.removeSubrange(..<delimiterRange.upperBound)
        isComplete = true
        awaitingTrailers = false
        return true
    }
}
