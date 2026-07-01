import AVFoundation
import Darwin
import Foundation

nonisolated enum LoopbackMediaServerError: Error, Equatable, LocalizedError {
    case invalidLoopbackAddress
    case listenerFailed(String)
    case duplicateInitializationSegment
    case segmentExceedsFrozenTargetDuration(roundedDuration: Int, targetDuration: Int)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidLoopbackAddress:
            "Could not create a loopback address for the media server."
        case .listenerFailed(let message):
            "Loopback media server listener failed: \(message)"
        case .duplicateInitializationSegment:
            "Loopback media server received more than one initialization segment."
        case .segmentExceedsFrozenTargetDuration(let roundedDuration, let targetDuration):
            "Segment duration \(roundedDuration) exceeds frozen target duration \(targetDuration)."
        case .writeFailed(let message):
            "Loopback media server write failed: \(message)"
        }
    }
}

nonisolated final class LoopbackMediaServer: FMP4SegmentSink, @unchecked Sendable {
    private static let playlistPath = "/p.m3u8"
    private static let initializationPath = "/init.mp4"

    let boundAddress: String
    let workDirectory: URL
    let mediaPlaylistURL: URL

    private let queue = DispatchQueue(
        label: "com.danneu.dancam.loopback-media-server",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<Void>()
    private let listenerFileDescriptor: Int32
    private let minimumTargetDuration: Int
    private let targetDurationMargin: Int
    private let onFirstPlayableReady: @Sendable (URL) -> Void
    private var state = State()

    /// - Parameter onFirstPlayableReady: invoked **at most once**, on the server's internal
    ///   serial queue, when the init segment and first media segment are both available
    ///   (the EVENT playlist becomes first playable). It runs in the server's isolation
    ///   domain, not the caller's: the closure may capture only `Sendable`/immutable or
    ///   internally synchronized handles by value (e.g. an `AsyncStream.Continuation`).
    ///   Capturing a reference whose mutable state is confined to another serial domain still
    ///   races, even by value -- to deliver into such state, hop to its owner domain instead.
    init(
        minimumTargetDuration: Int = 2,
        targetDurationMargin: Int = 1,
        onFirstPlayableReady: @Sendable @escaping (URL) -> Void = { _ in }
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("dancam-fmp4-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let listener = try Self.makeLoopbackListener()
        let endpoint: BoundEndpoint
        let playlistURL: URL
        do {
            endpoint = try Self.boundEndpoint(for: listener)
            guard let url = URL(string: "http://localhost:\(endpoint.port)\(Self.playlistPath)") else {
                throw URLError(.badURL)
            }
            playlistURL = url
        } catch {
            Darwin.close(listener)
            try? fileManager.removeItem(at: directory)
            throw error
        }

        listenerFileDescriptor = listener
        workDirectory = directory
        boundAddress = endpoint.address
        mediaPlaylistURL = playlistURL
        self.minimumTargetDuration = minimumTargetDuration
        self.targetDurationMargin = targetDurationMargin
        self.onFirstPlayableReady = onFirstPlayableReady

        queue.setSpecific(key: queueKey, value: ())
        startAccepting()
    }

    deinit {
        shutdown()
    }

    func appendInitializationSegment(_ data: Data) {
        queue.async { [weak self] in
            self?.appendInitializationSegmentOnQueue(data)
        }
    }

    func appendMediaSegment(_ data: Data, duration: CMTime) {
        queue.async { [weak self] in
            self?.appendMediaSegmentOnQueue(data, duration: duration)
        }
    }

    func finish() {
        queue.async { [weak self] in
            self?.finishOnQueue()
        }
    }

    func shutdown() {
        performOnQueueSync {
            guard state.isShutdown == false else {
                return
            }
            state.isShutdown = true
            state.acceptSource?.cancel()
            state.acceptSource = nil
            for id in Array(state.connections.keys) {
                closeConnection(id)
            }
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    func checkForFailure() throws {
        try performOnQueueSync {
            if let failure = state.failure {
                throw failure
            }
        }
    }

    func hasFinalizedPlaylist() -> Bool {
        performOnQueueSync {
            state.finished && state.targetDuration != nil
        }
    }

    private static func makeLoopbackListener() throws -> Int32 {
        let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fileDescriptor >= 0 else {
            throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
        }

        do {
            var one: Int32 = 1
            guard Darwin.setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &one,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0).bigEndian
            // Loopback-only bind (ADR 08). A regression to "0.0.0.0" here is caught by
            // LoopbackMediaServerTests, which asserts boundAddress read back via getsockname.
            guard Darwin.inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
                throw LoopbackMediaServerError.invalidLoopbackAddress
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(
                        fileDescriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
            }

            guard Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
            }

            try setNonBlocking(fileDescriptor)
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private struct BoundEndpoint {
        var address: String
        var port: UInt16
    }

    private static func boundEndpoint(for fileDescriptor: Int32) throws -> BoundEndpoint {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(fileDescriptor, socketAddress, &length)
            }
        }
        guard result == 0 else {
            throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
        }

        var sinAddr = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard Darwin.inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
        }

        return BoundEndpoint(address: String(cString: buffer), port: UInt16(bigEndian: address.sin_port))
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0 else {
            throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
        }
        guard Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
        }
    }

    private static func configureClientSocket(_ fileDescriptor: Int32) throws {
        var one: Int32 = 1
        guard Darwin.setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &one,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
        }

        try setNonBlocking(fileDescriptor)
    }

    private static func posixErrorDescription(_ errorNumber: Int32 = errno) -> String {
        String(cString: Darwin.strerror(errorNumber))
    }

    private func startAccepting() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: listenerFileDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler { [listenerFileDescriptor] in
            Darwin.close(listenerFileDescriptor)
        }
        state.acceptSource = source
        source.resume()
    }

    private func acceptAvailableConnections() {
        while state.isShutdown == false {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFileDescriptor = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(listenerFileDescriptor, socketAddress, &length)
                }
            }

            guard clientFileDescriptor >= 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                fail(.listenerFailed(Self.posixErrorDescription()))
                return
            }

            do {
                try Self.configureClientSocket(clientFileDescriptor)
                let id = UUID()
                let connection = ClientConnection(fileDescriptor: clientFileDescriptor)
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: clientFileDescriptor,
                    queue: queue
                )
                source.setEventHandler { [weak self] in
                    self?.readAvailableData(from: id)
                }
                source.setCancelHandler(handler: sourceCancelHandler(for: connection))
                connection.readSource = source
                connection.activeSourceCount += 1
                state.connections[id] = connection
                source.resume()
            } catch {
                Darwin.close(clientFileDescriptor)
                fail(.listenerFailed(error.localizedDescription))
            }
        }
    }

    private func readAvailableData(from id: UUID) {
        guard let connection = state.connections[id] else {
            return
        }

        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = scratch.withUnsafeMutableBytes { buffer in
                Darwin.read(connection.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                connection.buffer.append(scratch, count: count)
                if let delimiterRange = connection.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let requestData = Data(connection.buffer[..<delimiterRange.upperBound])
                    let response = response(for: requestData)
                    send(response: response, to: id)
                    return
                }
                continue
            }

            if count == 0 {
                send(response: LoopbackHTTPResponseHead.notFound(), to: id)
                return
            }

            if errno == EWOULDBLOCK || errno == EAGAIN {
                return
            }

            closeConnection(id)
            return
        }
    }

    private func send(response: Data, to id: UUID) {
        guard let connection = state.connections[id] else {
            return
        }
        connection.readSource?.cancel()
        connection.pendingResponse = response
        connection.writeOffset = 0
        flushPendingWrite(for: id)
    }

    private func flushPendingWrite(for id: UUID) {
        guard let connection = state.connections[id] else {
            return
        }
        switch writeRemainingBytes(of: connection) {
        case .drained, .failed:
            closeConnection(id)
        case .wouldBlock:
            ensureWriteSource(for: id, connection: connection)
        }
    }

    private func writeRemainingBytes(of connection: ClientConnection) -> WriteOutcome {
        let response = connection.pendingResponse
        let count = response.count
        if connection.writeOffset >= count {
            return .drained   // also covers an empty response
        }
        return response.withUnsafeBytes { raw -> WriteOutcome in
            guard let base = raw.baseAddress else {
                return .drained
            }
            while connection.writeOffset < count {
                let result = Darwin.write(
                    connection.fileDescriptor,
                    base.advanced(by: connection.writeOffset),
                    count - connection.writeOffset
                )
                if result > 0 {
                    connection.writeOffset += result
                    continue
                }
                if result < 0 && (errno == EWOULDBLOCK || errno == EAGAIN) {
                    return .wouldBlock
                }
                return .failed   // result == 0, or EPIPE/ECONNRESET/EINTR/other
            }
            return .drained
        }
    }

    private func ensureWriteSource(for id: UUID, connection: ClientConnection) {
        if connection.writeSource != nil {
            return   // already armed
        }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: connection.fileDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.flushPendingWrite(for: id)
        }
        source.setCancelHandler(handler: sourceCancelHandler(for: connection))
        connection.writeSource = source
        connection.activeSourceCount += 1
        source.resume()
    }

    private func closeConnection(_ id: UUID) {
        guard let connection = state.connections.removeValue(forKey: id) else {
            return
        }
        connection.isClosing = true
        connection.readSource?.cancel()
        connection.writeSource?.cancel()
        // fd closed by the last cancellation handler (activeSourceCount -> 0), not here.
    }

    private func sourceCancelHandler(for connection: ClientConnection) -> @Sendable () -> Void {
        { [connection] in                                  // runs on the serial queue
            connection.activeSourceCount -= 1
            if connection.isClosing && connection.activeSourceCount == 0 {
                Darwin.close(connection.fileDescriptor)     // exactly once, last handler
            }
        }
    }

    private func appendInitializationSegmentOnQueue(_ data: Data) {
        guard state.isShutdown == false, state.failure == nil else {
            return
        }
        guard state.initializationURL == nil else {
            fail(.duplicateInitializationSegment)
            return
        }

        let url = workDirectory.appendingPathComponent("init.mp4")
        do {
            try data.write(to: url, options: .atomic)
            state.initializationURL = url
            state.routes[Self.initializationPath] = Route(
                contentType: "video/mp4",
                body: .file(url)
            )
        } catch {
            fail(.writeFailed(error.localizedDescription))
        }
    }

    private func appendMediaSegmentOnQueue(_ data: Data, duration: CMTime) {
        guard state.isShutdown == false, state.failure == nil else {
            return
        }

        let roundedDuration = roundedTargetDuration(for: duration)
        if let targetDuration = state.targetDuration {
            guard roundedDuration <= targetDuration else {
                fail(.segmentExceedsFrozenTargetDuration(
                    roundedDuration: roundedDuration,
                    targetDuration: targetDuration
                ))
                return
            }
        } else {
            state.targetDuration = max(
                minimumTargetDuration,
                roundedDuration + targetDurationMargin
            )
        }

        let index = state.nextSegmentIndex
        let filename = "seg\(index).m4s"
        let path = "/\(filename)"
        let url = workDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            state.routes[path] = Route(
                contentType: "video/iso.segment",
                body: .file(url)
            )
            state.mediaSegments.append(MediaSegment(
                uri: filename,
                duration: duration
            ))
            state.nextSegmentIndex += 1
            publishPlaylistRoute()
            signalFirstPlayableIfReady()
        } catch {
            fail(.writeFailed(error.localizedDescription))
        }
    }

    private func finishOnQueue() {
        guard state.isShutdown == false, state.failure == nil else {
            return
        }
        guard state.finished == false else {
            return
        }
        state.finished = true
        publishPlaylistRoute()
    }

    private func publishPlaylistRoute() {
        guard state.targetDuration != nil else {
            return
        }
        state.routes[Self.playlistPath] = Route(
            contentType: "application/vnd.apple.mpegurl",
            body: .data(Data(playlistString().utf8))
        )
    }

    private func signalFirstPlayableIfReady() {
        guard state.didSignalFirstPlayable == false,
              state.initializationURL != nil,
              state.mediaSegments.isEmpty == false else {
            return
        }
        state.didSignalFirstPlayable = true
        onFirstPlayableReady(mediaPlaylistURL)
    }

    private func playlistString() -> String {
        let targetDuration = state.targetDuration ?? minimumTargetDuration
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]

        for segment in state.mediaSegments {
            lines.append("#EXTINF:\(extinfDuration(segment.duration)),")
            lines.append(segment.uri)
        }

        if state.finished {
            lines.append("#EXT-X-ENDLIST")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func response(for requestData: Data) -> Data {
        guard
            let request = String(data: requestData, encoding: .utf8),
            let line = HTTPRequestParser.requestLine(from: request)
        else {
            return LoopbackHTTPResponseHead.notFound()
        }

        let method = line.method.uppercased()
        let sendsBody = method == "GET"
        guard method == "GET" || method == "HEAD" else {
            return LoopbackHTTPResponseHead.notFound()
        }

        guard let route = state.routes[line.path] else {
            return LoopbackHTTPResponseHead.notFound()
        }

        guard let body = route.body.load() else {
            return LoopbackHTTPResponseHead.notFound()
        }

        let totalSize = UInt64(body.count)
        let rangeHeader = HTTPRequestParser.headerValue("range", in: request)
        switch HTTPByteRangeResolver.resolve(rangeHeader, totalSize: totalSize) {
        case .full:
            var response = LoopbackHTTPResponseHead.ok(
                contentLength: totalSize,
                contentType: route.contentType
            )
            if sendsBody {
                response.append(body)
            }
            return response
        case .partial(let range):
            var response = LoopbackHTTPResponseHead.partialContent(
                range: range,
                totalSize: totalSize,
                contentType: route.contentType
            )
            if sendsBody {
                response.append(body.subdata(in: range.dataRange))
            }
            return response
        case .unsatisfiable:
            return LoopbackHTTPResponseHead.rangeNotSatisfiable(totalSize: totalSize)
        }
    }

    private func fail(_ error: LoopbackMediaServerError) {
        if state.failure == nil {
            state.failure = error
        }
    }

    private func performOnQueueSync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    private func roundedTargetDuration(for duration: CMTime) -> Int {
        Int(ceil(max(duration.seconds, 0)))
    }

    private func extinfDuration(_ duration: CMTime) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), duration.seconds)
    }

    private struct State {
        var initializationURL: URL?
        var mediaSegments: [MediaSegment] = []
        var routes: [String: Route] = [:]
        var connections: [UUID: ClientConnection] = [:]
        var acceptSource: DispatchSourceRead?
        var nextSegmentIndex = 0
        var targetDuration: Int?
        var didSignalFirstPlayable = false
        var finished = false
        var isShutdown = false
        var failure: LoopbackMediaServerError?
    }

    private enum WriteOutcome {
        case drained
        case wouldBlock
        case failed
    }

    private struct MediaSegment {
        var uri: String
        var duration: CMTime
    }

    private struct Route {
        var contentType: String
        var body: RouteBody
    }

    private enum RouteBody {
        case data(Data)
        case file(URL)

        func load() -> Data? {
            switch self {
            case .data(let data):
                data
            case .file(let url):
                try? Data(contentsOf: url)
            }
        }
    }
}

nonisolated private final class ClientConnection: @unchecked Sendable {
    let fileDescriptor: Int32
    var buffer = Data()
    var readSource: DispatchSourceRead?
    var pendingResponse = Data()        // set once in send(); stable afterward
    var writeOffset = 0                  // advances as bytes drain
    var writeSource: DispatchSourceWrite?
    var activeSourceCount = 0           // created+resumed sources not yet cancel-delivered
    var isClosing = false               // set by closeConnection; gates the fd close

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }
}

nonisolated private struct HTTPRequestLine: Equatable, Sendable {
    var method: String
    var path: String
}

nonisolated private enum HTTPRequestParser {
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
            guard line.isEmpty == false else {
                break
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }

            let headerName = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard headerName == wantedName else {
                continue
            }

            return line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

nonisolated private struct HTTPByteRange: Equatable, Sendable {
    var start: UInt64
    var end: UInt64

    var length: UInt64 {
        end >= start ? end - start + 1 : 0
    }

    var dataRange: Range<Data.Index> {
        Int(start)..<Int(end + 1)
    }
}

nonisolated private enum HTTPRangeResolution: Equatable, Sendable {
    case full
    case partial(HTTPByteRange)
    case unsatisfiable
}

nonisolated private enum HTTPByteRangeResolver {
    static func resolve(
        _ rawRange: String?,
        totalSize: UInt64
    ) -> HTTPRangeResolution {
        guard let rawRange else {
            return .full
        }
        guard totalSize > 0 else {
            return .unsatisfiable
        }
        guard rawRange.hasPrefix("bytes="), rawRange.contains(",") == false else {
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
}

nonisolated private enum LoopbackHTTPResponseHead {
    static func ok(contentLength: UInt64, contentType: String) -> Data {
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

    static func partialContent(
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

    static func rangeNotSatisfiable(totalSize: UInt64) -> Data {
        head(
            statusCode: 416,
            reasonPhrase: "Range Not Satisfiable",
            headers: [
                ("Content-Length", "0"),
                ("Content-Range", "bytes */\(totalSize)"),
                ("Accept-Ranges", "bytes"),
                ("Connection", "close"),
            ]
        )
    }

    static func notFound() -> Data {
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
