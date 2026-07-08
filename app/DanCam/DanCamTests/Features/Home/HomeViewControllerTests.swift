import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct HomeViewControllerTests {
    // MARK: Prefetch glue (observable cancels)

    @Test(.timeLimit(.minutes(1)))
    func prefetchCancelsTheReplacedHandleBeforeStoringANewOne() async throws {
        let probe = HomeLoaderProbe()
        let controller = makeController(clips: [clipA, clipB], loader: probe.loader())
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])
        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])

        #expect(probe.prefetchCancelCount(clipA) == 1)  // the first handle was cancelled before replace
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelPrefetchingCancelsTheStoredHandle() async throws {
        let probe = HomeLoaderProbe()
        let controller = makeController(clips: [clipA, clipB], loader: probe.loader())
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])
        controller.tableView(UITableView(), cancelPrefetchingForRowsAt: [IndexPath(row: 0, section: 0)])

        #expect(probe.prefetchCancelCount(clipA) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aClipsUpdatePreservesSurvivingPrefetchHandles() async throws {
        let probe = HomeLoaderProbe()
        let (controller, store) = makeControllerAndStore(clips: [clipA, clipB], loader: probe.loader())
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [
            IndexPath(row: 0, section: 0),
            IndexPath(row: 1, section: 0),
        ])

        store.send(.clips(.clipFinalized(clipC)))

        #expect(probe.prefetchCancelCount(clipA) == 0)
        #expect(probe.prefetchCancelCount(clipB) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aReRepresentedClipCancelsItsStaleHandle() async throws {
        let probe = HomeLoaderProbe()
        let (controller, store) = makeControllerAndStore(clips: [clipA, clipB], loader: probe.loader())
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])
        let updatedClipA = Clip(
            id: clipA.id,
            startMs: clipA.startMs,
            durMs: clipA.durMs,
            bytes: clipA.bytes,
            locked: clipA.locked,
            etag: "1-2",
            timeApproximate: clipA.timeApproximate
        )

        store.send(.clips(.clipFinalized(updatedClipA)))

        #expect(probe.prefetchCancelCount(clipA) == 1)
        #expect(probe.prefetchCancelCount(clipB) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func telemetryDeltaDoesNotChurnTheClipList() async throws {
        let probe = HomeLoaderProbe()
        let world = CameraSamples.world(tempC: TempC(soc: 39, sensor: 40))
        let (controller, store) = makeControllerAndStore(
            clips: [clipA, clipB],
            loader: probe.loader(),
            world: world
        )
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])
        store.send(.event(.tempChanged(soc: 40, sensor: 41)))

        #expect(probe.prefetchCancelCount(clipA) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func viewWillDisappearCancelsEveryOutstandingHandle() async throws {
        let probe = HomeLoaderProbe()
        let controller = makeController(clips: [clipA, clipB], loader: probe.loader())
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [
            IndexPath(row: 0, section: 0),
            IndexPath(row: 1, section: 0),
        ])
        controller.viewWillDisappear(false)

        #expect(probe.prefetchCancelCount(clipA) == 1)
        #expect(probe.prefetchCancelCount(clipB) == 1)
    }

    // MARK: Offscreen quieting of strong cell loads

    @Test(.timeLimit(.minutes(1)))
    func viewWillDisappearQuietsVisibleCellLoads() async throws {
        let probe = HomeLoaderProbe()
        let controller = makeController(clips: [clipA, clipB], loader: probe.loader())
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil { probe.thumbnailCallCount() >= 1 }  // a visible cell began loading
        controller.viewWillDisappear(false)
        try await waitUntil { probe.thumbnailCancelCount() >= 1 }  // that load observed cancellation
    }

    @Test(.timeLimit(.minutes(1)))
    func didEndDisplayingQuietsTheDepartingCellLoad() async throws {
        let probe = HomeLoaderProbe()
        let controller = makeController(clips: [clipA], loader: probe.loader())
        controller.loadViewIfNeeded()

        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "clipThumbnail")
        cell.configure(clip: clipA, loader: probe.loader())
        try await waitUntil { probe.thumbnailCallCount() >= 1 }

        controller.tableView(UITableView(), didEndDisplaying: cell, forRowAt: IndexPath(row: 0, section: 0))
        try await waitUntil { probe.thumbnailCancelCount() >= 1 }
    }

    @Test(.timeLimit(.minutes(1)))
    func aClipsUpdateReconfiguresChangedRowsWithoutReloadingSurvivors() async throws {
        let loader = GatedThumbnailLoader()
        let (controller, store) = makeControllerAndStore(clips: [clipA, clipB], loader: loader.loader())
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id)?.displayedImageForTesting != nil &&
                controller.clipThumbnailCellForTesting(clipID: self.clipB.id)?.displayedImageForTesting != nil
        }

        let cellA = try #require(controller.clipThumbnailCellForTesting(clipID: clipA.id))
        let cellB = try #require(controller.clipThumbnailCellForTesting(clipID: clipB.id))
        let originalA = try #require(cellA.displayedImageForTesting)
        let originalLabelA = try #require(cellA.accessibilityLabel)
        let originalB = try #require(cellB.displayedImageForTesting)
        let relabeledClipA = Clip(
            id: clipA.id,
            startMs: clipA.startMs,
            durMs: 45_000,
            bytes: clipA.bytes,
            locked: clipA.locked,
            etag: clipA.etag,
            timeApproximate: clipA.timeApproximate
        )

        store.send(.clips(.clipsResponse(epoch: 0, .success(ClipsResponse(
            clips: [clipC, relabeledClipA, clipB],
            serverTimeMs: 0,
            nextCursor: nil
        )))))

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id)?.accessibilityLabel != originalLabelA
        }

        let updatedCellA = try #require(controller.clipThumbnailCellForTesting(clipID: clipA.id))
        let updatedImageA = try #require(updatedCellA.displayedImageForTesting)
        let survivorCellB = try #require(controller.clipThumbnailCellForTesting(clipID: clipB.id))
        let survivorImageB = try #require(survivorCellB.displayedImageForTesting)

        #expect(updatedImageA === originalA)
        #expect(updatedCellA.isLoadingForTesting == false)
        #expect(survivorImageB === originalB)
        #expect(survivorCellB.isLoadingForTesting == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func trustedTimestampUpdateReconfiguresRowWithoutReloadingThumbnail() async throws {
        let loader = GatedThumbnailLoader()
        let initialClip = Clip(
            id: clipA.id,
            startMs: nil,
            durMs: clipA.durMs,
            bytes: clipA.bytes,
            locked: clipA.locked,
            etag: clipA.etag,
            timeApproximate: true
        )
        let (controller, store) = makeControllerAndStore(clips: [initialClip], loader: loader.loader())
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id)?.displayedImageForTesting != nil
        }

        let cell = try #require(controller.clipThumbnailCellForTesting(clipID: clipA.id))
        let originalImage = try #require(cell.displayedImageForTesting)
        let originalSubtitle = try #require(cell.subtitleTextForTesting)
        let trustedClip = Clip(
            id: initialClip.id,
            startMs: 1_767_225_600_000,
            durMs: initialClip.durMs,
            bytes: initialClip.bytes,
            locked: initialClip.locked,
            etag: initialClip.etag,
            timeApproximate: false
        )

        store.send(.clips(.clipsResponse(epoch: 0, .success(ClipsResponse(
            clips: [trustedClip],
            serverTimeMs: 1_767_225_601_000,
            nextCursor: nil
        )))))

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id)?.subtitleTextForTesting != originalSubtitle
        }

        let updatedCell = try #require(controller.clipThumbnailCellForTesting(clipID: clipA.id))
        let updatedImage = try #require(updatedCell.displayedImageForTesting)
        let updatedSubtitle = try #require(updatedCell.subtitleTextForTesting)

        #expect(updatedImage === originalImage)
        #expect(updatedCell.isLoadingForTesting == false)
        #expect(loader.requestCount(ClipThumbnailIdentity(trustedClip)) == 1)
        #expect(updatedSubtitle.contains("00:30"))
    }

    @Test(.timeLimit(.minutes(1)))
    func clipRemovedRemovesFinishedRow() async throws {
        let (controller, store) = makeControllerAndStore(clips: [clipA, clipB], loader: .noop)
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id) != nil
        }

        store.send(.clips(.clipRemoved(id: clipA.id)))

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id) == nil
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func performDeleteForTestingRoutesToClipsClientAndRemovesRow() async throws {
        let deleteSpy = HomeDeleteSpy()
        let (controller, _) = makeControllerAndStore(
            clips: [clipA],
            loader: .noop,
            clipsClient: deleteSpy.client()
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id) != nil
        }
        controller.performDeleteForTesting(clipID: clipA.id)

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: self.clipA.id) == nil
        }
        for _ in 0..<200 {
            if await deleteSpy.deletedIDs() == [clipA.id] {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for clip delete.")
    }

    @Test func timeUnverifiedPillVisibilityFollowsProjection() {
        let disconnected = makeController(clips: [], loader: .noop)
        disconnected.loadViewIfNeeded()
        #expect(disconnected.isTimeUnverifiedPillVisibleForTesting == false)

        let nilTime = makeController(clips: [], loader: .noop, world: CameraSamples.world(time: nil))
        nilTime.loadViewIfNeeded()
        #expect(nilTime.isTimeUnverifiedPillVisibleForTesting == true)

        let unsynced = makeController(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(time: TimeStatus(synced: false))
        )
        unsynced.loadViewIfNeeded()
        #expect(unsynced.isTimeUnverifiedPillVisibleForTesting == true)

        let synced = makeController(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(time: TimeStatus(synced: true))
        )
        synced.loadViewIfNeeded()
        #expect(synced.isTimeUnverifiedPillVisibleForTesting == false)
    }

    @Test func recordButtonPresentationFollowsRecordingState() {
        let (controller, store) = makeControllerAndStore(clips: [], loader: .noop)
        controller.loadViewIfNeeded()

        store.send(.recording(.recorderPhaseObserved(.idle)))

        #expect(controller.recordButtonForTesting.configuration?.title == "Record")
        #expect(controller.recordButtonForTesting.isEnabled)
        #expect(controller.recordButtonForTesting.accessibilityLabel == "Start recording")
        #expect(controller.recordButtonForTesting.configuration?.image != nil)

        store.send(.recording(.recorderPhaseObserved(.starting)))

        #expect(controller.recordButtonForTesting.configuration?.title == "Starting")
        #expect(controller.recordButtonForTesting.isEnabled == false)
        #expect(controller.recordButtonForTesting.accessibilityLabel == "Starting recording")
        #expect(controller.recordButtonForTesting.configuration?.image != nil)

        store.send(.recording(.recorderPhaseObserved(.recording)))

        #expect(controller.recordButtonForTesting.configuration?.title == "Stop")
        #expect(controller.recordButtonForTesting.isEnabled)
        #expect(controller.recordButtonForTesting.accessibilityLabel == "Stop recording")
        #expect(controller.recordButtonForTesting.configuration?.image != nil)
    }

    @Test func recordButtonLivesBelowPreviewNotInToolbar() throws {
        let controller = makeController(clips: [], loader: .noop)
        let (window, navigationController) = try embedInNavigationController(controller)
        defer { window.isHidden = true }

        #expect(controller.recordButtonForTesting.isDescendant(of: controller.view))
        #expect(navigationController.isToolbarHidden == true)
    }

    @Test func manualRefreshSpinnerStaysUntilClipsReachTerminalStatus() throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            clipsClient: parkedClipsClient()
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.pullToRefreshForTesting()

        #expect(controller.isRefreshingForTesting)
        #expect(controller.isManualRefreshingForTesting)

        store.send(.clips(.clipsResponse(epoch: 1, .failure(.transport("No route")))))

        #expect(controller.isRefreshingForTesting == false)
        #expect(controller.isManualRefreshingForTesting == false)

        controller.viewWillDisappear(false)
    }

    @Test func manualRefreshSpinnerEndsWhenHomeDisappears() throws {
        let controller = makeController(
            clips: [],
            loader: .noop,
            clipsClient: parkedClipsClient()
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.pullToRefreshForTesting()
        controller.viewWillDisappear(false)

        #expect(controller.isRefreshingForTesting == false)
        #expect(controller.isManualRefreshingForTesting == false)
    }

    @Test func clipsBodyPlaceholderFollowsLoadingEmptyRefreshAndRows() throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            clipsClient: parkedClipsClient()
        )
        let window = try embed(controller)
        defer {
            controller.viewWillDisappear(false)
            window.isHidden = true
        }

        store.send(.clips(.load))

        #expect(controller.isShowingLoadingStateForTesting)
        #expect(controller.isShowingEmptyStateForTesting == false)

        store.send(.clips(.clipsResponse(epoch: 1, .success(ClipsResponse(
            clips: [],
            serverTimeMs: nil,
            nextCursor: nil
        )))))

        #expect(controller.isShowingEmptyStateForTesting)
        #expect(controller.isShowingLoadingStateForTesting == false)

        store.send(.clips(.refresh))

        #expect(controller.isShowingEmptyStateForTesting)
        #expect(controller.isShowingLoadingStateForTesting == false)

        store.send(.clips(.clipsResponse(epoch: 2, .success(ClipsResponse(
            clips: [clipA],
            serverTimeMs: nil,
            nextCursor: nil
        )))))

        #expect(controller.isShowingEmptyStateForTesting == false)
        #expect(controller.isShowingLoadingStateForTesting == false)
    }

    @Test func clipsFailurePresentationIsVisibleAndSuppressesEmptyState() {
        let (staleController, staleStore) = makeControllerAndStore(clips: [clipA], loader: .noop)
        staleController.loadViewIfNeeded()

        staleStore.send(.clips(.clipsResponse(epoch: 0, .failure(.transport("No route")))))

        #expect(staleController.clipsFailureMessageForTesting == "Transport error: No route")
        #expect(staleController.isShowingEmptyStateForTesting == false)

        staleStore.send(.clips(.clipsResponse(epoch: 0, .success(ClipsResponse(
            clips: [],
            serverTimeMs: 0,
            nextCursor: nil
        )))))

        #expect(staleController.clipsFailureMessageForTesting == nil)
        #expect(staleController.isShowingEmptyStateForTesting)

        let (emptyController, emptyStore) = makeControllerAndStore(clips: [], loader: .noop)
        emptyController.loadViewIfNeeded()
        #expect(emptyController.isShowingEmptyStateForTesting == false)

        emptyStore.send(.clips(.clipsResponse(epoch: 0, .failure(.transport("No route")))))

        #expect(emptyController.clipsFailureMessageForTesting == "Transport error: No route")
        #expect(emptyController.isShowingEmptyStateForTesting == false)
    }

    // MARK: - Helpers

    private let clipA = Clip(id: 1, startMs: nil, durMs: 30_000, bytes: 1, locked: false, etag: "1-1", timeApproximate: false)
    private let clipB = Clip(id: 2, startMs: nil, durMs: 30_000, bytes: 2, locked: false, etag: "2-2", timeApproximate: false)
    private let clipC = Clip(id: 3, startMs: nil, durMs: 30_000, bytes: 3, locked: false, etag: "3-3", timeApproximate: false)

    private func makeController(
        clips: [Clip],
        loader: ThumbnailLoader,
        world: World? = nil,
        clipsClient: ClipsClient = .noop,
        preview: PreviewClient = .noop
    ) -> HomeViewController {
        makeControllerAndStore(
            clips: clips,
            loader: loader,
            world: world,
            clipsClient: clipsClient,
            preview: preview
        ).0
    }

    private func makeControllerAndStore(
        clips: [Clip],
        loader: ThumbnailLoader,
        world: World? = nil,
        clipsClient: ClipsClient = .noop,
        preview: PreviewClient = .noop
    ) -> (HomeViewController, AppStore) {
        var state = AppFeature.State()
        state.clips.clips = clips
        if let world {
            state.link = .online(world)
        }
        let dependencies = AppDependencies(
            health: HealthClient(fetch: { fatalError("Health is not used by HomeViewControllerTests.") }),
            clips: clipsClient,
            thumbnailLoader: loader,
            preview: preview,
            heartbeatTimeout: { throw CancellationError() }
        )
        let store = AppStore(initialState: state, dependencies: dependencies, reduce: AppFeature.reduce)
        return (HomeViewController(dependencies: dependencies, store: store), store)
    }

    private func parkedClipsClient() -> ClipsClient {
        ClipsClient { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    private func embed(_ controller: UIViewController) throws -> UIWindow {
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func embedInNavigationController(_ controller: UIViewController) throws -> (UIWindow, UINavigationController) {
        let navigationController = UINavigationController(rootViewController: controller)
        let window = try embed(navigationController)
        return (window, navigationController)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
    }
}

private actor HomeDeleteSpy {
    private var ids: [Int] = []

    nonisolated func client() -> ClipsClient {
        ClipsClient(
            fetch: { _ in ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil) },
            delete: { id in await self.record(id) }
        )
    }

    func deletedIDs() -> [Int] {
        ids
    }

    private func record(_ id: Int) {
        ids.append(id)
    }
}

/// A `ThumbnailLoader` fake for controller tests: `prefetch` returns a handle whose
/// `cancel()` records against the clip's `(id, etag)` key; `thumbnail` parks and records
/// observed cancellation. Both are asserted behaviorally -- the tests never reach into the
/// controller's private handle map.
private final class HomeLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var prefetchCancels: [String: Int] = [:]
    private var thumbnailCalls = 0
    private var thumbnailCancels = 0
    private let thumbnailSignal = AsyncSignal()

    func loader() -> ThumbnailLoader {
        ThumbnailLoader(
            thumbnail: { [self] _ in
                noteThumbnailCall()
                await withTaskCancellationHandler {
                    await thumbnailSignal.wait()
                } onCancel: {
                    noteThumbnailCancel()
                }
                return nil
            },
            prefetch: { [self] clip in
                let key = key(clip)
                return ThumbnailLoader.PrefetchHandle { self.notePrefetchCancel(key) }
            }
        )
    }

    func prefetchCancelCount(_ clip: Clip) -> Int {
        lock.lock(); defer { lock.unlock() }
        return prefetchCancels[key(clip)] ?? 0
    }

    func thumbnailCallCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return thumbnailCalls
    }

    func thumbnailCancelCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return thumbnailCancels
    }

    private func key(_ clip: Clip) -> String {
        "\(clip.id)-\(clip.etag)"
    }

    private func notePrefetchCancel(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        prefetchCancels[key, default: 0] += 1
    }

    private func noteThumbnailCall() {
        lock.lock(); defer { lock.unlock() }
        thumbnailCalls += 1
    }

    private func noteThumbnailCancel() {
        lock.lock(); defer { lock.unlock() }
        thumbnailCancels += 1
    }
}

private final class GatedThumbnailLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let parked = AsyncSignal()
    private var requestCounts: [ClipThumbnailIdentity: Int] = [:]

    func loader() -> ThumbnailLoader {
        ThumbnailLoader(
            thumbnail: { [self] clip in
                let identity = ClipThumbnailIdentity(clip)
                if let image = firstImageOrNil(for: identity) {
                    return ThumbnailImage(image: image)
                }

                await parked.wait()
                return nil
            },
            prefetch: { _ in .inert }
        )
    }

    func requestCount(_ identity: ClipThumbnailIdentity) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCounts[identity] ?? 0
    }

    private func firstImageOrNil(for identity: ClipThumbnailIdentity) -> UIImage? {
        lock.lock(); defer { lock.unlock() }

        let count = requestCounts[identity, default: 0] + 1
        requestCounts[identity] = count
        guard count == 1 else { return nil }

        return image(for: identity)
    }

    private func image(for identity: ClipThumbnailIdentity) -> UIImage {
        let hue = CGFloat(abs(identity.hashValue % 256)) / 255
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
