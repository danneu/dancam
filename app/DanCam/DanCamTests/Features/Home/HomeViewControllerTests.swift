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
    func aClipsReloadCancelsEveryOutstandingHandle() async throws {
        let probe = HomeLoaderProbe()
        let (controller, store) = makeControllerAndStore(clips: [clipA, clipB], loader: probe.loader())
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [
            IndexPath(row: 0, section: 0),
            IndexPath(row: 1, section: 0),
        ])

        // A clips update drives a full renderRows() reload, which clears all handles.
        store.send(.clips(.clipFinalized(clipC)))

        #expect(probe.prefetchCancelCount(clipA) == 1)
        #expect(probe.prefetchCancelCount(clipB) == 1)
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
        let window = embed(controller)
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

    // MARK: - Helpers

    private let clipA = Clip(id: 1, startMs: nil, durMs: 30_000, bytes: 1, locked: false, etag: "1-1", timeApproximate: false)
    private let clipB = Clip(id: 2, startMs: nil, durMs: 30_000, bytes: 2, locked: false, etag: "2-2", timeApproximate: false)
    private let clipC = Clip(id: 3, startMs: nil, durMs: 30_000, bytes: 3, locked: false, etag: "3-3", timeApproximate: false)

    private func makeController(clips: [Clip], loader: ThumbnailLoader) -> HomeViewController {
        makeControllerAndStore(clips: clips, loader: loader).0
    }

    private func makeControllerAndStore(
        clips: [Clip],
        loader: ThumbnailLoader
    ) -> (HomeViewController, AppStore) {
        var state = AppFeature.State()
        state.clips.clips = clips
        let dependencies = AppDependencies(
            health: HealthClient(fetch: { fatalError("Health is not used by HomeViewControllerTests.") }),
            thumbnailLoader: loader,
            heartbeatTimeout: { throw CancellationError() }
        )
        let store = AppStore(initialState: state, dependencies: dependencies, reduce: AppFeature.reduce)
        return (HomeViewController(dependencies: dependencies, store: store), store)
    }

    private func embed(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
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
