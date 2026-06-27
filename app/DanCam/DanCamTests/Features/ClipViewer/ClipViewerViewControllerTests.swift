import AVFoundation
import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct ClipViewerViewControllerTests {
    @Test
    func progressiveAvailabilityTerminatesOnExplicitRestart() {
        var lastForwarded: UInt64 = 0

        #expect(ProgressiveAvailability.decide(
            .progress(bytesWritten: 4, expected: 100),
            lastForwarded: &lastForwarded
        ) == .advance(4))
        #expect(ProgressiveAvailability.decide(
            .progress(bytesWritten: 7, expected: 100),
            lastForwarded: &lastForwarded
        ) == .advance(7))
        #expect(ProgressiveAvailability.decide(
            .progress(bytesWritten: 12, expected: 100),
            lastForwarded: &lastForwarded
        ) == .advance(12))
        #expect(ProgressiveAvailability.decide(
            .restarted,
            lastForwarded: &lastForwarded
        ) == .terminateProgressive)
        #expect(ProgressiveAvailability.decide(
            .progress(bytesWritten: 64, expected: 100),
            lastForwarded: &lastForwarded
        ) == .advance(64))
    }

    @Test
    func progressiveAvailabilityDefensivelyTerminatesOnNonMonotonicProgress() {
        var lastForwarded: UInt64 = 0

        #expect(ProgressiveAvailability.decide(
            .progress(bytesWritten: 12, expected: 100),
            lastForwarded: &lastForwarded
        ) == .advance(12))
        #expect(ProgressiveAvailability.decide(
            .progress(bytesWritten: 2, expected: 100),
            lastForwarded: &lastForwarded
        ) == .terminateProgressive)
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulRemuxDeletesPulledTSAndDeletesMP4OnDisappear() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        let didRemux = AsyncSignal()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
        }

        let controller = makeController(
            sourceURL: sourceURL,
            remuxer: ClipRemuxer { _, _ in
                await didRemux.signal()
                return ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        await didRemux.wait()
        try await waitUntil { FileManager.default.fileExists(atPath: sourceURL.path) == false }
        #expect(FileManager.default.fileExists(atPath: mp4URL.path))
        #expect(controller.statusText == "Ready")
        #expect(controller.currentPlayerItemURL == mp4URL)

        controller.viewWillDisappear(false)

        #expect(FileManager.default.fileExists(atPath: mp4URL.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationAfterRemuxReturnsDeletesPulledTSAndCompletedMP4() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        let mp4Written = AsyncSignal()
        let allowReturn = AsyncSignal()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
        }

        let controller = makeController(
            sourceURL: sourceURL,
            remuxer: ClipRemuxer { _, _ in
                await mp4Written.signal()
                await allowReturn.wait()
                return ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        await mp4Written.wait()
        controller.viewWillDisappear(false)
        await allowReturn.signal()

        try await waitUntil {
            FileManager.default.fileExists(atPath: sourceURL.path) == false
                && FileManager.default.fileExists(atPath: mp4URL.path) == false
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func remuxFailureDeletesPulledTS() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let controller = makeController(
            sourceURL: sourceURL,
            remuxer: ClipRemuxer { _, _ in
                throw ClipRemuxError.invalidH264("boom")
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { FileManager.default.fileExists(atPath: sourceURL.path) == false }
    }

    @Test(.timeLimit(.minutes(1)))
    func segmenterFailureFallsBackToFinalizedMP4() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
        }

        let controller = makeController(
            pullEvents: completedPullEvents(sourceURL: sourceURL),
            progressiveSegmenter: failingSegmenter(),
            remuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == mp4URL }
        #expect(controller.statusText == "Ready")
        #expect(controller.hasEmbeddedPlayer)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func noopSegmenterNeverProducingFirstFrameFallsBackToFinalizedMP4() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
        }

        let controller = makeController(
            pullEvents: completedPullEvents(sourceURL: sourceURL),
            progressiveSegmenter: .noop,
            remuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == mp4URL }
        #expect(controller.statusText == "Ready")
        #expect(controller.hasEmbeddedPlayer)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func restartedPullTerminatesProgressiveAttemptButStillReadiesMP4() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
        }

        let controller = makeController(
            pullEvents: [
                .opened(fileURL: sourceURL),
                .progress(bytesWritten: 4, expected: 100),
                .restarted,
                .progress(bytesWritten: 64, expected: 100),
                .completed(ClipPullResult(
                    fileURL: sourceURL,
                    bytes: 100,
                    elapsed: .milliseconds(10),
                    throughputMbps: 80
                )),
            ],
            progressiveSegmenter: .noop,
            remuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == mp4URL }
        #expect(controller.statusText == "Ready")
        #expect(controller.resultText == "100 bytes pulled - 1 byte playable - 0.0 s - 80 Mbps")
        #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func progressiveSegmenterReachesPlayingWhilePulling() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dancam-progressive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let playlistURL = try #require(URL(string: "http://localhost:49152/p.m3u8"))
        let allowPullToFinish = AsyncSignal()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: workDirectory)
        }

        let controller = makeController(
            clipPull: gatedPullClient(sourceURL: sourceURL, allowCompletion: allowPullToFinish),
            progressiveSegmenter: playingSegmenter(playlistURL: playlistURL, workDirectory: workDirectory),
            remuxer: ClipRemuxer { _, _ in
                Issue.record("Progressive test should not reach the finalizer before assertion.")
                return ClipRemuxResult(fileURL: sourceURL, duration: .seconds(0), bytes: 0)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == playlistURL }
        #expect(controller.hasEmbeddedPlayer)
        #expect(controller.statusText == "Playing - 1 byte of 1 byte")

        controller.viewWillDisappear(false)
        await allowPullToFinish.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func completedProgressivePullSwapsToDurableMP4PreservingPlaybackPosition() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dancam-progressive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let playlistURL = try #require(URL(string: "http://localhost:49152/p.m3u8"))
        let allowPullToFinish = AsyncSignal()
        let resumeTime = CMTime(seconds: 0.75, preferredTimescale: 600)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: workDirectory)
        }

        let controller = makeController(
            clipPull: gatedPullClient(sourceURL: sourceURL, allowCompletion: allowPullToFinish),
            progressiveSegmenter: playingSegmenter(playlistURL: playlistURL, workDirectory: workDirectory),
            remuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == playlistURL }
        await controller.seekCurrentPlayerForTesting(to: resumeTime)
        try await waitUntil { isTime(controller.currentPlayerTime, near: resumeTime) }
        controller.pauseCurrentPlayerForTesting()

        await allowPullToFinish.signal()

        try await waitUntil { controller.currentPlayerItemURL == mp4URL }
        try await waitUntil { isTime(controller.currentPlayerTime, near: resumeTime) }
        #expect(controller.statusText == "Ready")
        #expect(controller.resultText == "1 byte pulled - 1 byte playable - 0.0 s - 1 Mbps")
        #expect(controller.isCurrentPlayerPlaying == false)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: workDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: mp4URL.path))

        controller.viewWillDisappear(false)

        #expect(FileManager.default.fileExists(atPath: mp4URL.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func postSwapFirstPlayableReadyDoesNotReplaceDurableMP4() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dancam-progressive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let playlistURL = try #require(URL(string: "http://localhost:49153/p.m3u8"))
        let allowLateFirstPlayable = AsyncSignal()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: workDirectory)
        }

        let controller = makeController(
            pullEvents: completedPullEvents(sourceURL: sourceURL),
            progressiveSegmenter: postSwapFirstPlayableSegmenter(
                playlistURL: playlistURL,
                workDirectory: workDirectory,
                allowLateFirstPlayable: allowLateFirstPlayable
            ),
            remuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == mp4URL }
        await allowLateFirstPlayable.signal()
        try await Task.sleep(for: .milliseconds(50))

        #expect(controller.currentPlayerItemURL == mp4URL)
        #expect(controller.statusText == "Ready")
    }

    private func makeController(
        sourceURL: URL,
        remuxer: ClipRemuxer
    ) -> ClipViewerViewController {
        makeController(
            pullEvents: [
                .completed(ClipPullResult(
                    fileURL: sourceURL,
                    bytes: 1,
                    elapsed: .milliseconds(1),
                    throughputMbps: 1
                )),
            ],
            progressiveSegmenter: .noop,
            remuxer: remuxer
        )
    }

    private func makeController(
        pullEvents: [ClipPullEvent],
        progressiveSegmenter: ProgressiveSegmenter,
        remuxer: ClipRemuxer
    ) -> ClipViewerViewController {
        makeController(
            clipPull: ClipPullClient { _, _ in
                AsyncThrowingStream { continuation in
                    for event in pullEvents {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            },
            progressiveSegmenter: progressiveSegmenter,
            remuxer: remuxer
        )
    }

    private func makeController(
        clipPull: ClipPullClient,
        progressiveSegmenter: ProgressiveSegmenter,
        remuxer: ClipRemuxer
    ) -> ClipViewerViewController {
        ClipViewerViewController(
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError("Health is not used by ClipViewerViewControllerTests.") }),
                clipPull: clipPull,
                clipRemuxer: remuxer,
                progressiveSegmenter: progressiveSegmenter
            ),
            clip: Clip(
                id: 1,
                startMs: nil,
                durMs: 30_000,
                bytes: 1,
                locked: false,
                etag: "etag",
                timeApproximate: false
            )
        )
    }

    private func completedPullEvents(sourceURL: URL) -> [ClipPullEvent] {
        [
            .opened(fileURL: sourceURL),
            .progress(bytesWritten: 1, expected: 1),
            .completed(ClipPullResult(
                fileURL: sourceURL,
                bytes: 1,
                elapsed: .milliseconds(1),
                throughputMbps: 1
            )),
        ]
    }

    private func failingSegmenter() -> ProgressiveSegmenter {
        ProgressiveSegmenter { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: ClipRemuxError.invalidH264("boom"))
            }
        }
    }

    private func playingSegmenter(
        playlistURL: URL,
        workDirectory: URL
    ) -> ProgressiveSegmenter {
        ProgressiveSegmenter { _, _, availability in
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.opened(workDirectory: workDirectory))

                    var didEmitFirstPlayable = false
                    for await bytesAvailable in availability {
                        guard didEmitFirstPlayable == false, bytesAvailable > 0 else {
                            continue
                        }
                        didEmitFirstPlayable = true
                        continuation.yield(.firstPlayableReady(url: playlistURL))
                    }
                    continuation.finish()
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }
    }

    private func postSwapFirstPlayableSegmenter(
        playlistURL: URL,
        workDirectory: URL,
        allowLateFirstPlayable: AsyncSignal
    ) -> ProgressiveSegmenter {
        ProgressiveSegmenter { _, _, availability in
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.opened(workDirectory: workDirectory))
                    for await _ in availability {
                    }
                    await allowLateFirstPlayable.wait()
                    continuation.yield(.firstPlayableReady(url: playlistURL))
                    continuation.finish()
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }
    }

    private func gatedPullClient(
        sourceURL: URL,
        allowCompletion: AsyncSignal
    ) -> ClipPullClient {
        ClipPullClient { _, _ in
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.opened(fileURL: sourceURL))
                    continuation.yield(.progress(bytesWritten: 1, expected: 1))
                    await allowCompletion.wait()
                    continuation.yield(.completed(ClipPullResult(
                        fileURL: sourceURL,
                        bytes: 1,
                        elapsed: .milliseconds(1),
                        throughputMbps: 1
                    )))
                    continuation.finish()
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }
    }

    private func temporaryFile(
        extension pathExtension: String,
        contents: Data
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).\(pathExtension)")
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw ClipRemuxError.file("Could not create test file.")
        }
        return url
    }

    private func isTime(
        _ actual: CMTime,
        near expected: CMTime,
        tolerance: Double = 1.0 / 30.0
    ) -> Bool {
        guard actual.isNumeric, expected.isNumeric else {
            return false
        }
        return abs(actual.seconds - expected.seconds) < tolerance
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
    }
}
