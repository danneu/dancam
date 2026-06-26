import Foundation
import Network

actor LoopbackHLSServer {
    private let segmentURL: URL
    private let durationSeconds: Double
    private let queue = DispatchQueue(label: "com.danneu.dancam.loopback")

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var baseURL: URL?

    init(segmentURL: URL, durationSeconds: Double) {
        self.segmentURL = segmentURL
        self.durationSeconds = durationSeconds
    }

    func start() async throws -> URL {
        if let baseURL {
            return baseURL
        }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }

        self.listener = listener

        let resolvedBaseURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        guard
                            let port = listener.port?.rawValue,
                            let url = URL(string: "http://127.0.0.1:\(port)/")
                        else {
                            continuation.resume(throwing: URLError(.badServerResponse))
                            return
                        }

                        continuation.resume(returning: url)
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }

                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }

        baseURL = resolvedBaseURL
        return resolvedBaseURL
    }

    func stop() {
        listener?.cancel()
        listener = nil
        baseURL = nil

        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task {
                    await self?.removeConnection(id)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, buffer: Data())
    }

    private func receive(on connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceive(
                    on: connection,
                    id: id,
                    buffer: buffer,
                    data: data,
                    isComplete: isComplete,
                    error: error
                )
            }
        }
    }

    private func handleReceive(
        on connection: NWConnection,
        id: UUID,
        buffer: Data,
        data: Data?,
        isComplete: Bool,
        error: NWError?
    ) {
        guard error == nil else {
            connection.cancel()
            connections[id] = nil
            return
        }

        var nextBuffer = buffer
        if let data {
            nextBuffer.append(data)
        }

        let delimiter = Data("\r\n\r\n".utf8)
        if let delimiterRange = nextBuffer.range(of: delimiter) {
            let requestData = Data(nextBuffer[..<delimiterRange.upperBound])
            send(response: response(for: requestData), on: connection, id: id)
            return
        }

        if isComplete {
            send(response: HTTPRangeRequest.notFoundHead(), on: connection, id: id)
            return
        }

        receive(on: connection, id: id, buffer: nextBuffer)
    }

    private func response(for requestData: Data) -> Data {
        guard
            let request = String(data: requestData, encoding: .utf8),
            let line = HTTPRangeRequest.requestLine(from: request)
        else {
            return HTTPRangeRequest.notFoundHead()
        }

        let method = line.method.uppercased()
        let sendsBody = method == "GET"
        guard method == "GET" || method == "HEAD" else {
            return HTTPRangeRequest.notFoundHead()
        }

        switch line.path {
        case "/index.m3u8":
            return playlistResponse(sendsBody: sendsBody)
        case "/segment.ts":
            return segmentResponse(request: request, sendsBody: sendsBody)
        default:
            return HTTPRangeRequest.notFoundHead()
        }
    }

    private func playlistResponse(sendsBody: Bool) -> Data {
        let playlist = HLSPlaylist.singleSegmentVOD(
            segmentURI: "segment.ts",
            durationSeconds: durationSeconds
        )
        let body = Data(playlist.utf8)
        var response = HTTPRangeRequest.okHead(
            contentLength: UInt64(body.count),
            contentType: "application/vnd.apple.mpegurl"
        )
        if sendsBody {
            response.append(body)
        }
        return response
    }

    private func segmentResponse(request: String, sendsBody: Bool) -> Data {
        guard let totalSize = segmentSize() else {
            return HTTPRangeRequest.notFoundHead()
        }

        let rangeHeader = HTTPRangeRequest.headerValue("range", in: request)
        switch HTTPRangeRequest.resolveRange(rangeHeader, totalSize: totalSize) {
        case .full:
            var response = HTTPRangeRequest.okHead(
                contentLength: totalSize,
                contentType: "video/mp2t"
            )
            if sendsBody, let body = readSegment(start: 0, length: totalSize) {
                response.append(body)
            }
            return response
        case .partial(let range):
            var response = HTTPRangeRequest.partialContentHead(
                range: range,
                totalSize: totalSize,
                contentType: "video/mp2t"
            )
            if sendsBody, let body = readSegment(start: range.start, length: range.length) {
                response.append(body)
            }
            return response
        case .unsatisfiable:
            return HTTPRangeRequest.rangeNotSatisfiableHead(totalSize: totalSize)
        }
    }

    private func segmentSize() -> UInt64? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: segmentURL.path),
            let size = attributes[.size] as? NSNumber
        else {
            return nil
        }

        return size.uint64Value
    }

    private func readSegment(start: UInt64, length: UInt64) -> Data? {
        guard length <= UInt64(Int.max) else {
            return nil
        }

        do {
            let fileHandle = try FileHandle(forReadingFrom: segmentURL)
            defer {
                fileHandle.closeFile()
            }
            try fileHandle.seek(toOffset: start)
            return try fileHandle.read(upToCount: Int(length)) ?? Data()
        } catch {
            return nil
        }
    }

    private func send(response: Data, on connection: NWConnection, id: UUID) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task {
                await self?.removeConnection(id)
            }
        })
    }

    private func removeConnection(_ id: UUID) {
        connections[id] = nil
    }
}
