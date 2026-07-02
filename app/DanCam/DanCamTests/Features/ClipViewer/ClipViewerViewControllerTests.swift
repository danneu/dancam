import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import DanCam

@MainActor
struct ClipViewerViewControllerTests {
    @Test func captionUsesClipMetadata() {
        let controller = makeController()

        controller.loadViewIfNeeded()

        #expect(controller.captionText == Formatters.clipMetadata(durMs: 30_000, bytes: 1))
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheHitPlaysLookedUpURLWithoutPulling() async throws {
        let cacheURL = URL(filePath: "/tmp/dancam-cache-hit-\(UUID().uuidString).mp4")
        let pullCalls = CallLog<Int>()
        let controller = makeController(
            clipPull: ClipPullClient { clipID, _ in
                pullCalls.append(clipID)
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: TestError.unexpectedPull)
                }
            },
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            ),
            remuxer: ClipRemuxer { source, _ in
                ClipRemuxResult(fileURL: source, duration: .zero, bytes: 0)
            }
        )

        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == cacheURL }
        #expect(controller.currentPlayerItemURL == cacheURL)
        #expect(controller.statusText == "Ready")
        #expect(pullCalls.values().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func shareButtonIsDisabledWhilePulling() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let allowCompletion = AsyncSignal()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = makeController(
            clipPull: gatedPullClient(sourceURL: sourceURL, allowCompletion: allowCompletion),
            remuxer: ClipRemuxer { _, _ in
                Issue.record("The remuxer should not run while the pull is gated.")
                return ClipRemuxResult(fileURL: sourceURL, duration: .zero, bytes: 0)
            }
        )

        controller.loadViewIfNeeded()
        try await waitUntil { controller.statusText == "\(Formatters.byteSize(1)) of \(Formatters.byteSize(1))" }

        #expect(controller.isShareButtonEnabled == false)

        controller.didMove(toParent: nil)
        await allowCompletion.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheHitEnablesShareButton() async throws {
        let cacheURL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )

        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == cacheURL }
        #expect(controller.statusText == "Ready")
        #expect(controller.isShareButtonEnabled == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func disappearanceWithoutRemovalKeepsPlayer() async throws {
        let cacheURL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )
        defer { controller.didMove(toParent: nil) }

        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }

        let artifact = try #require(controller.makeShareArtifactForTesting())
        let directory = try #require(artifact.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        controller.viewWillDisappear(false)

        #expect(controller.hasEmbeddedPlayer == true)
        #expect(controller.currentPlayerItemURL == cacheURL)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func fullscreenRoundTripKeepsPlayer() async throws {
        let cacheURL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )
        defer { controller.didMove(toParent: nil) }

        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }

        #expect(controller.hasEmbeddedPlayer == true)
        #expect(controller.isPresentingFullScreenForTesting == false)

        controller.enterFullScreenForTesting()

        #expect(controller.hasEmbeddedPlayer == true)
        #expect(controller.currentPlayerItemURL == cacheURL)
        #expect(controller.isPresentingFullScreenForTesting == true)

        controller.exitFullScreenForTesting()

        #expect(controller.hasEmbeddedPlayer == true)
        #expect(controller.currentPlayerItemURL == cacheURL)
        #expect(controller.isPresentingFullScreenForTesting == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func removalTearsDownPlayer() async throws {
        let cacheURL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )

        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }

        #expect(controller.hasEmbeddedPlayer == true)
        #expect(controller.currentPlayerItemURL == cacheURL)

        controller.didMove(toParent: nil)

        #expect(controller.hasEmbeddedPlayer == false)
        #expect(controller.currentPlayerItemURL == nil)
    }

    @Test func shareArtifactIsNilBeforePlaying() {
        let controller = makeController()

        #expect(controller.makeShareArtifactForTesting() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheHitShareArtifactClonesCacheWithFriendlyMovieName() async throws {
        let cacheURL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )

        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }

        let clip = Clip(
            id: 1,
            startMs: nil,
            durMs: 30_000,
            bytes: 1,
            locked: false,
            etag: "list-etag",
            timeApproximate: false
        )
        let artifact = try #require(controller.makeShareArtifactForTesting())
        defer { if let dir = artifact.temporaryDirectory { try? FileManager.default.removeItem(at: dir) } }
        #expect(artifact.url.lastPathComponent == Formatters.clipExportFilename(clip))
        #expect(FileManager.default.fileExists(atPath: artifact.url.path))
        #expect(try Data(contentsOf: artifact.url) == Data([0x02]))        // clone carries the cache bytes
        #expect(UTType(filenameExtension: artifact.url.pathExtension)?.conforms(to: .movie) == true)
    }

    @Test
    func clipShareItemSourceDeclaresMovieTypeAndVendsTheURL() throws {
        let url = try temporaryFile(extension: "mp4", contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = ClipShareItemSource(url: url)
        let host = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        #expect(source.activityViewControllerPlaceholderItem(host) as? URL == url)
        #expect(source.activityViewController(host, itemForActivityType: nil) as? URL == url)

        let identifier = source.activityViewController(host, dataTypeIdentifierForActivityType: nil)
        #expect(UTType(identifier)?.conforms(to: .movie) == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func cloneFailureFallsBackToCacheURL() async throws {
        let cacheURL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )

        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }

        let blocker = try temporaryFile(extension: "blocker", contents: Data())  // a file, not a dir
        defer { try? FileManager.default.removeItem(at: blocker) }
        controller.shareScratchDirectory = blocker
        let artifact = try #require(controller.makeShareArtifactForTesting())
        #expect(artifact.url == cacheURL)             // shared the real cache file, ugly name and all
        #expect(artifact.temporaryDirectory == nil)   // nothing owned -> handler skips, defer skips
    }

    @Test(.timeLimit(.minutes(1)))
    func removalCleansUpShareArtifacts() async throws {
        let cacheURL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )

        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }

        let artifact = try #require(controller.makeShareArtifactForTesting())
        let directory = try #require(artifact.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }   // safety net if the assert fails
        #expect(FileManager.default.fileExists(atPath: directory.path))

        controller.didMove(toParent: nil)

        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func purgedCacheShareTapSelfHealsByPulling() async throws {
        let missingCacheURL = FileManager.default.temporaryDirectory
            .appending(path: "dancam-missing-cache-\(UUID().uuidString).mp4")
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let allowCompletion = AsyncSignal()
        let pullCalls = CallLog<Int>()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: missingCacheURL)
        }

        let controller = makeController(
            clipPull: gatedPullClient(
                sourceURL: sourceURL,
                allowCompletion: allowCompletion,
                calls: pullCalls
            ),
            clipCache: ClipCache(
                lookup: { _, _ in missingCacheURL },
                insert: { _, _, source in source }
            )
        )

        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == missingCacheURL }
        #expect(controller.statusText == "Ready")
        #expect(controller.currentPlayerItemURL == missingCacheURL)
        #expect(controller.makeShareArtifactForTesting() == nil)

        controller.shareTappedForTesting()

        #expect(controller.statusText == "\(Formatters.byteSize(0)) of \(Formatters.byteSize(1))")
        #expect(controller.currentPlayerItemURL == nil)
        #expect(controller.isShareButtonEnabled == false)
        try await waitUntil { pullCalls.values().count == 1 }

        controller.didMove(toParent: nil)
        await allowCompletion.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func missPullsRemuxesInsertsByResolvedETagAndPlaysCachedURL() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        let cachedURL = FileManager.default.temporaryDirectory
            .appending(path: "dancam-viewer-cached-\(UUID().uuidString).mp4")
        let insertCalls = CallLog<InsertCall>()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: cachedURL)
        }

        let controller = makeController(
            pullEvents: completedPullEvents(sourceURL: sourceURL, resolvedETag: "\"resolved-etag\""),
            clipCache: movingCache(cachedURL: cachedURL, insertCalls: insertCalls),
            remuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )

        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == cachedURL }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: mp4URL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        let insert = try #require(insertCalls.values().first)
        #expect(insert.clipID == 1)
        #expect(insert.etag == "\"resolved-etag\"")
        #expect(insert.source == mp4URL)
    }

    @Test(.timeLimit(.minutes(1)))
    func remuxFailureShowsErrorAndRetryStartsANewPull() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let pullCalls = CallLog<Int>()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = makeController(
            clipPull: pullClient(events: completedPullEvents(sourceURL: sourceURL), calls: pullCalls),
            remuxer: ClipRemuxer { _, _ in
                throw ClipRemuxError.invalidH264("boom")
            }
        )

        controller.loadViewIfNeeded()

        try await waitUntil { controller.statusText == "Clip failed" }
        #expect(controller.isRetryButtonHidden == false)
        #expect(controller.isShareButtonEnabled == false)

        controller.retryForTesting()

        try await waitUntil { pullCalls.values().count == 2 }
    }

    @Test(.timeLimit(.minutes(1)))
    func insertFailureShowsErrorCleansTempsAndRetryStartsANewPull() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = FileManager.default.temporaryDirectory
            .appending(path: "dancam-viewer-remux-\(UUID().uuidString).mp4")
        let pullCalls = CallLog<Int>()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
        }

        let controller = makeController(
            clipPull: pullClient(events: completedPullEvents(sourceURL: sourceURL), calls: pullCalls),
            clipCache: ClipCache(
                lookup: { _, _ in nil },
                insert: { _, _, _ in throw TestError.insertFailed }
            ),
            remuxer: ClipRemuxer { _, _ in
                try Data([0x02]).write(to: mp4URL)
                return ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )

        controller.loadViewIfNeeded()

        try await waitUntil {
            controller.statusText == "Clip failed"
                && FileManager.default.fileExists(atPath: sourceURL.path) == false
                && FileManager.default.fileExists(atPath: mp4URL.path) == false
        }
        #expect(controller.currentPlayerItemURL == nil)
        #expect(controller.isRetryButtonHidden == false)

        controller.retryForTesting()

        try await waitUntil { pullCalls.values().count == 2 }
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheHitPlaybackFailureSelfHealsByPullingOnce() async throws {
        let cacheURL = URL(filePath: "/tmp/dancam-missing-cache-\(UUID().uuidString).mp4")
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let pullCalls = CallLog<Int>()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = makeController(
            clipPull: ClipPullClient { clipID, _ in
                pullCalls.append(clipID)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.opened(fileURL: sourceURL))
                    continuation.yield(.progress(bytesWritten: 1, expected: 1))
                }
            },
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            )
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == cacheURL }
        #expect(controller.currentPlayerItemURL == cacheURL)

        controller.failCurrentPlayerForTesting()

        try await waitUntil { pullCalls.values().count == 1 }
        #expect(controller.statusText != "Clip failed")
    }

    @Test(.timeLimit(.minutes(1)))
    func postRemuxPlaybackFailureSurfacesAndDoesNotAutoRepull() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try temporaryFile(extension: "mp4", contents: Data([0x02]))
        let cachedURL = FileManager.default.temporaryDirectory
            .appending(path: "dancam-viewer-cached-\(UUID().uuidString).mp4")
        let pullCalls = CallLog<Int>()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: cachedURL)
        }

        let controller = makeController(
            clipPull: pullClient(events: completedPullEvents(sourceURL: sourceURL), calls: pullCalls),
            clipCache: movingCache(cachedURL: cachedURL),
            remuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4URL, duration: .seconds(30), bytes: 1)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == cachedURL }
        controller.failCurrentPlayerForTesting()

        try await waitUntil { controller.statusText == "Clip failed" }
        try await Task.sleep(for: .milliseconds(50))
        #expect(pullCalls.values().count == 1)
        #expect(controller.isRetryButtonHidden == false)

        controller.retryForTesting()

        try await waitUntil { pullCalls.values().count == 2 }
    }

    @Test(.timeLimit(.minutes(1)))
    func navAwayDuringPullCancelsAndCleansTempFile() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let allowCompletion = AsyncSignal()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = makeController(
            clipPull: gatedPullClient(sourceURL: sourceURL, allowCompletion: allowCompletion),
            remuxer: ClipRemuxer { _, _ in
                Issue.record("The remuxer should not run while the pull is gated.")
                return ClipRemuxResult(fileURL: sourceURL, duration: .zero, bytes: 0)
            }
        )

        controller.loadViewIfNeeded()
        try await waitUntil { controller.statusText == "\(Formatters.byteSize(1)) of \(Formatters.byteSize(1))" }

        controller.didMove(toParent: nil)
        await allowCompletion.signal()

        try await waitUntil {
            FileManager.default.fileExists(atPath: sourceURL.path) == false
        }
    }

    private func makeController(
        pullEvents: [ClipPullEvent],
        clipCache: ClipCache = .noop,
        remuxer: ClipRemuxer
    ) -> ClipViewerViewController {
        makeController(
            clipPull: pullClient(events: pullEvents),
            clipCache: clipCache,
            remuxer: remuxer
        )
    }

    private func makeController(
        clipPull: ClipPullClient = .noop,
        clipCache: ClipCache = .noop,
        remuxer: ClipRemuxer = .noop
    ) -> ClipViewerViewController {
        ClipViewerViewController(
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError("Health is not used by ClipViewerViewControllerTests.") }),
                clipPull: clipPull,
                clipRemuxer: remuxer,
                clipCache: clipCache
            ),
            clip: Clip(
                id: 1,
                startMs: nil,
                durMs: 30_000,
                bytes: 1,
                locked: false,
                etag: "list-etag",
                timeApproximate: false
            )
        )
    }

    private func movingCache(
        cachedURL: URL,
        insertCalls: CallLog<InsertCall> = CallLog<InsertCall>()
    ) -> ClipCache {
        ClipCache(
            lookup: { _, _ in nil },
            insert: { clipID, etag, source in
                insertCalls.append(InsertCall(clipID: clipID, etag: etag, source: source))
                try? FileManager.default.removeItem(at: cachedURL)
                try FileManager.default.moveItem(at: source, to: cachedURL)
                return cachedURL
            }
        )
    }

    private func pullClient(
        events: [ClipPullEvent],
        calls: CallLog<Int> = CallLog<Int>()
    ) -> ClipPullClient {
        ClipPullClient { clipID, _ in
            calls.append(clipID)
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func gatedPullClient(
        sourceURL: URL,
        allowCompletion: AsyncSignal,
        calls: CallLog<Int> = CallLog<Int>()
    ) -> ClipPullClient {
        ClipPullClient { clipID, _ in
            calls.append(clipID)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.opened(fileURL: sourceURL))
                    continuation.yield(.progress(bytesWritten: 1, expected: 1))
                    await allowCompletion.wait()
                    continuation.yield(.completed(ClipPullResult(
                        fileURL: sourceURL,
                        bytes: 1,
                        elapsed: .milliseconds(1),
                        throughputMbps: 1,
                        resolvedETag: "\"list-etag\""
                    )))
                    continuation.finish()
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }
    }

    private func completedPullEvents(
        sourceURL: URL,
        resolvedETag: String = "\"list-etag\""
    ) -> [ClipPullEvent] {
        [
            .opened(fileURL: sourceURL),
            .progress(bytesWritten: 1, expected: 1),
            .completed(ClipPullResult(
                fileURL: sourceURL,
                bytes: 1,
                elapsed: .milliseconds(1),
                throughputMbps: 1,
                resolvedETag: resolvedETag
            )),
        ]
    }

    private func temporaryFile(
        extension pathExtension: String,
        contents: Data
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).\(pathExtension)")
        try contents.write(to: url)
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

private enum TestError: Error {
    case insertFailed
    case unexpectedPull
}

private struct InsertCall: Equatable, Sendable {
    var clipID: Int
    var etag: String
    var source: URL
}

private final class CallLog<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    func values() -> [Value] {
        lock.lock()
        let values = stored
        lock.unlock()
        return values
    }
}
