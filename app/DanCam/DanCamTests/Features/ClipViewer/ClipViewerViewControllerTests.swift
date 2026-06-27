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
        ClipViewerViewController(
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError("Health is not used by ClipViewerViewControllerTests.") }),
                clipPull: ClipPullClient { _, _ in
                    AsyncThrowingStream { continuation in
                        for event in pullEvents {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                },
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
