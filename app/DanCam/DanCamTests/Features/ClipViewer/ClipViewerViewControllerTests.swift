import AVFoundation
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

    @Test func captionPrefixesTrustedCreatedTime() {
        let clip = Clip(
            id: 1,
            startMs: 1_767_225_600_000,
            durMs: 30_000,
            bytes: 1,
            locked: false,
            etag: "list-etag",
            timeApproximate: false
        )
        let controller = makeController(clip: clip)

        controller.loadViewIfNeeded()

        #expect(controller.captionText == Formatters.clipDetailLine(clip))
    }

    @Test(.timeLimit(.minutes(1)))
    func deleteSendsClientCommandAndPopsViewer() async throws {
        let clip = Clip(
            id: 7,
            startMs: nil,
            durMs: 30_000,
            bytes: 1,
            locked: false,
            etag: "7-1",
            timeApproximate: false
        )
        let calls = CallLog<Int>()
        let controller = makeController(
            clipsClient: ClipsClient(
                fetch: { _ in fatalError("Delete should not fetch clips.") },
                delete: { id in calls.append(id) }
            ),
            clip: clip
        )
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        controller.performDeleteForTesting()

        try await waitUntil { calls.values() == [7] }
        #expect(navigationController.viewControllers.contains(controller) == false)
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
        #expect(controller.progressIndicatorForTesting == .hidden)
        #expect(pullCalls.values().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func initialCacheLookupShowsIndeterminateProgress() async {
        let allowLookup = AsyncSignal()
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in
                    await allowLookup.wait()
                    return nil
                },
                insert: { _, _, source in source }
            )
        )

        controller.loadViewIfNeeded()

        #expect(controller.statusText == "Preparing")
        #expect(controller.progressIndicatorForTesting == .indeterminate)

        controller.didMove(toParent: nil)
        await allowLookup.signal()
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
        #expect(controller.progressIndicatorForTesting == .determinate)

        controller.didMove(toParent: nil)
        await allowCompletion.signal()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [UInt64?.none, UInt64?(0)])
    func unknownOrZeroExpectedPullShowsIndeterminateProgress(expected: UInt64?) async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        let allowCompletion = AsyncSignal()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = makeController(
            clipPull: gatedPullClient(
                sourceURL: sourceURL,
                allowCompletion: allowCompletion,
                bytesWritten: 5,
                expected: expected
            ),
            remuxer: ClipRemuxer { _, _ in
                Issue.record("The remuxer should not run while the pull is gated.")
                return ClipRemuxResult(fileURL: sourceURL, duration: .zero, bytes: 0)
            }
        )

        controller.loadViewIfNeeded()
        try await waitUntil { controller.statusText == "\(Formatters.byteSize(5)) pulled" }

        #expect(controller.progressIndicatorForTesting == .indeterminate)

        controller.didMove(toParent: nil)
        await allowCompletion.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func remuxPreparingShowsIndeterminateProgress() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let remuxStarted = AsyncSignal()
        let allowRemuxCompletion = AsyncSignal()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = makeController(
            pullEvents: completedPullEvents(sourceURL: sourceURL),
            remuxer: gatedRemuxer(
                allowCompletion: allowRemuxCompletion,
                didStart: remuxStarted
            )
        )

        controller.loadViewIfNeeded()

        await remuxStarted.wait()
        #expect(controller.statusText == "Preparing")
        #expect(controller.progressIndicatorForTesting == .indeterminate)

        await allowRemuxCompletion.signal()
        try await waitUntil { controller.currentPlayerItemURL == sourceURL }
        controller.didMove(toParent: nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheHitEnablesShareButton() async throws {
        let cacheURL = try await temporaryPlayableVideoFile()
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
        let cacheURL = try await temporaryPlayableVideoFile()
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

        controller.viewWillDisappear(false)

        #expect(controller.hasEmbeddedPlayer == true)
        #expect(controller.currentPlayerItemURL == cacheURL)
    }

    @Test(.timeLimit(.minutes(1)))
    func fullscreenRoundTripKeepsPlayer() async throws {
        let cacheURL = try await temporaryPlayableVideoFile()
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
        let cacheURL = try await temporaryPlayableVideoFile()
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

    @Test func shareBeforePlayingDoesNothing() {
        let controller = makeController()

        controller.shareTappedForTesting()

        #expect(controller.isSharePreparingForTesting == false)
        #expect(controller.presentedShareURLForTesting == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheHitSharePreparesImmediatelyAndPresentsFriendlyMovieName() async throws {
        let cacheURL = try await temporaryPlayableVideoFile()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let preparationStarted = AsyncSignal()
        let allowPreparation = AsyncSignal()
        let calls = CallLog<SharePreparationRequest>()
        let presentation = VideoSharePresentationSpy()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "dancam-viewer-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        let clip = Clip(
            id: 1,
            startMs: nil,
            durMs: 30_000,
            bytes: 1,
            locked: false,
            etag: "list-etag",
            timeApproximate: false
        )
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            ),
            shareArtifactPreparer: ShareArtifactPreparer { request in
                calls.append(request)
                await preparationStarted.signal()
                await allowPreparation.wait()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appending(path: request.suggestedFilename)
                try Data(contentsOf: request.sourceURL).write(to: destination)
                return PreparedShareArtifact(url: destination, ownedDirectory: directory)
            },
            sharePresentation: presentation.presentation,
            clip: clip
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()

        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }

        controller.shareTappedForTesting()
        controller.shareTappedForTesting()

        #expect(controller.isSharePreparingForTesting)
        #expect(controller.sharePreparationAccessibilityLabelForTesting == "Preparing video")
        #expect(controller.isShareButtonEnabled == false)
        #expect(controller.isDeleteButtonEnabledForTesting == false)
        #expect(controller.isScrollEnabledForTesting)
        #expect(controller.hasEmbeddedPlayer)
        await preparationStarted.wait()
        #expect(calls.values().count == 1)
        let request = try #require(calls.values().first)
        #expect(request.sourceURL == cacheURL)
        #expect(request.suggestedFilename == Formatters.clipExportFilename(clip))

        await allowPreparation.signal()
        try await waitUntil { presentation.presentedURL != nil }
        let presentedURL = try #require(presentation.presentedURL)
        #expect(presentedURL.lastPathComponent == Formatters.clipExportFilename(clip))
        try await waitUntil { controller.isSharePreparingForTesting == false }
        #expect(controller.isShareButtonEnabled)
        #expect(controller.isDeleteButtonEnabledForTesting)

        #expect(FileManager.default.fileExists(atPath: directory.path))
        presentation.complete()
        try await waitUntil { FileManager.default.fileExists(atPath: directory.path) == false }
        controller.didMove(toParent: nil)
        _ = window
    }

    @Test(.timeLimit(.minutes(1)))
    func purgedCacheShareTapSelfHealsByPulling() async throws {
        let missingCacheURL = try await temporaryPlayableVideoFile()
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
        try FileManager.default.removeItem(at: missingCacheURL)
        controller.shareTappedForTesting()

        try await waitUntil { pullCalls.values().count == 1 }
        #expect(controller.statusText == "\(Formatters.byteSize(0)) of \(Formatters.byteSize(1))")
        #expect(controller.currentPlayerItemURL == nil)
        #expect(controller.isShareButtonEnabled == false)

        controller.didMove(toParent: nil)
        await allowCompletion.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func backNavigationCancelsPreparationAndCleansLateArtifact() async throws {
        let cacheURL = try await temporaryPlayableVideoFile()
        let preparationStarted = AsyncSignal()
        let allowPreparation = AsyncSignal()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "dancam-viewer-late-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        let artifactURL = directory.appending(path: "late.mp4")
        defer {
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: directory)
        }
        let controller = makeController(
            clipCache: ClipCache(
                lookup: { _, _ in cacheURL },
                insert: { _, _, source in source }
            ),
            shareArtifactPreparer: ShareArtifactPreparer { _ in
                await preparationStarted.signal()
                await allowPreparation.wait()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data([0x02]).write(to: artifactURL)
                return PreparedShareArtifact(url: artifactURL, ownedDirectory: directory)
            }
        )
        controller.loadViewIfNeeded()
        try await waitUntil { controller.currentPlayerItemURL == cacheURL }
        controller.shareTappedForTesting()
        await preparationStarted.wait()

        controller.didMove(toParent: nil)

        #expect(controller.isSharePreparingForTesting == false)
        await allowPreparation.signal()
        try await waitUntil { FileManager.default.fileExists(atPath: directory.path) == false }
        #expect(controller.presentedShareURLForTesting == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func missPullsRemuxesInsertsByResolvedETagAndPlaysCachedURL() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let mp4URL = try await temporaryPlayableVideoFile()
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
        #expect(controller.statusText == "Ready")
        #expect(controller.progressIndicatorForTesting == .hidden)
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
        #expect(controller.progressIndicatorForTesting == .hidden)
        #expect(controller.isRetryButtonHidden == false)
        #expect(controller.isShareButtonEnabled == false)

        controller.retryForTesting()

        try await waitUntil { pullCalls.values().count == 2 }
    }

    @Test(.timeLimit(.minutes(1)))
    func remuxFailureShowsHonestMessage() async throws {
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = makeController(
            pullEvents: completedPullEvents(sourceURL: sourceURL),
            remuxer: ClipRemuxer { _, _ in
                throw ClipRemuxError.invalidTransportStream("No H.264 PES packets found.")
            }
        )

        controller.loadViewIfNeeded()

        try await waitUntil { controller.statusText == "Clip failed" }
        #expect(controller.resultText == "Clip contains no playable video: No H.264 PES packets found.")
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
    func cacheHitPlaybackFailureDuringPreparationRepullsAndCleansLateArtifact() async throws {
        let cacheURL = URL(filePath: "/tmp/dancam-missing-cache-\(UUID().uuidString).mp4")
        let sourceURL = try temporaryFile(extension: "ts", contents: Data([0x01]))
        let pullCalls = CallLog<Int>()
        let preparationStarted = AsyncSignal()
        let allowPreparation = AsyncSignal()
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appending(path: "dancam-late-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        let artifactURL = artifactDirectory.appending(path: "late.mp4")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: artifactDirectory)
        }

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
            ),
            shareArtifactPreparer: ShareArtifactPreparer { _ in
                await preparationStarted.signal()
                await allowPreparation.wait()
                try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
                try Data([0x02]).write(to: artifactURL)
                return PreparedShareArtifact(url: artifactURL, ownedDirectory: artifactDirectory)
            }
        )
        controller.loadViewIfNeeded()

        try await waitUntil { controller.currentPlayerItemURL == cacheURL }
        #expect(controller.currentPlayerItemURL == cacheURL)

        controller.shareTappedForTesting()
        await preparationStarted.wait()
        controller.failCurrentPlayerForTesting()

        try await waitUntil { pullCalls.values().count == 1 }
        #expect(controller.statusText != "Clip failed")
        #expect(controller.isSharePreparingForTesting == false)

        await allowPreparation.signal()
        try await waitUntil { FileManager.default.fileExists(atPath: artifactDirectory.path) == false }
        #expect(controller.presentedShareURLForTesting == nil)
        controller.didMove(toParent: nil)
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
        remuxer: ClipRemuxer = .noop,
        clipsClient: ClipsClient = .noop,
        shareArtifactPreparer: ShareArtifactPreparer = .unavailable,
        sharePresentation: VideoSharePresentation? = nil,
        clip: Clip = Clip(
            id: 1,
            startMs: nil,
            durMs: 30_000,
            bytes: 1,
            locked: false,
            etag: "list-etag",
            timeApproximate: false
        )
    ) -> ClipViewerViewController {
        let dependencies = AppDependencies(
            clips: clipsClient,
            clipPull: clipPull,
            clipRemuxer: remuxer,
            clipCache: clipCache,
            shareArtifactPreparer: shareArtifactPreparer
        )
        let store = AppStore(
            initialState: AppFeature.State(),
            dependencies: dependencies,
            reduce: AppFeature.reduce
        )
        return ClipViewerViewController(
            dependencies: dependencies,
            store: store,
            clip: clip,
            sharePresentation: sharePresentation
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
        calls: CallLog<Int> = CallLog<Int>(),
        bytesWritten: UInt64 = 1,
        expected: UInt64? = 1
    ) -> ClipPullClient {
        ClipPullClient { clipID, _ in
            calls.append(clipID)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.opened(fileURL: sourceURL))
                    continuation.yield(.progress(bytesWritten: bytesWritten, expected: expected))
                    await allowCompletion.wait()
                    continuation.yield(.completed(ClipPullResult(
                        fileURL: sourceURL,
                        bytes: bytesWritten,
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

    private func gatedRemuxer(
        allowCompletion: AsyncSignal,
        didStart: AsyncSignal
    ) -> ClipRemuxer {
        ClipRemuxer { source, _ in
            await didStart.signal()
            await allowCompletion.wait()

            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
            let bytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            return ClipRemuxResult(fileURL: source, duration: .zero, bytes: bytes)
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

    private func temporaryPlayableVideoFile() async throws -> URL {
        try await makeTemporaryPlayableVideoFile()
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
