import AVFoundation
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
        #expect(server.bindAddress == "127.0.0.1")
        #expect(FileManager.default.fileExists(atPath: workDirectory.path))

        server.shutdown()

        #expect(FileManager.default.fileExists(atPath: workDirectory.path) == false)
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
