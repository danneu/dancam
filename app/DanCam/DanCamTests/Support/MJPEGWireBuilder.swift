import Foundation

enum MJPEGWireBuilder {
    static let boundary = "dancamframe"
    static let contentType = "multipart/x-mixed-replace; boundary=dancamframe"

    static func response(
        statusCode: Int = 200,
        headers: [(String, String)] = [("Content-Type", contentType)],
        body: Data
    ) -> Data {
        var head = "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n"
        for header in headers {
            head += "\(header.0): \(header.1)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func part(_ frame: Data, includeContentLength: Bool = true) -> Data {
        var data = Data("--\(boundary)\r\n".utf8)
        data.append(Data("Content-Type: image/jpeg\r\n".utf8))
        if includeContentLength {
            data.append(Data("Content-Length: \(frame.count)\r\n".utf8))
        }
        data.append(Data("\r\n".utf8))
        data.append(frame)
        data.append(Data("\r\n".utf8))
        return data
    }

    static func chunked(_ body: Data, chunkSizes: [Int]) -> Data {
        var output = Data()
        var offset = 0
        var index = 0

        while offset < body.count {
            let requestedSize = chunkSizes[index % chunkSizes.count]
            let size = min(requestedSize, body.count - offset)
            output.append(Data(String(size, radix: 16).utf8))
            output.append(Data("\r\n".utf8))
            output.append(body[offset..<offset + size])
            output.append(Data("\r\n".utf8))
            offset += size
            index += 1
        }

        output.append(Data("0\r\nX-Trailer: ignored\r\n\r\n".utf8))
        return output
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            "OK"
        case 503:
            "Service Unavailable"
        default:
            "Status"
        }
    }
}
