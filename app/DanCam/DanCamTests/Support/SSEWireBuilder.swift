import Foundation

enum SSEWireBuilder {
    static func response(
        statusCode: Int = 200,
        headers: [(String, String)] = [("Content-Type", "text/event-stream")],
        body: Data
    ) -> Data {
        MJPEGWireBuilder.response(
            statusCode: statusCode,
            headers: headers,
            body: body
        )
    }

    static func event(id: Int? = nil, data: Data) -> Data {
        var output = Data()
        if let id {
            output.append(Data("id: \(id)\n".utf8))
        }
        output.append(Data("data: ".utf8))
        output.append(data)
        output.append(Data("\n\n".utf8))
        return output
    }
}
