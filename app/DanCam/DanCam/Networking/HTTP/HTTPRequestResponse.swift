import Foundation

nonisolated enum HTTPRequestResponse {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    static func get(
        url: URL,
        openByteStream: OpenByteStream
    ) async throws -> (HTTPResponseHead, Data) {
        let request = try HTTPRequestEncoder.get(
            url: url,
            extraHeaders: [("Connection", "close")]
        )
        let byteStream = try await openByteStream(url, request)
        var headParser = HTTPResponseHeadParser()
        var head: HTTPResponseHead?
        var decoder: HTTPBodyDecoder?
        var body = Data()

        for try await chunk in byteStream {
            try Task.checkCancellation()

            if decoder == nil {
                switch try headParser.append(chunk) {
                case .needsMoreData:
                    continue
                case .complete(let parsedHead, let leftoverBody):
                    head = parsedHead
                    var parsedDecoder = HTTPBodyDecoder(head: parsedHead)
                    for decodedChunk in try parsedDecoder.append(leftoverBody) {
                        body.append(decodedChunk)
                    }
                    decoder = parsedDecoder
                }
            } else {
                for decodedChunk in try decoder!.append(chunk) {
                    body.append(decodedChunk)
                }
            }

            if decoder?.isComplete == true {
                break
            }
        }

        guard let head else {
            throw HTTPResponseHeadError.malformedResponse
        }

        return (head, body)
    }
}
