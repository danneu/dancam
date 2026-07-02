import Foundation

nonisolated enum ClipPrefixError: Error, Equatable {
    case http(Int)
    case malformedResponse(String)
    case validatorMismatch
    case transport(String)
}

/// Fetches a bounded byte prefix of a finished clip (`GET /v1/clips/{id}` with a
/// `Range: bytes=0-<limit-1>`) so the phone can decode a first-frame thumbnail
/// without pulling the whole ~38 MB segment. `ClipPullClient` cannot be reused: its
/// resume path hard-asserts tail-to-EOF and whole-file completion, whereas a thumbnail
/// wants exactly the first GOP and nothing more.
///
/// The bytes must be *proven* to belong to the `(id, etag)` the caller keyed its cache
/// on before they are decoded or cached, so `fetchPrefix` validates the response `ETag`
/// octet-equals `httpEntityTag(expectedETag)` (and, for a `206`, that the range starts
/// at byte 0). A plain ranged `GET` is sent -- never an `If-Range`, whose mismatch would
/// return a full `200` and defeat the point.
nonisolated struct ClipPrefixClient: Sendable {
    typealias OpenByteStream = @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error>

    var fetchPrefix: @Sendable (_ clipID: Int, _ expectedETag: String, _ byteLimit: Int) async throws -> Data

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration
    ) -> ClipPrefixClient {
        live(baseURL: baseURL, pinning: pinning) { url, request in
            try await NWByteStream.open(
                url: url,
                request: request,
                pinning: pinning,
                connectTimeout: connectTimeout,
                receiveIdleTimeout: receiveIdleTimeout
            )
        }
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning = .disabled,
        openByteStream: @escaping OpenByteStream
    ) -> ClipPrefixClient {
        ClipPrefixClient { clipID, expectedETag, byteLimit in
            let clipURL = baseURL.appending(path: "v1/clips/\(clipID)")
            let request = try HTTPRequestEncoder.get(
                url: clipURL,
                extraHeaders: [
                    ("Range", "bytes=0-\(byteLimit - 1)"),
                    ("Connection", "close"),
                ]
            )
            return try await fetch(
                url: clipURL,
                request: request,
                expectedETag: expectedETag,
                byteLimit: byteLimit,
                openByteStream: openByteStream
            )
        }
    }

    static let noop = ClipPrefixClient { _, _, _ in Data() }

    private static func fetch(
        url: URL,
        request: Data,
        expectedETag: String,
        byteLimit: Int,
        openByteStream: OpenByteStream
    ) async throws -> Data {
        let expectedTag = httpEntityTag(expectedETag)

        let byteStream: AsyncThrowingStream<Data, Error>
        do {
            byteStream = try await openByteStream(url, request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw ClipPrefixError.transport(error.localizedDescription)
        }

        var headParser = HTTPResponseHeadParser()
        var decoder: HTTPBodyDecoder?
        var body = Data()

        do {
            for try await chunk in byteStream {
                try Task.checkCancellation()

                if decoder == nil {
                    switch try headParser.append(chunk) {
                    case .needsMoreData:
                        continue
                    case .complete(let head, let leftoverBody):
                        try validate(head: head, expectedTag: expectedTag)
                        var parsedDecoder = HTTPBodyDecoder(head: head)
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

                // One GOP is all we need: stop as soon as the prefix is filled (then
                // the dropped stream's `onTermination` closes the connection) or the
                // whole -- smaller-than-limit -- clip has arrived.
                if body.count >= byteLimit || decoder?.isComplete == true {
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClipPrefixError {
            throw error
        } catch let error as HTTPResponseHeadError {
            throw ClipPrefixError.malformedResponse(String(describing: error))
        } catch let error as HTTPBodyDecodingError {
            throw ClipPrefixError.malformedResponse(String(describing: error))
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw ClipPrefixError.transport(error.localizedDescription)
        }

        guard decoder != nil else {
            throw ClipPrefixError.malformedResponse("Response ended before headers completed.")
        }

        return Data(body.prefix(byteLimit))
    }

    /// Reject anything but a `200`/`206` carrying the exact validator the caller keyed
    /// on. `httpEntityTag` quotes the *raw* expected etag, so it must be applied only to
    /// that side and compared against the already-quoted wire `ETag`. A `206` must also
    /// start at byte 0.
    private static func validate(head: HTTPResponseHead, expectedTag: String) throws {
        guard head.statusCode == 200 || head.statusCode == 206 else {
            throw ClipPrefixError.http(head.statusCode)
        }

        guard
            let etag = head.headerValue("etag")?.trimmingCharacters(in: .whitespacesAndNewlines),
            etag == expectedTag
        else {
            throw ClipPrefixError.validatorMismatch
        }

        if head.statusCode == 206 {
            guard
                let contentRange = head.headerValue("content-range"),
                let parsed = HTTPContentRange.parse(contentRange),
                parsed.start == 0
            else {
                throw ClipPrefixError.malformedResponse("206 Content-Range did not start at byte 0.")
            }
        }
    }
}
