import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct RecordingDetailViewControllerTests {
    private let target = RecordingID(bootTag: "target", session: 7)

    @Test func rendersOnlyTheTargetRecording() {
        let controller = makeController(clips: [
            clip(id: 12, bootTag: "target"),
            clip(id: 11, bootTag: "other"),
            clip(id: 10, bootTag: "target"),
            clip(id: 9, bootTag: nil),
        ])

        controller.loadViewIfNeeded()

        #expect(controller.clipIDsForTesting() == [12, 10])
    }

    @Test func titleUsesFullRecordingSpanAndUndatedFallback() {
        let newestStart = UInt64(1_767_231_420_000)
        let oldestStart = UInt64(1_767_225_720_000)
        let datedController = makeController(clips: [
            clip(id: 12, bootTag: "target", startMs: newestStart),
            clip(id: 10, bootTag: "target", startMs: oldestStart),
        ])

        datedController.loadViewIfNeeded()

        #expect(datedController.title == Formatters.recordingCardTitle(
            start: Date(timeIntervalSince1970: Double(oldestStart) / 1_000),
            end: Date(timeIntervalSince1970: Double(newestStart) / 1_000)
        ))

        let undatedController = makeController(clips: [
            clip(id: 12, bootTag: "target"),
        ])

        undatedController.loadViewIfNeeded()

        #expect(undatedController.title == "Recording")
    }

    @Test func prefetchAndCancelRoutesThroughThumbnailLoader() throws {
        let probe = RecordingLoaderProbe()
        let controller = makeController(
            clips: [clip(id: 12, bootTag: "target")],
            thumbnailLoader: probe.loader()
        )
        controller.loadViewIfNeeded()
        let indexPath = try #require(controller.indexPathForTesting(clipID: 12))

        controller.tableView(UITableView(), prefetchRowsAt: [indexPath])

        #expect(probe.prefetchedIDs() == [12])

        controller.tableView(UITableView(), cancelPrefetchingForRowsAt: [indexPath])

        #expect(probe.cancelCount(clipID: 12) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func tappingClipPushesViewer() async throws {
        let controller = makeController(clips: [clip(id: 12, bootTag: "target")])
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        let indexPath = try #require(controller.indexPathForTesting(clipID: 12))
        controller.tableView(UITableView(), didSelectRowAt: indexPath)

        try await waitUntil {
            navigationController.topViewController is ClipViewerViewController
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func swipeDeleteConfigurationAndConfirmedDeleteSendDeleteTapped() async throws {
        let deleteSpy = RecordingDeleteSpy()
        let controller = makeController(
            clips: [clip(id: 12, bootTag: "target")],
            clipsClient: deleteSpy.client()
        )
        controller.loadViewIfNeeded()

        let indexPath = try #require(controller.indexPathForTesting(clipID: 12))
        let configuration = try #require(controller.tableView(
            UITableView(),
            trailingSwipeActionsConfigurationForRowAt: indexPath
        ))
        #expect(configuration.actions.map(\.title) == ["Delete"])

        controller.performDeleteForTesting(clipID: 12)

        try await waitUntil {
            await deleteSpy.deletedIDs() == [12]
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func tailWillDisplayLoadsMoreOnlyWhenRecordingCanLoadMore() async throws {
        let blockedSpy = RecordingFetchSpy()
        let blockedController = makeController(
            clips: [
                clip(id: 12, bootTag: "target"),
                clip(id: 1, bootTag: "other"),
            ],
            clipsClient: blockedSpy.client(),
            nextCursor: "1"
        )
        blockedController.loadViewIfNeeded()
        let blockedTail = try #require(blockedController.indexPathForTesting(clipID: 12))

        blockedController.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: blockedTail)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await blockedSpy.requestedCursors() == [])

        let fetchSpy = RecordingFetchSpy()
        let loadingController = makeController(
            clips: [
                clip(id: 12, bootTag: "target"),
                clip(id: 11, bootTag: nil),
            ],
            clipsClient: fetchSpy.client(),
            nextCursor: "11"
        )
        loadingController.loadViewIfNeeded()
        let loadingTail = try #require(loadingController.indexPathForTesting(clipID: 12))

        loadingController.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: loadingTail)

        try await waitForCursors(fetchSpy, [Optional("11")])
    }

    @Test(.timeLimit(.minutes(1)))
    func nilOnlyPageAdvancesFrontierAndTriggersTheNextLoad() async throws {
        let fetchSpy = RecordingFetchSpy(responses: [
            ClipsResponse(
                clips: [clip(id: 11, bootTag: nil)],
                serverTimeMs: nil,
                nextCursor: "11"
            ),
            ClipsResponse(
                clips: [clip(id: 10, bootTag: "target")],
                serverTimeMs: nil,
                nextCursor: nil
            ),
        ])
        let controller = makeController(
            clips: [clip(id: 12, bootTag: "target")],
            clipsClient: fetchSpy.client(),
            nextCursor: "12"
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.layoutTableForTesting()
            return controller.clipThumbnailCellForTesting(clipID: 12) != nil
        }

        try await waitForCursors(fetchSpy, [Optional("12"), Optional("11")])
        try await waitUntil {
            controller.clipIDsForTesting() == [12, 10]
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyButNotExhaustedKeepsControllerAndLoadsMore() async throws {
        let fetchSpy = ParkedRecordingFetchSpy()
        defer {
            Task {
                await fetchSpy.releaseFetches()
            }
        }
        let (controller, store) = makeControllerAndStore(
            clips: [
                clip(id: 12, bootTag: "target"),
                clip(id: 11, bootTag: nil),
            ],
            clipsClient: fetchSpy.client(),
            nextCursor: "11"
        )
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        store.send(.clips(.clipRemoved(id: 12)))

        try await waitForCursors(fetchSpy, [Optional("11")])
        #expect(navigationController.viewControllers.contains(controller))
        await fetchSpy.releaseFetches()
    }

    @Test(.timeLimit(.minutes(1)))
    func exhaustedEmptyRecordingPopsWhenTopmost() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [clip(id: 12, bootTag: "target")],
            nextCursor: nil
        )
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        store.send(.clips(.clipRemoved(id: 12)))

        try await waitUntil {
            navigationController.viewControllers.contains(controller) == false
        }
        #expect(navigationController.topViewController === root)
    }

    @Test(.timeLimit(.minutes(1)))
    func exhaustedEmptyRecordingSplicesOutWhenNotTopmost() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [clip(id: 12, bootTag: "target")],
            nextCursor: nil
        )
        let root = UIViewController()
        let above = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(controller, animated: false)
        navigationController.pushViewController(above, animated: false)
        controller.loadViewIfNeeded()

        store.send(.clips(.clipRemoved(id: 12)))

        try await waitUntil {
            navigationController.viewControllers == [root, above]
        }
        #expect(navigationController.topViewController === above)
    }

    @Test(.timeLimit(.minutes(1)))
    func finalizedClipForRecordingAppearsAsNewTopRow() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [clip(id: 12, bootTag: "target")],
            nextCursor: nil
        )
        controller.loadViewIfNeeded()

        store.send(.clips(.clipFinalized(clip(id: 13, bootTag: "target"))))

        try await waitUntil {
            controller.clipIDsForTesting() == [13, 12]
        }
    }

    // MARK: Live recording row

    @Test(.timeLimit(.minutes(1)))
    func currentRecordingShowsLiveRowAtTop() async throws {
        let controller = makeController(
            clips: [clip(id: 10, bootTag: "target")],
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: 107_000),
                bootTag: "target"
            ),
            recording: .recording
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let cell = try await liveCell(in: controller)
        #expect(controller.isShowingLiveRowForTesting)
        #expect(cell.statusViewForTesting.titleTextForTesting == "seg_00024.ts")
        #expect(colorMatches(cell.statusViewForTesting.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(controller.indexPathForTesting(clipID: 10) == IndexPath(row: 1, section: 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func otherRecordingShowsNoLiveRow() async throws {
        let controller = makeController(
            clips: [clip(id: 10, bootTag: "target")],
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: 107_000),
                bootTag: "other"
            ),
            recording: .recording
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.layoutTableForTesting()
            return controller.clipThumbnailCellForTesting(clipID: 10) != nil
        }

        #expect(controller.isShowingLiveRowForTesting == false)
        #expect(controller.liveRecordingCellForTesting() == nil)
        #expect(controller.indexPathForTesting(clipID: 10) == IndexPath(row: 0, section: 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func olderSessionOfRecordingBootShowsNoLiveRow() async throws {
        // Detail is scoped to an older session (1) of a boot the recorder is now recording into
        // under a newer session (7). Same boot, different session -> no live row.
        let controller = makeController(
            clips: [clip(id: 10, bootTag: "target", session: 1)],
            recordingID: RecordingID(bootTag: "target", session: 1),
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: 107_000),
                bootTag: "target"
            ),
            recording: .recording
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.layoutTableForTesting()
            return controller.clipThumbnailCellForTesting(clipID: 10) != nil
        }

        #expect(controller.isShowingLiveRowForTesting == false)
        #expect(controller.liveRecordingCellForTesting() == nil)
        #expect(controller.indexPathForTesting(clipID: 10) == IndexPath(row: 0, section: 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func liveRowFreezesWhenLinkDropsAndThawsOnReconnect() async throws {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000),
            bootTag: "target"
        )
        let (controller, store) = makeControllerAndStore(
            clips: [clip(id: 10, bootTag: "target")],
            clipsClient: parkedClipsClient(),
            world: world,
            recording: .recording
        )
        let window = try embed(controller)
        defer {
            store.send(.clips(.onDisappear))
            window.isHidden = true
        }

        let cell = try await liveCell(in: controller)
        #expect(colorMatches(cell.statusViewForTesting.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(cell.statusViewForTesting.elapsedTextForTesting?.hasPrefix("~") == false)

        store.send(.heartbeatTimedOut)

        try await waitUntil {
            guard let view = controller.liveRecordingCellForTesting()?.statusViewForTesting else { return false }
            return self.colorMatches(view.recBadgeForTesting.dotColorForTesting, .systemGray) &&
                view.elapsedTextForTesting?.hasPrefix("~") == true
        }
        #expect(controller.liveRecordingCellForTesting() === cell)

        store.send(.event(.snapshot(world)))

        try await waitUntil {
            guard let view = controller.liveRecordingCellForTesting()?.statusViewForTesting else { return false }
            return self.colorMatches(view.recBadgeForTesting.dotColorForTesting, .systemRed) &&
                view.elapsedTextForTesting?.hasPrefix("~") == false
        }
        #expect(controller.liveRecordingCellForTesting() === cell)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingRowShowsForCurrentBootBeforeFirstSegment() async throws {
        let controller = makeController(
            clips: [],
            world: CameraSamples.world(phase: .starting, currentSegment: nil, bootTag: "target"),
            recording: .starting
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let cell = try await liveCell(in: controller)
        #expect(controller.isShowingLiveRowForTesting)
        #expect(cell.statusViewForTesting.titleTextForTesting == "Starting...")
        #expect(cell.statusViewForTesting.elapsedTextForTesting == "00:00")
        #expect(colorMatches(cell.statusViewForTesting.recBadgeForTesting.dotColorForTesting, .systemRed))
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingToLiveReconfiguresTheStableLiveRow() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            world: CameraSamples.world(phase: .starting, currentSegment: nil, bootTag: "target"),
            recording: .starting
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let cell = try await liveCell(in: controller)
        #expect(cell.statusViewForTesting.titleTextForTesting == "Starting...")

        store.send(.event(.segmentOpened(session: 7, id: 43, atMs: 5_400)))

        try await waitUntil {
            controller.liveRecordingCellForTesting()?.statusViewForTesting.titleTextForTesting == "seg_00043.ts"
        }
        #expect(controller.liveRecordingCellForTesting() === cell)
    }

    @Test(.timeLimit(.minutes(1)))
    func segmentRollReconfiguresLiveRowTitleInPlace() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: 107_000),
                bootTag: "target"
            ),
            recording: .recording
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let cell = try await liveCell(in: controller)
        #expect(cell.statusViewForTesting.titleTextForTesting == "seg_00024.ts")

        store.send(.event(.segmentOpened(session: 7, id: 25, atMs: 137_000)))

        try await waitUntil {
            controller.liveRecordingCellForTesting()?.statusViewForTesting.titleTextForTesting == "seg_00025.ts"
        }
        #expect(controller.liveRecordingCellForTesting() === cell)
    }

    @Test(.timeLimit(.minutes(1)))
    func openingCurrentRecordingMidSegmentSeedsElapsedFromInitialLiveSegment() async throws {
        let seed = LiveSegment(
            sessionId: 7,
            id: 24,
            elapsed: .ticking(seedDurMs: 100_000, anchor: ContinuousClock().now)
        )
        let controller = makeController(
            clips: [],
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: nil),
                bootTag: "target"
            ),
            recording: .recording,
            initialLiveSegment: seed
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let cell = try await liveCell(in: controller)
        let elapsed = try #require(cell.statusViewForTesting.elapsedTextForTesting)
        #expect(elapsed != "00:00")
        #expect(elapsed.hasPrefix("01:"))
    }

    @Test(.timeLimit(.minutes(1)))
    func exhaustedEmptyRecordingStaysWhileRecordingIntoItThenPopsAfterStop() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            nextCursor: nil,
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: 107_000),
                bootTag: "target"
            ),
            recording: .recording
        )
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        #expect(controller.isShowingLiveRowForTesting)
        #expect(navigationController.viewControllers.contains(controller))

        store.send(.event(.recordingStopped(session: 7, atMs: 62_000)))

        try await waitUntil {
            navigationController.viewControllers.contains(controller) == false
        }
        #expect(navigationController.topViewController === root)
    }

    private func makeController(
        clips: [Clip],
        clipsClient: ClipsClient = .noop,
        nextCursor: String? = nil,
        thumbnailLoader: ThumbnailLoader = .noop,
        recordingID: RecordingID? = nil,
        world: World? = nil,
        recording: RecordingFeature.State = .unknown,
        initialLiveSegment: LiveSegment? = nil
    ) -> RecordingDetailViewController {
        makeControllerAndStore(
            clips: clips,
            clipsClient: clipsClient,
            nextCursor: nextCursor,
            thumbnailLoader: thumbnailLoader,
            recordingID: recordingID,
            world: world,
            recording: recording,
            initialLiveSegment: initialLiveSegment
        ).0
    }

    private func makeControllerAndStore(
        clips: [Clip],
        clipsClient: ClipsClient = .noop,
        nextCursor: String? = nil,
        thumbnailLoader: ThumbnailLoader = .noop,
        recordingID: RecordingID? = nil,
        world: World? = nil,
        recording: RecordingFeature.State = .unknown,
        initialLiveSegment: LiveSegment? = nil
    ) -> (RecordingDetailViewController, AppStore) {
        var state = AppFeature.State()
        state.clips.clips = clips
        state.clips.nextCursor = nextCursor
        state.recording = recording
        if let world {
            state.link = .online(world)
        }
        let dependencies = AppDependencies(
            clips: clipsClient,
            thumbnailLoader: thumbnailLoader,
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
            heartbeatTimeout: { throw CancellationError() }
        )
        let store = AppStore(initialState: state, dependencies: dependencies, reduce: AppFeature.reduce)
        return (
            RecordingDetailViewController(
                dependencies: dependencies,
                store: store,
                recordingID: recordingID ?? target,
                initialLiveSegment: initialLiveSegment
            ),
            store
        )
    }

    private func parkedClipsClient() -> ClipsClient {
        ClipsClient { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    private func liveCell(in controller: RecordingDetailViewController) async throws -> LiveRecordingCell {
        try await waitUntil {
            controller.layoutTableForTesting()
            return controller.liveRecordingCellForTesting() != nil
        }
        return try #require(controller.liveRecordingCellForTesting())
    }

    private func colorMatches(_ color: UIColor?, _ expected: UIColor) -> Bool {
        colorComponents(color) == colorComponents(expected)
    }

    private func colorComponents(_ color: UIColor?) -> [Int]? {
        guard let color else { return nil }

        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        return [red, green, blue, alpha].map { Int(($0 * 1_000).rounded()) }
    }

    private func clip(
        id: Int,
        bootTag: String?,
        startMs: UInt64? = nil,
        session: UInt64? = 7
    ) -> Clip {
        CameraSamples.clip(
            id: id,
            startMs: startMs,
            durMs: 30_000,
            timeApproximate: startMs == nil,
            bootTag: bootTag,
            session: bootTag == nil ? nil : session
        )
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

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
    }

    private func waitForCursors(_ spy: RecordingFetchSpy, _ expected: [String?]) async throws {
        try await waitUntil {
            await spy.requestedCursors() == expected
        }
    }

    private func waitForCursors(_ spy: ParkedRecordingFetchSpy, _ expected: [String?]) async throws {
        try await waitUntil {
            await spy.requestedCursors() == expected
        }
    }
}

private actor RecordingDeleteSpy {
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

private actor RecordingFetchSpy {
    private var cursors: [String?] = []
    private var responses: [ClipsResponse]

    init(responses: [ClipsResponse] = [
        ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil),
    ]) {
        self.responses = responses
    }

    nonisolated func client() -> ClipsClient {
        ClipsClient { cursor in
            await self.nextResponse(cursor: cursor)
        }
    }

    func requestedCursors() -> [String?] {
        cursors
    }

    private func nextResponse(cursor: String?) -> ClipsResponse {
        cursors.append(cursor)
        guard responses.isEmpty == false else {
            return ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil)
        }

        return responses.removeFirst()
    }
}

private actor ParkedRecordingFetchSpy {
    private var cursors: [String?] = []
    private let release = AsyncSignal()

    nonisolated func client() -> ClipsClient {
        ClipsClient { cursor in
            await self.record(cursor)
            await self.waitForRelease()
            throw CancellationError()
        }
    }

    func requestedCursors() -> [String?] {
        cursors
    }

    func releaseFetches() async {
        await release.signal()
    }

    private func record(_ cursor: String?) {
        cursors.append(cursor)
    }

    private func waitForRelease() async {
        await release.wait()
    }
}

private final class RecordingLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var prefetched: [Int] = []
    private var cancels: [Int: Int] = [:]

    func loader() -> ThumbnailLoader {
        ThumbnailLoader(
            thumbnail: { _ in nil },
            prefetch: { [self] clip in
                notePrefetch(clip.id)
                return ThumbnailLoader.PrefetchHandle { self.noteCancel(clip.id) }
            }
        )
    }

    func prefetchedIDs() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return prefetched
    }

    func cancelCount(clipID: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return cancels[clipID] ?? 0
    }

    private func notePrefetch(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        prefetched.append(id)
    }

    private func noteCancel(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        cancels[id, default: 0] += 1
    }
}
