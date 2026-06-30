import Foundation

nonisolated struct SSEEventParser {
    private var buffer = Data()
    private var dataLines: [Data] = []

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var events: [Data] = []

        while let line = popLine() {
            if line.isEmpty {
                if dataLines.isEmpty == false {
                    events.append(joinedDataLines())
                    dataLines.removeAll(keepingCapacity: true)
                }
                continue
            }

            guard line.first != UInt8(ascii: ":") else {
                continue
            }

            let field: Data
            let value: Data

            if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
                field = Data(line[..<colon])
                let valueStart = line.index(after: colon)
                if valueStart < line.endIndex, line[valueStart] == UInt8(ascii: " ") {
                    value = Data(line[line.index(after: valueStart)...])
                } else {
                    value = Data(line[valueStart...])
                }
            } else {
                field = line
                value = Data()
            }

            if String(data: field, encoding: .utf8) == "data" {
                dataLines.append(value)
            }
        }

        return events
    }

    private mutating func popLine() -> Data? {
        guard let terminator = buffer.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) else {
            return nil
        }

        let line = Data(buffer[..<terminator])
        var removeEnd = buffer.index(after: terminator)

        if buffer[terminator] == UInt8(ascii: "\r"),
           removeEnd < buffer.endIndex,
           buffer[removeEnd] == UInt8(ascii: "\n") {
            removeEnd = buffer.index(after: removeEnd)
        }

        buffer.removeSubrange(..<removeEnd)
        return line
    }

    private func joinedDataLines() -> Data {
        var output = Data()

        for (index, line) in dataLines.enumerated() {
            if index > 0 {
                output.append(UInt8(ascii: "\n"))
            }
            output.append(line)
        }

        return output
    }
}
