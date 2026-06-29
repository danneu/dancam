import AVFoundation
import Foundation
import Testing
@testable import DanCam

struct ProgressivePlaybackIntegrationTests {
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func livePullThroughProgressiveSegmenterProducesPlayableItem() async throws {
        let fixtureURL = try MediaFixtureURLs.seg00000TS()
        let fixtureData = try Data(contentsOf: fixtureURL)
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let clipID = 91_200
        let pullClient = ClipPullClient.live(baseURL: baseURL, sleep: { _ in }) { _, _ in
            AsyncStreamHelpers.byteStream(Self.responseChunks(for: fixtureData))
        }
        var availabilityContinuation: AsyncStream<UInt64>.Continuation?
        var segmenterDrainTask: Task<Void, Never>?
        let (firstPlayableURLs, firstPlayableContinuation) = AsyncThrowingStream.makeStream(
            of: URL.self,
            throwing: Error.self
        )
        let segmenterFinished = AsyncSignal()
        var pullResult: ClipPullResult?
        var remuxedURL: URL?
        defer {
            availabilityContinuation?.finish()
            segmenterDrainTask?.cancel()
            if let sourceURL = pullResult?.fileURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            if let remuxedURL {
                try? FileManager.default.removeItem(at: remuxedURL)
            }
        }

        for try await event in pullClient.pull(clipID, "fixture-\(fixtureData.count)") {
            switch event {
            case .opened(let sourceURL):
                let (availability, continuation) = AsyncStream.makeStream(of: UInt64.self)
                availabilityContinuation = continuation
                let events = ProgressiveSegmenter.live.start(sourceURL, clipID, availability)
                segmenterDrainTask = Self.drainSegmenterEvents(
                    events,
                    firstPlayableContinuation: firstPlayableContinuation,
                    segmenterFinished: segmenterFinished
                )
            case .restarted:
                throw ClipRemuxError.file("Fixture pull unexpectedly restarted.")
            case .progress(let bytesWritten, _):
                availabilityContinuation?.yield(bytesWritten)
            case .completed(let result):
                pullResult = result
                availabilityContinuation?.finish()
            }
        }

        _ = try #require(segmenterDrainTask)
        let playlistURL = try await Self.firstValue(from: firstPlayableURLs)
        let item = AVPlayerItem(url: playlistURL)
        let player = AVPlayer(playerItem: item)
        defer {
            player.pause()
        }

        try await Self.waitUntil {
            item.status != .unknown
        }
        if item.status == .failed {
            Issue.record("Progressive item failed: \(String(describing: item.error)).")
        }
        #expect(item.status == .readyToPlay)

        let completedPull = try #require(pullResult)
        let remuxed = try await ClipRemuxer.live.remux(completedPull.fileURL, clipID)
        remuxedURL = remuxed.fileURL
        let remuxedAsset = AVURLAsset(url: remuxed.fileURL)
        let remuxedDuration = try await remuxedAsset.load(.duration)
        #expect(abs(remuxedDuration.seconds - 30.0) < 0.5)

        await segmenterFinished.wait()
        let progressiveAsset = AVURLAsset(url: playlistURL)
        let progressiveDuration = try await progressiveAsset.load(.duration)
        #expect(progressiveDuration.isNumeric)
        #expect(abs(progressiveDuration.seconds - remuxedDuration.seconds) < 0.5)
    }

    private static func drainSegmenterEvents(
        _ events: AsyncThrowingStream<ProgressiveSegmenterEvent, Error>,
        firstPlayableContinuation: AsyncThrowingStream<URL, Error>.Continuation,
        segmenterFinished: AsyncSignal
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await event in events {
                    switch event {
                    case .firstPlayableReady(let url):
                        firstPlayableContinuation.yield(url)
                    case .finished:
                        await segmenterFinished.signal()
                    case .opened:
                        break
                    }
                }
                firstPlayableContinuation.finish()
            } catch {
                firstPlayableContinuation.finish(throwing: error)
            }
        }
    }

    private static func firstValue<T>(
        from stream: AsyncThrowingStream<T, Error>
    ) async throws -> T {
        for try await value in stream {
            return value
        }
        throw ClipRemuxError.file("Expected a first playable progressive URL.")
    }

    private static func responseChunks(
        for body: Data,
        bodyChunkSize: Int = 32 * 1024
    ) -> [Data] {
        let response = MJPEGWireBuilder.response(
            headers: [
                ("Content-Type", "application/mp2t"),
                ("Content-Length", "\(body.count)"),
            ],
            body: body
        )
        guard let headEnd = response.range(of: Data("\r\n\r\n".utf8))?.upperBound else {
            return [response]
        }

        var chunks = [Data(response[..<headEnd])]
        var offset = headEnd
        while offset < response.count {
            let end = min(offset + bodyChunkSize, response.count)
            chunks.append(Data(response[offset..<end]))
            offset = end
        }
        return chunks
    }

    private static func waitUntil(
        _ condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for condition.")
    }
}
