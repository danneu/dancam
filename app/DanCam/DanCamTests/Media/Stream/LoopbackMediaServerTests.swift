import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing
@testable import DanCam

struct LoopbackMediaServerTests {
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func servesGrowingEventPlaylistWithFrozenTargetDuration() async throws {
        let readyURLs = ReadyURLRecorder()
        let server = try LoopbackMediaServer(
            minimumTargetDuration: 2,
            targetDurationMargin: 1,
            onFirstPlayableReady: { url in
                readyURLs.record(url)
            }
        )
        defer {
            server.shutdown()
        }

        server.appendInitializationSegment(Data([0x01, 0x02, 0x03]))
        server.appendMediaSegment(Data([0x10, 0x11]), duration: CMTime(value: 125, timescale: 100))
        try server.checkForFailure()

        let firstPlaylist = try await request(server.mediaPlaylistURL)
        #expect(firstPlaylist.statusCode == 200)
        #expect(firstPlaylist.header("Content-Type") == "application/vnd.apple.mpegurl")
        let firstBody = String(decoding: firstPlaylist.body, as: UTF8.self)
        #expect(firstBody.contains("#EXT-X-VERSION:7"))
        #expect(firstBody.contains("#EXT-X-TARGETDURATION:3"))
        #expect(firstBody.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        #expect(firstBody.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(firstBody.contains("#EXTINF:1.250000,\nseg0.m4s"))
        #expect(firstBody.contains("#EXT-X-ENDLIST") == false)
        #expect(readyURLs.snapshot() == [server.mediaPlaylistURL])

        let targetDurationLine = try #require(line(containing: "#EXT-X-TARGETDURATION:", in: firstBody))

        server.appendMediaSegment(Data([0x12, 0x13]), duration: CMTime(value: 150, timescale: 100))
        try server.checkForFailure()

        let secondBody = String(decoding: try await request(server.mediaPlaylistURL).body, as: UTF8.self)
        #expect(line(containing: "#EXT-X-TARGETDURATION:", in: secondBody) == targetDurationLine)
        #expect(secondBody.contains("#EXTINF:1.500000,\nseg1.m4s"))
        #expect(secondBody.contains("#EXT-X-ENDLIST") == false)
        #expect(readyURLs.snapshot() == [server.mediaPlaylistURL])

        server.finish()
        try server.checkForFailure()

        let finishedBody = String(decoding: try await request(server.mediaPlaylistURL).body, as: UTF8.self)
        #expect(line(containing: "#EXT-X-TARGETDURATION:", in: finishedBody) == targetDurationLine)
        #expect(finishedBody.contains("#EXT-X-ENDLIST"))
    }

    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func surfacesSegmentThatExceedsFrozenTargetDuration() async throws {
        let server = try LoopbackMediaServer(minimumTargetDuration: 1, targetDurationMargin: 0)
        defer {
            server.shutdown()
        }

        server.appendInitializationSegment(Data([0x01]))
        server.appendMediaSegment(Data([0x02]), duration: CMTime(value: 11, timescale: 10))
        try server.checkForFailure()

        server.appendMediaSegment(Data([0x03]), duration: CMTime(value: 21, timescale: 10))

        #expect(throws: LoopbackMediaServerError.segmentExceedsFrozenTargetDuration(
            roundedDuration: 3,
            targetDuration: 2
        )) {
            try server.checkForFailure()
        }

        let playlist = String(decoding: try await request(server.mediaPlaylistURL).body, as: UTF8.self)
        #expect(playlist.contains("seg0.m4s"))
        #expect(playlist.contains("seg1.m4s") == false)
    }

    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func reportsFinalizedPlaylistOnlyAfterMediaAndFinish() throws {
        do {
            let server = try LoopbackMediaServer()
            defer {
                server.shutdown()
            }

            #expect(server.hasFinalizedPlaylist() == false)
        }

        do {
            let server = try LoopbackMediaServer()
            defer {
                server.shutdown()
            }

            server.appendInitializationSegment(Data([0x01]))
            server.finish()
            #expect(server.hasFinalizedPlaylist() == false)
        }

        do {
            let server = try LoopbackMediaServer()
            defer {
                server.shutdown()
            }

            server.appendInitializationSegment(Data([0x01]))
            server.appendMediaSegment(Data([0x02]), duration: CMTime(value: 1, timescale: 1))
            #expect(server.hasFinalizedPlaylist() == false)
        }

        do {
            let server = try LoopbackMediaServer()
            defer {
                server.shutdown()
            }

            server.appendInitializationSegment(Data([0x01]))
            server.appendMediaSegment(Data([0x02]), duration: CMTime(value: 1, timescale: 1))
            server.finish()
            #expect(server.hasFinalizedPlaylist())
        }
    }

    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func servesInitAndMediaRoutesWithHeadAndRanges() async throws {
        let server = try LoopbackMediaServer()
        defer {
            server.shutdown()
        }

        let initData = Data([0x00, 0x01, 0x02, 0x03])
        let segmentData = Data([0x10, 0x11, 0x12, 0x13, 0x14])
        server.appendInitializationSegment(initData)
        server.appendMediaSegment(segmentData, duration: CMTime(value: 1, timescale: 1))
        try server.checkForFailure()

        let initResponse = try await request(try routeURL("/init.mp4", server: server))
        #expect(initResponse.statusCode == 200)
        #expect(initResponse.header("Content-Type") == "video/mp4")
        #expect(initResponse.header("Accept-Ranges") == "bytes")
        #expect(initResponse.body == initData)

        let initRange = try await request(
            try routeURL("/init.mp4", server: server),
            headers: ["Range": "bytes=1-2"]
        )
        #expect(initRange.statusCode == 206)
        #expect(initRange.header("Content-Range") == "bytes 1-2/4")
        #expect(initRange.body == Data([0x01, 0x02]))

        let segmentHead = try await request(
            try routeURL("/seg0.m4s", server: server),
            method: "HEAD"
        )
        #expect(segmentHead.statusCode == 200)
        #expect(segmentHead.header("Content-Type") == "video/iso.segment")
        #expect(segmentHead.header("Content-Length") == "\(segmentData.count)")
        #expect(segmentHead.header("Accept-Ranges") == "bytes")
        #expect(segmentHead.body.isEmpty)

        let unsatisfiable = try await request(
            try routeURL("/seg0.m4s", server: server),
            headers: ["Range": "bytes=99-100"]
        )
        #expect(unsatisfiable.statusCode == 416)
        #expect(unsatisfiable.header("Content-Range") == "bytes */\(segmentData.count)")
        #expect(unsatisfiable.body.isEmpty)
    }

    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func assignsContiguousSegmentIndicesUnderConcurrentAppends() async throws {
        let server = try LoopbackMediaServer()
        defer {
            server.shutdown()
        }

        server.appendInitializationSegment(Data([0x01]))
        DispatchQueue.concurrentPerform(iterations: 25) { index in
            server.appendMediaSegment(Data([UInt8(index)]), duration: CMTime(value: 1, timescale: 2))
        }
        try server.checkForFailure()

        let playlist = String(decoding: try await request(server.mediaPlaylistURL).body, as: UTF8.self)
        for index in 0..<25 {
            #expect(playlist.contains("seg\(index).m4s"))
        }
        #expect(playlist.contains("seg25.m4s") == false)
    }

    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func bindsToLoopbackAndDeletesWorkDirectoryOnShutdown() throws {
        let server = try LoopbackMediaServer()
        let workDirectory = server.workDirectory

        #expect(server.mediaPlaylistURL.host == "localhost")
        #expect(server.boundAddress == "127.0.0.1")
        #expect(FileManager.default.fileExists(atPath: workDirectory.path))

        server.shutdown()

        #expect(FileManager.default.fileExists(atPath: workDirectory.path) == false)
    }

    // A. Large-body integrity over URLSession. Exercises the offset-advance loop and,
    // opportunistically, the EWOULDBLOCK -> arm write source -> resume cycle through
    // the production client stack.
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func servesLargeSegmentBodyByteForByteOverURLSession() async throws {
        let server = try LoopbackMediaServer()
        defer {
            server.shutdown()
        }

        let segment = Self.deterministicBytes(count: 8 * 1024 * 1024)
        server.appendInitializationSegment(Data([0x00, 0x01, 0x02, 0x03]))
        server.appendMediaSegment(segment, duration: CMTime(value: 1, timescale: 1))
        try server.checkForFailure()

        let response = try await request(try routeURL("/seg0.m4s", server: server))
        #expect(response.statusCode == 200)
        #expect(response.header("Content-Length") == "\(segment.count)")
        #expect(response.body == segment)
    }

    // B. Publication is not stalled by a partial (stop-reading) reader -- the core
    // regression guard. Under the old blocking write the serial queue parks in the
    // seg0 write and this operation never finishes; with the fix it returns promptly.
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func keepsPublishingWhileReaderStopsMidResponse() async throws {
        let server = try LoopbackMediaServer()
        let client = try RawLoopbackClient(port: try port(of: server))
        defer {
            // Close the client first: on the old-code path this EPIPEs the parked
            // write and unblocks the abandoned detached operation, so teardown is clean.
            client.close()
            server.shutdown()
        }

        server.appendInitializationSegment(Data([0x01]))
        server.appendMediaSegment(
            Self.deterministicBytes(count: 8 * 1024 * 1024),
            duration: CMTime(value: 1, timescale: 1)
        )
        try server.checkForFailure()

        try client.send("GET /seg0.m4s HTTP/1.1\r\n\r\n")
        // Receiving the prefix is a happens-after proof that the server's send() is
        // already executing on the serial queue; the unread multi-MB remainder plus the
        // small client SO_RCVBUF force the next writes to EWOULDBLOCK (fix: arm the
        // write source, free the queue) or block (old code: parked queue), far below any
        // plausible loopback buffer sum. Bump the payload if a future OS massively
        // enlarges loopback buffers.
        #expect(client.readPrefix(4 * 1024).isEmpty == false)

        let seg1 = Data([0x02])
        let finalized = resultWithin(2) {
            server.appendMediaSegment(seg1, duration: CMTime(value: 1, timescale: 1))
            try? server.checkForFailure()
            server.finish()
            return server.hasFinalizedPlaylist()
        }
        #expect(finalized == true)
    }

    // C. Slow-draining reader, byte-for-byte integrity under forced backpressure. Small
    // SO_RCVBUF + multi-MB body + slow reads deterministically drive many
    // EWOULDBLOCK -> arm -> writable -> resume-from-writeOffset cycles; the exact-bytes
    // assertion proves no byte is dropped, duplicated, or reordered across them.
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func slowDrainingReaderReceivesSegmentByteForByte() async throws {
        let server = try LoopbackMediaServer()
        let client = try RawLoopbackClient(port: try port(of: server))
        defer {
            client.close()
            server.shutdown()
        }

        server.appendInitializationSegment(Data([0x01]))
        let segment = Self.deterministicBytes(count: 2 * 1024 * 1024)
        server.appendMediaSegment(segment, duration: CMTime(value: 1, timescale: 1))
        try server.checkForFailure()

        try client.send("GET /seg0.m4s HTTP/1.1\r\n\r\n")
        let raw = try await Task.detached {
            try client.drainToEnd(chunkBytes: 16 * 1024, pauseMicroseconds: 1_000)
        }.value

        let body = try #require(httpBody(of: raw))
        #expect(body == segment)
    }

    // D. Shutdown stays responsive under backpressure. Teardown needs its own guard --
    // B closes its client before shutting down, so it never exercises shutdown while a
    // write is stalled. Under the old code shutdown's queue.sync parks behind the write.
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func shutdownStaysResponsiveWhileReaderStalls() async throws {
        let server = try LoopbackMediaServer()
        let workDirectory = server.workDirectory
        let client = try RawLoopbackClient(port: try port(of: server))
        defer {
            // After the assertions: on the old-code path this EPIPEs the stuck write so
            // the abandoned shutdown self-completes.
            client.close()
        }

        server.appendInitializationSegment(Data([0x01]))
        server.appendMediaSegment(
            Self.deterministicBytes(count: 8 * 1024 * 1024),
            duration: CMTime(value: 1, timescale: 1)
        )
        try server.checkForFailure()

        try client.send("GET /seg0.m4s HTTP/1.1\r\n\r\n")
        #expect(client.readPrefix(4 * 1024).isEmpty == false)

        let didShutdown = resultWithin(2) {
            server.shutdown()
            return true
        }
        #expect(didShutdown == true)
        #expect(FileManager.default.fileExists(atPath: workDirectory.path) == false)
    }

    // E. A broken client connection stays connection-local. Drives the new
    // WriteOutcome.failed -> closeConnection path directly (A-D only reach it during
    // teardown) and asserts it never becomes state.failure.
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func brokenClientConnectionStaysConnectionLocal() async throws {
        let server = try LoopbackMediaServer()
        let client = try RawLoopbackClient(port: try port(of: server))
        defer {
            client.close()
            server.shutdown()
        }

        server.appendInitializationSegment(Data([0x01]))
        server.appendMediaSegment(
            Self.deterministicBytes(count: 8 * 1024 * 1024),
            duration: CMTime(value: 1, timescale: 1)
        )
        try server.checkForFailure()

        try client.send("GET /seg0.m4s HTTP/1.1\r\n\r\n")
        #expect(client.readPrefix(4 * 1024).isEmpty == false)
        client.closeWithReset()

        // A short settle only ensures the async .failed write-source firing actually
        // ran (otherwise the test could pass vacuously). Unlike B/D, guard validity here
        // does not lean on the sleep -- this is a fix-behavior test.
        try await Task.sleep(for: .milliseconds(200))

        try server.checkForFailure()   // must NOT throw: failure stayed connection-local
        server.appendMediaSegment(Data([0x03]), duration: CMTime(value: 1, timescale: 1))
        server.finish()
        #expect(server.hasFinalizedPlaylist() == true)
    }

    // Runs `operation` (which may block synchronously in queue.sync) on a detached task;
    // returns its result, or nil if it did not finish within `seconds`. The semaphore's
    // timed wait returns at the deadline independent of the operation -- unlike a task
    // group, which would join the still-blocked child. The signal -> wait edge orders
    // the box write before the read, so no lock is needed on the read path.
    private func resultWithin<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () -> T
    ) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = operation()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }

    // Deterministic, well-mixed bytes (LCG): any dropped/duplicated byte shifts the tail
    // and any substitution changes a byte, so an exact-equality check catches corruption.
    private static func deterministicBytes(count: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return Data(bytes)
    }

    private func httpBody(of response: Data) -> Data? {
        guard let delimiter = response.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        return response.subdata(in: delimiter.upperBound..<response.endIndex)
    }

    private func port(of server: LoopbackMediaServer) throws -> UInt16 {
        let components = try #require(
            URLComponents(url: server.mediaPlaylistURL, resolvingAgainstBaseURL: false)
        )
        return UInt16(try #require(components.port))
    }

    private func line(containing needle: String, in text: String) -> String? {
        text.split(separator: "\n")
            .map(String.init)
            .first { $0.contains(needle) }
    }

    private func routeURL(_ path: String, server: LoopbackMediaServer) throws -> URL {
        var components = try #require(URLComponents(url: server.mediaPlaylistURL, resolvingAgainstBaseURL: false))
        components.path = path
        return try #require(components.url)
    }

    private func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:]
    ) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return HTTPResult(response: httpResponse, body: data)
    }
}

private struct HTTPResult {
    var response: HTTPURLResponse
    var body: Data

    var statusCode: Int {
        response.statusCode
    }

    func header(_ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }
}

private final class ReadyURLRecorder: Sendable {
    private let urls = Mutex<[URL]>([])

    func record(_ url: URL) {
        urls.withLock { urls in
            urls.append(url)
        }
    }

    func snapshot() -> [URL] {
        urls.withLock { $0 }
    }
}

// Written once by the detached operation, read once by resultWithin after the
// semaphore's signal -> wait edge; that edge is the synchronization, so no lock.
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private enum RawLoopbackClientError: Error {
    case socketFailed
    case addressFailed
    case connectFailed
    case sendFailed
}

// A blocking raw-socket HTTP/1.1 client that forces loopback write backpressure
// URLSession cannot express: a small SO_RCVBUF plus a reader that stops mid-response,
// slow-drains, or resets. Shared by the backpressure / broken-connection tests.
private final class RawLoopbackClient: @unchecked Sendable {
    let fileDescriptor: Int32
    private var closed = false

    init(port: UInt16, receiveBufferBytes: Int32 = 8 * 1024) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw RawLoopbackClientError.socketFailed
        }

        // Clamp the client receive buffer before connect so the advertised window stays
        // small and the server's write side hits EWOULDBLOCK well below any plausible
        // loopback buffer sum.
        var receiveBuffer = receiveBufferBytes
        _ = Darwin.setsockopt(
            fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)
        )
        // Safety net so a blocking read can never hang the suite to the time limit.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = Darwin.setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard Darwin.inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw RawLoopbackClientError.addressFailed
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw RawLoopbackClientError.connectFailed
        }

        fileDescriptor = fd
    }

    func send(_ request: String) throws {
        let bytes = Array(request.utf8)
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    fileDescriptor, base.advanced(by: offset), bytes.count - offset
                )
                guard result > 0 else {
                    throw RawLoopbackClientError.sendFailed
                }
                offset += result
            }
        }
    }

    // Reads until at least `count` bytes arrive (or EOF/error), then stops -- leaving the
    // connection open and the rest of the response unread.
    @discardableResult
    func readPrefix(_ count: Int) -> Data {
        var received = Data()
        var scratch = [UInt8](repeating: 0, count: max(1, min(count, 64 * 1024)))
        while received.count < count {
            let n = scratch.withUnsafeMutableBytes { buffer in
                Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            guard n > 0 else {
                break
            }
            received.append(scratch, count: n)
        }
        return received
    }

    // Slow-drains the whole response to EOF, sleeping `pauseMicroseconds` between reads
    // to hold the reader behind the server and keep the write side under backpressure.
    func drainToEnd(chunkBytes: Int, pauseMicroseconds: UInt32) throws -> Data {
        var received = Data()
        var scratch = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let n = scratch.withUnsafeMutableBytes { buffer in
                Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if n > 0 {
                received.append(scratch, count: n)
                if pauseMicroseconds > 0 {
                    usleep(pauseMicroseconds)
                }
                continue
            }
            if n == 0 {
                break   // EOF: the server delivered the full body and closed.
            }
            if errno == EINTR {
                continue
            }
            break
        }
        return received
    }

    func close() {
        guard closed == false else {
            return
        }
        closed = true
        Darwin.close(fileDescriptor)
    }

    // Closes with a zero linger so the unread remainder triggers an RST, surfacing at the
    // server's next write as EPIPE/ECONNRESET (SO_NOSIGPIPE => errno, not a signal).
    func closeWithReset() {
        guard closed == false else {
            return
        }
        closed = true
        var lingerOption = linger(l_onoff: 1, l_linger: 0)
        _ = Darwin.setsockopt(
            fileDescriptor, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size)
        )
        Darwin.close(fileDescriptor)
    }
}
