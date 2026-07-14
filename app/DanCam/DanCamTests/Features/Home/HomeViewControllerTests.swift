import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct HomeViewControllerTests {
    @Test func loadingHomePreservesSceneOwnedTabTitle() {
        let controller = makeController(clips: [], loader: .noop)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.tabBarItem = UITabBarItem(
            title: "Home",
            image: UIImage(systemName: "house"),
            tag: 0
        )

        controller.loadViewIfNeeded()

        #expect(navigationController.tabBarItem.title == "Home")
        #expect(controller.navigationItem.title == "DanCam")
    }

    // MARK: Prefetch glue (observable cancels)

    @Test(.timeLimit(.minutes(1)))
    func prefetchCancelsTheReplacedHandleBeforeStoringANewOne() async throws {
        let probe = HomeLoaderProbe()
        let controller = makeController(clips: [clipA, clipB], loader: probe.loader())
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])
        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])

        #expect(probe.prefetchCancelCount(clipA) == 1)  // the first handle was cancelled before replace
    }

    @Test(.timeLimit(.minutes(1)))
    func recordingCardUsesOnlyRepresentativeThumbnailForDisplayAndPrefetch() async throws {
        let probe = HomeLoaderProbe()
        let oldest = recordingClip(id: 1, bootTag: "boot-a")
        let middle = recordingClip(id: 2, bootTag: "boot-a")
        let newest = recordingClip(id: 3, bootTag: "boot-a")
        let (controller, store) = makeControllerAndStore(
            clips: [newest, middle, oldest],
            loader: probe.loader()
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            probe.thumbnailIdentities() == [ClipThumbnailIdentity(oldest)]
        }

        let recordingIndexPath = try #require(controller.indexPathForTesting(rowID: .recording(recording: RecordingID(bootTag: "boot-a", session: 7), occurrence: 0)))
        controller.tableView(UITableView(), prefetchRowsAt: [recordingIndexPath])

        #expect(probe.prefetchIdentities() == [ClipThumbnailIdentity(oldest)])

        store.send(.clips(.clipFinalized(recordingClip(id: 4, bootTag: "boot-a"))))
        try await Task.sleep(for: .milliseconds(40))

        #expect(probe.thumbnailIdentities() == [ClipThumbnailIdentity(oldest)])
        #expect(probe.prefetchIdentities() == [ClipThumbnailIdentity(oldest)])
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

    @Test func rendersStickyDayHeadersForDatedClipSections() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        let now = try date(2026, 1, 3, hour: 12, calendar: calendar)
        let todayClip = datedClip(id: 10, start: try date(2026, 1, 3, hour: 11, calendar: calendar))
        let olderClip = datedClip(id: 9, start: try date(2026, 1, 1, hour: 10, calendar: calendar))
        let controller = makeController(
            clips: [todayClip, olderClip],
            loader: .noop,
            wallNow: { now },
            currentCalendar: { calendar }
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.layoutClipsTableForTesting()

        #expect(controller.sectionHeaderTitlesForTesting == ["Today", "Thursday, Jan 1"])
        let header = try #require(controller.dayHeaderViewForTesting(section: 0))
        #expect(header.titleTextForTesting == "Today")
    }

    @Test(.timeLimit(.minutes(1)))
    func paginationTriggersFromTailIDsAcrossSections() async throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        let now = try date(2026, 1, 3, hour: 12, calendar: calendar)
        let fetchSpy = HomeFetchSpy()
        let clips = [
            datedClip(id: 10, start: try date(2026, 1, 3, hour: 11, calendar: calendar)),
            datedClip(id: 9, start: try date(2026, 1, 3, hour: 10, calendar: calendar)),
            CameraSamples.clip(id: 8, durMs: 30_000, timeApproximate: true),
            datedClip(id: 7, start: try date(2026, 1, 2, hour: 9, calendar: calendar)),
            datedClip(id: 6, start: try date(2026, 1, 2, hour: 8, calendar: calendar)),
            datedClip(id: 5, start: try date(2026, 1, 1, hour: 7, calendar: calendar)),
        ]
        let controller = makeController(
            clips: clips,
            loader: .noop,
            clipsClient: fetchSpy.client(),
            nextCursor: "5",
            wallNow: { now },
            currentCalendar: { calendar }
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let firstIndexPath = try #require(controller.indexPathForTesting(rowID: .finished(10)))
        controller.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: firstIndexPath)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await fetchSpy.requestedCursors() == [])

        let lastIndexPath = try #require(controller.indexPathForTesting(rowID: .finished(5)))
        #expect(lastIndexPath.section != firstIndexPath.section)
        controller.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: lastIndexPath)

        try await waitForCursors(fetchSpy, [Optional("5")])
    }

    @Test(.timeLimit(.minutes(1)))
    func paginationTriggersFromTailRecordingRows() async throws {
        let fetchSpy = HomeFetchSpy()
        let controller = makeController(
            clips: [
                recordingClip(id: 10, bootTag: "boot-a"),
                recordingClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop,
            clipsClient: fetchSpy.client(),
            nextCursor: "8"
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let recordingIndexPath = try #require(controller.indexPathForTesting(rowID: .recording(recording: RecordingID(bootTag: "boot-a", session: 7), occurrence: 0)))
        controller.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: recordingIndexPath)

        try await waitForCursors(fetchSpy, [Optional("8")])
    }

    @Test(.timeLimit(.minutes(1)))
    func pageAbsorbedByVisibleBottomRecordingIssuesNextFetch() async throws {
        let fetchSpy = HomeFetchSpy(responses: [
            ClipsResponse(clips: [recordingClip(id: 8, bootTag: "boot-a")], serverTimeMs: nil, nextCursor: "7"),
            ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil),
        ])
        let controller = makeController(
            clips: [
                recordingClip(id: 10, bootTag: "boot-a"),
                recordingClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop,
            clipsClient: fetchSpy.client(),
            nextCursor: "8"
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let recordingIndexPath = try #require(controller.indexPathForTesting(rowID: .recording(recording: RecordingID(bootTag: "boot-a", session: 7), occurrence: 0)))
        controller.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: recordingIndexPath)

        try await waitForCursors(fetchSpy, [Optional("8"), Optional("7")])
    }

    @Test func tappingRecordingCardPushesRecordingDetail() throws {
        let controller = makeController(
            clips: [
                recordingClip(id: 10, bootTag: "boot-a"),
                recordingClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop
        )
        let (window, navigationController) = try embedInNavigationController(controller)
        defer { window.isHidden = true }

        let recordingIndexPath = try #require(controller.indexPathForTesting(rowID: .recording(recording: RecordingID(bootTag: "boot-a", session: 7), occurrence: 0)))
        controller.tableView(UITableView(), didSelectRowAt: recordingIndexPath)

        #expect(navigationController.topViewController is RecordingDetailViewController)
        #expect(navigationController.viewControllers.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func coveredUpdatesDeferUIKitAndPaginationUntilReattachment() async throws {
        let fetchSpy = HomeFetchSpy()
        let (controller, store) = makeControllerAndStore(
            clips: [clipA],
            loader: .noop,
            clipsClient: fetchSpy.client()
        )
        let (window, navigationController) = try embedInNavigationController(controller)
        defer { window.isHidden = true }
        #expect(controller.presentedRowIDsForTesting == [.finished(clipA.id)])

        let cover = UIViewController()
        navigationController.pushViewController(cover, animated: false)
        window.layoutIfNeeded()

        store.send(.clips(.clipFinalized(clipB)))
        store.send(.clips(.clipsResponse(
            epoch: 0,
            generation: 0,
            .success(ClipsResponse(clips: [clipB, clipA], serverTimeMs: nil, nextCursor: "1"))
        )))

        #expect(controller.rowIDsForTesting.contains(.finished(clipB.id)))
        #expect(controller.presentedRowIDsForTesting == [.finished(clipA.id)])
        #expect(store.state.clips.isPaging == false)

        let tail = try #require(controller.indexPathForTesting(rowID: .finished(clipA.id)))
        controller.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: tail)
        #expect(store.state.clips.isPaging == false)
        #expect(await fetchSpy.requestedCursors().isEmpty)

        navigationController.popViewController(animated: false)
        window.layoutIfNeeded()
        controller.layoutClipsTableForTesting()

        try await waitUntil {
            controller.clipThumbnailCellForTesting(clipID: clipB.id) != nil
        }
        try await waitForCursors(fetchSpy, [Optional("1")])
    }

    @Test func recordingCardSwipeHasNoActions() throws {
        let controller = makeController(
            clips: [
                recordingClip(id: 10, bootTag: "boot-a"),
                recordingClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop
        )
        controller.loadViewIfNeeded()

        let recordingIndexPath = try #require(controller.indexPathForTesting(rowID: .recording(recording: RecordingID(bootTag: "boot-a", session: 7), occurrence: 0)))

        #expect(controller.tableView(
            UITableView(),
            trailingSwipeActionsConfigurationForRowAt: recordingIndexPath
        ) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func dayRolloverRefreshesVisibleHeaders() async throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        var now = try date(2026, 1, 3, hour: 23, minute: 59, calendar: calendar)
        let finishedClip = datedClip(id: 21, start: try date(2026, 1, 3, hour: 12, calendar: calendar))
        let controller = makeController(
            clips: [finishedClip],
            loader: .noop,
            wallNow: { now },
            currentCalendar: { calendar }
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.layoutClipsTableForTesting()
            return controller.sectionHeaderTitlesForTesting == ["Today"] &&
                controller.indexPathForTesting(rowID: .finished(finishedClip.id))?.section == 0
        }
        let todayHeader = try #require(controller.dayHeaderViewForTesting(section: 0))
        #expect(todayHeader.titleTextForTesting == "Today")

        now = try date(2026, 1, 4, hour: 0, minute: 1, calendar: calendar)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)

        try await waitUntil {
            controller.layoutClipsTableForTesting()
            return controller.sectionHeaderTitlesForTesting == ["Yesterday"] &&
                controller.indexPathForTesting(rowID: .finished(finishedClip.id))?.section == 0 &&
                controller.dayHeaderViewForTesting(section: 0)?.titleTextForTesting == "Yesterday"
        }
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
        let world = CameraSamples.world(tempC: TempC(
            soc: TempReading(current: 39),
            sensor: TempReading(current: 40)
        ))
        let (controller, store) = makeControllerAndStore(
            clips: [clipA, clipB],
            loader: probe.loader(),
            world: world
        )
        controller.loadViewIfNeeded()

        controller.tableView(UITableView(), prefetchRowsAt: [IndexPath(row: 0, section: 0)])
        store.send(.event(.tempChanged(TempC(
            soc: TempReading(current: 40),
            sensor: TempReading(current: 41)
        ))))

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

        store.send(.clips(.clipsResponse(epoch: 0, generation: 0, .success(ClipsResponse(
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

        store.send(.clips(.clipsResponse(epoch: 0, generation: 0, .success(ClipsResponse(
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

    @Test(.timeLimit(.minutes(1)))
    func liveRecordingWidgetFreezesOfflineAndThawsOnReconnectSnapshot() async throws {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000)
        )
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: world,
            recording: .recording
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.liveRecordingWidgetForTesting.isHidden == false &&
                controller.liveRecordingWidgetForTesting.titleTextForTesting == "seg_00024.ts"
        }

        let widget = controller.liveRecordingWidgetForTesting
        let initialElapsed = try #require(widget.elapsedTextForTesting)
        #expect(colorMatches(widget.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(initialElapsed.hasPrefix("~") == false)
        #expect(controller.isLiveRecordingWidgetTickTimerRunningForTesting)
        #expect(controller.recordButtonForTesting.configuration?.title == "Stop")
        #expect(controller.recordButtonForTesting.isEnabled)

        store.send(.heartbeatTimedOut)

        try await waitUntil {
            self.colorMatches(widget.recBadgeForTesting.dotColorForTesting, .systemGray) &&
                widget.elapsedTextForTesting?.hasPrefix("~") == true
        }

        let frozenElapsed = try #require(widget.elapsedTextForTesting)
        #expect(widget.accessibilityLabel?.hasPrefix("seg_00024.ts, last known recording, ~") == true)
        #expect(controller.isLiveRecordingWidgetTickTimerRunningForTesting == false)
        controller.tickLiveRecordingWidgetForTesting()
        #expect(widget.elapsedTextForTesting == frozenElapsed)
        #expect(controller.recordButtonForTesting.configuration?.title == "Record")
        #expect(controller.recordButtonForTesting.isEnabled == false)

        store.send(.event(.snapshot(world)))

        try await waitUntil {
            self.colorMatches(widget.recBadgeForTesting.dotColorForTesting, .systemRed) &&
                widget.elapsedTextForTesting?.hasPrefix("~") == false
        }

        #expect(controller.liveRecordingWidgetForTesting === widget)
        #expect(controller.isLiveRecordingWidgetTickTimerRunningForTesting)
        #expect(controller.recordButtonForTesting.configuration?.title == "Stop")
        #expect(controller.recordButtonForTesting.isEnabled)
    }

    @Test(.timeLimit(.minutes(1)))
    func recordingCardShowsRedPillAndClearsOnStop() async throws {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000),
            bootTag: "boot-a"
        )
        let (controller, store) = makeControllerAndStore(
            clips: [recordingClip(id: 10, bootTag: "boot-a")],
            loader: .noop,
            world: world,
            recording: .recording
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            guard let cell = controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "boot-a", session: 7)) else { return false }
            return cell.isRecordingPillVisibleForTesting &&
                self.colorMatches(cell.recordingPillForTesting.dotColorForTesting, .systemRed)
        }

        store.send(.event(.recordingStopped(session: 7, atMs: 62_000)))

        try await waitUntil {
            guard let cell = controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "boot-a", session: 7)) else { return false }
            return cell.isRecordingPillVisibleForTesting == false
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func recordingCardGraysWhenLinkDrops() async throws {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000),
            bootTag: "boot-a"
        )
        let (controller, store) = makeControllerAndStore(
            clips: [recordingClip(id: 10, bootTag: "boot-a")],
            loader: .noop,
            world: world,
            recording: .recording
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            guard let cell = controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "boot-a", session: 7)) else { return false }
            return self.colorMatches(cell.recordingPillForTesting.dotColorForTesting, .systemRed)
        }

        store.send(.heartbeatTimedOut)

        try await waitUntil {
            guard let cell = controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "boot-a", session: 7)) else { return false }
            return cell.isRecordingPillVisibleForTesting &&
                self.colorMatches(cell.recordingPillForTesting.dotColorForTesting, .systemGray)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reconnectSnapshotWithNewBootTagMarksOnlyNewRecordingCard() async throws {
        let oldWorld = CameraSamples.world(phase: .idle, currentSegment: nil, bootTag: "old-boot")
        let newWorld = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000),
            bootTag: "new-boot"
        )
        let (controller, store) = makeControllerAndStore(
            clips: [
                recordingClip(id: 11, bootTag: "new-boot"),
                recordingClip(id: 10, bootTag: "old-boot"),
            ],
            loader: .noop,
            world: oldWorld,
            recording: .idle,
            clipsClient: parkedClipsClient()
        )
        let window = try embed(controller)
        defer {
            store.send(.clips(.onDisappear))
            window.isHidden = true
        }

        try await waitUntil {
            controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "new-boot", session: 7)) != nil &&
                controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "old-boot", session: 7)) != nil
        }

        store.send(.event(.snapshot(newWorld)))

        try await waitUntil {
            guard let newCell = controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "new-boot", session: 7)),
                  let oldCell = controller.recordingThumbnailCellForTesting(recording: RecordingID(bootTag: "old-boot", session: 7)) else {
                return false
            }

            return newCell.isRecordingPillVisibleForTesting &&
                self.colorMatches(newCell.recordingPillForTesting.dotColorForTesting, .systemRed) &&
                oldCell.isRecordingPillVisibleForTesting == false
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func tappingRecordShowsPendingWidgetImmediatelyWithoutTickTimer() async throws {
        let releaseStart = AsyncSignal()
        let (controller, _) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(phase: .idle, currentSegment: nil),
            recording: .idle,
            recordingClient: RecordingClient(
                start: {
                    await releaseStart.wait()
                },
                stop: {}
            )
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.recordButtonForTesting.sendActions(for: .touchUpInside)

        try await waitUntil {
            controller.isShowingPendingWidgetForTesting
        }
        let widget = controller.liveRecordingWidgetForTesting
        #expect(widget.accessibilityLabel == "Starting recording")
        #expect(widget.elapsedTextForTesting == "00:00")
        #expect(colorMatches(widget.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(controller.isLiveRecordingWidgetTickTimerRunningForTesting == false)

        await releaseStart.signal()
        try await waitUntil {
            controller.recordButtonForTesting.configuration?.title == "Stop"
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func segmentOpenedReplacesPendingWithLiveWidget() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(phase: .idle, currentSegment: nil),
            recording: .idle
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.recordButtonForTesting.sendActions(for: .touchUpInside)
        try await waitUntil {
            controller.isShowingPendingWidgetForTesting
        }

        store.send(.event(.segmentOpened(session: 7, id: 43, atMs: 5_400)))

        try await waitUntil {
            controller.isShowingPendingWidgetForTesting == false &&
                controller.liveRecordingWidgetForTesting.titleTextForTesting == "seg_00043.ts"
        }
        #expect(controller.liveRecordingWidgetForTesting.isHidden == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedStartRemovesPendingWidgetSilently() async throws {
        let releaseStart = AsyncSignal()
        let (controller, _) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(phase: .idle, currentSegment: nil),
            recording: .idle,
            recordingClient: RecordingClient(
                start: {
                    await releaseStart.wait()
                    throw RecordingError.http(503)
                },
                stop: {}
            )
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.recordButtonForTesting.sendActions(for: .touchUpInside)
        try await waitUntil {
            controller.isShowingPendingWidgetForTesting
        }

        await releaseStart.signal()

        try await waitUntil {
            controller.isShowingPendingWidgetForTesting == false
        }
        #expect(controller.liveRecordingWidgetForTesting.isHidden)
        #expect(controller.clipsFailureMessageForTesting == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func recorderFailedEventClearsPendingViaProjection() async throws {
        let releaseStart = AsyncSignal()
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(phase: .idle, currentSegment: nil),
            recording: .idle,
            recordingClient: RecordingClient(
                start: {
                    await releaseStart.wait()
                    throw CancellationError()
                },
                stop: {}
            )
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.recordButtonForTesting.sendActions(for: .touchUpInside)
        try await waitUntil {
            controller.isShowingPendingWidgetForTesting
        }

        store.send(.event(.recorderFailed(session: 7, detail: "sensor lost", atMs: 1)))

        try await waitUntil {
            controller.isShowingPendingWidgetForTesting == false
        }
        #expect(controller.liveRecordingWidgetForTesting.isHidden)
        #expect(controller.recordButtonForTesting.isEnabled)

        await releaseStart.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func heartbeatTimeoutHidesPendingWidget() async throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(phase: .idle, currentSegment: nil),
            recording: .idle,
            recordingClient: RecordingClient(
                start: {
                    try await Task.sleep(for: .seconds(60))
                },
                stop: {}
            )
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.recordButtonForTesting.sendActions(for: .touchUpInside)
        try await waitUntil {
            controller.isShowingPendingWidgetForTesting
        }

        store.send(.heartbeatTimedOut)

        try await waitUntil {
            controller.isShowingPendingWidgetForTesting == false
        }
        store.send(.streamStopped)
    }

    @Test func configurePendingWidgetResetsGrayFrozenBadgeToRed() {
        let clock = ContinuousClock()
        let widget = LiveRecordingStatusView()
        let segment = LiveSegment(
            sessionId: 7,
            id: 43,
            elapsed: .frozen(durMs: 1_000)
        )

        widget.configure(status: .live(segment), now: clock.now)
        #expect(colorMatches(widget.recBadgeForTesting.dotColorForTesting, .systemGray))

        widget.configure(status: .pending, now: clock.now)

        #expect(colorMatches(widget.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(widget.elapsedTextForTesting == "00:00")
    }

    @Test func recordButtonLivesBelowPreviewNotInToolbar() throws {
        let controller = makeController(clips: [], loader: .noop)
        controller.loadViewIfNeeded()

        #expect(controller.isTableHeaderInstalledForTesting == false)

        let (window, navigationController) = try embedInNavigationController(controller)
        defer { window.isHidden = true }

        #expect(controller.isTableHeaderInstalledForTesting)
        #expect(controller.recordButtonForTesting.isDescendant(of: controller.view))
        #expect(controller.incidentButtonForTesting.isDescendant(of: controller.view))
        #expect(navigationController.isToolbarHidden == true)
    }

    @Test func incidentButtonFollowsCaptureEnablementAndFeedback() {
        let now = ContinuousClock().now
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 1_000),
            bootTag: "boot-a"
        )
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: world,
            recording: .recording,
            clipsClient: parkedClipsClient(),
            continuousNow: { now }
        )
        controller.loadViewIfNeeded()
        #expect(controller.incidentButtonForTesting.isEnabled == false)

        store.send(.event(.snapshot(world)))
        #expect(controller.incidentButtonForTesting.isEnabled)
        #expect(controller.incidentButtonForTesting.configuration?.title == "Save Incident")

        store.send(.incidents(.pressTapped))
        #expect(controller.incidentButtonForTesting.isEnabled == false)
        #expect(controller.incidentButtonForTesting.configuration?.title == "Saving... 17s")
    }

    @Test func incidentButtonPresentationScopesLockoutAndCreateToCurrentRecording() {
        let now = ContinuousClock().now
        let id = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let recordingID = RecordingID(bootTag: "boot", session: 7)
        let record = IncidentRecord(
            id: id,
            pressedAtMs: 1_784_480_523_000,
            recordingID: recordingID,
            markSeq: 43,
            markAgeMs: 12_000
        )
        var state = AppFeature.State()
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 43, durMs: 1_000),
            bootTag: "boot"
        )
        state.link = .online(world)
        state.incidents.hasLoadedStore = true
        state.incidents.openSegmentAnchor = .init(
            recordingID: recordingID,
            seq: 43,
            seedDurMs: 1_000,
            observedAt: now
        )
        state.incidents.incidents = [record]
        state.incidents.runtimeLockout = .init(
            recordingID: recordingID,
            deadline: now.advanced(by: .seconds(12))
        )

        #expect(IncidentButtonPresentation.from(state, now: now) == .armed(
            lockoutDeadline: now.advanced(by: .seconds(12)),
            createInFlight: false
        ))

        state.incidents.runtimeLockout = nil
        #expect(IncidentButtonPresentation.from(state, now: now) == .armed(
            lockoutDeadline: nil,
            createInFlight: false
        ))

        state.incidents.pendingRecords[recordingID] = record
        #expect(IncidentButtonPresentation.from(state, now: now) == .armed(
            lockoutDeadline: nil,
            createInFlight: true
        ))

        state.link = .offline(last: world)
        #expect(IncidentButtonPresentation.from(state, now: now) == .unavailable)
    }

    @Test func incidentButtonEnabledStateAndAccessibilityStayConsistent() {
        let now = ContinuousClock().now
        let button = IncidentButton(frame: .zero, continuousNow: { now })
        let presentations: [IncidentButtonPresentation] = [
            .armed(lockoutDeadline: now.advanced(by: .seconds(12)), createInFlight: false),
            .armed(lockoutDeadline: nil, createInFlight: false),
            .armed(lockoutDeadline: now, createInFlight: false),
            .armed(lockoutDeadline: nil, createInFlight: true),
            .unavailable,
        ]

        for (index, presentation) in presentations.enumerated() {
            button.apply(presentation, now: now)
            if button.isEnabled {
                #expect(button.configuration?.title == "Save Incident")
            }
            if index > 0 {
                #expect(button.accessibilityValue == nil)
            }
        }
    }

    @Test func incidentButtonTimerExpiresAndStopsWhenDetached() throws {
        let now = ContinuousClock().now
        let button = IncidentButton(
            frame: .zero,
            continuousNow: { now.advanced(by: .seconds(200)) }
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.addSubview(button)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        button.apply(
            .armed(lockoutDeadline: now.advanced(by: .seconds(100)), createInFlight: false),
            now: now
        )
        #expect(button.isTickTimerRunningForTesting)

        button.tickForTesting(now: now.advanced(by: .seconds(101)))
        #expect(button.isEnabled)
        #expect(button.isTickTimerRunningForTesting == false)

        button.apply(
            .armed(lockoutDeadline: now.advanced(by: .seconds(100)), createInFlight: false),
            now: now
        )
        button.removeFromSuperview()
        #expect(button.isTickTimerRunningForTesting == false)
    }

    @Test func incidentPersistenceFailureShowsCalmAlert() async throws {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 1_000),
            bootTag: "boot-a"
        )
        let failingStore = IncidentStore(
            list: { [] },
            create: { _ in throw CocoaError(.fileWriteOutOfSpace) },
            update: { _ in },
            delete: { _ in },
            deleteUnreadable: { _ in },
            directoryURL: { _ in URL(filePath: "/tmp") }
        )
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: world,
            recording: .recording,
            clipsClient: parkedClipsClient(),
            incidentStore: failingStore
        )
        let window = try embed(controller)
        defer { window.isHidden = true }
        store.send(.event(.snapshot(world)))

        controller.incidentButtonForTesting.sendActions(for: .touchUpInside)
        try await waitUntil { controller.presentedViewController is UIAlertController }

        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == "Could not save incident")
        #expect(alert.message?.contains("phone storage") == true)
    }

    @Test func manualRefreshSpinnerStaysUntilClipsReachTerminalStatus() throws {
        let (controller, store) = makeControllerAndStore(
            clips: [],
            loader: .noop,
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: nil)
            ),
            recording: .recording,
            clipsClient: parkedClipsClient()
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.pullToRefreshForTesting()

        #expect(controller.isRefreshingForTesting)
        #expect(controller.isManualRefreshingForTesting)

        store.send(.clips(.clipsResponse(epoch: 1, generation: 0, .failure(.transport(.connectTimedOut)))))

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
            world: CameraSamples.world(
                phase: .recording,
                currentSegment: RecorderSegment(id: 24, durMs: nil)
            ),
            recording: .recording,
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

        store.send(.clips(.clipsResponse(epoch: 1, generation: 0, .success(ClipsResponse(
            clips: [],
            serverTimeMs: nil,
            nextCursor: nil
        )))))

        #expect(controller.isShowingEmptyStateForTesting)
        #expect(controller.isShowingLoadingStateForTesting == false)
        #expect(controller.liveRecordingWidgetForTesting.isHidden == false)

        store.send(.clips(.refresh))

        #expect(controller.isShowingEmptyStateForTesting)
        #expect(controller.isShowingLoadingStateForTesting == false)

        store.send(.clips(.clipsResponse(epoch: 2, generation: 0, .success(ClipsResponse(
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

        staleStore.send(.clips(.clipsResponse(epoch: 0, generation: 0, .failure(.transport(.connectTimedOut)))))

        #expect(staleController.clipsFailureMessageForTesting == "Can't reach the camera (timed out).")
        #expect(staleController.isShowingEmptyStateForTesting == false)

        staleStore.send(.clips(.clipsResponse(epoch: 0, generation: 0, .success(ClipsResponse(
            clips: [],
            serverTimeMs: 0,
            nextCursor: nil
        )))))

        #expect(staleController.clipsFailureMessageForTesting == nil)
        #expect(staleController.isShowingEmptyStateForTesting)

        let (emptyController, emptyStore) = makeControllerAndStore(clips: [], loader: .noop)
        emptyController.loadViewIfNeeded()
        #expect(emptyController.isShowingEmptyStateForTesting == false)

        emptyStore.send(.clips(.clipsResponse(epoch: 0, generation: 0, .failure(.transport(.connectTimedOut)))))

        #expect(emptyController.clipsFailureMessageForTesting == "Can't reach the camera (timed out).")
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
        recording: RecordingFeature.State = .unknown,
        clipsClient: ClipsClient = .noop,
        nextCursor: String? = nil,
        preview: PreviewClient = .noop,
        recordingClient: RecordingClient = .noop,
        incidentStore: IncidentStore = .noop,
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        dependencyWallNow: @escaping @Sendable () -> Date = Date.init,
        wallNow: @escaping () -> Date = Date.init,
        currentCalendar: @escaping () -> Calendar = { .current }
    ) -> HomeViewController {
        makeControllerAndStore(
            clips: clips,
            loader: loader,
            world: world,
            recording: recording,
            clipsClient: clipsClient,
            nextCursor: nextCursor,
            preview: preview,
            recordingClient: recordingClient,
            incidentStore: incidentStore,
            continuousNow: continuousNow,
            dependencyWallNow: dependencyWallNow,
            wallNow: wallNow,
            currentCalendar: currentCalendar
        ).0
    }

    private func makeControllerAndStore(
        clips: [Clip],
        loader: ThumbnailLoader,
        world: World? = nil,
        recording: RecordingFeature.State = .unknown,
        clipsClient: ClipsClient = .noop,
        nextCursor: String? = nil,
        preview: PreviewClient = .noop,
        recordingClient: RecordingClient = .noop,
        incidentStore: IncidentStore = .noop,
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        dependencyWallNow: @escaping @Sendable () -> Date = Date.init,
        wallNow: @escaping () -> Date = Date.init,
        currentCalendar: @escaping () -> Calendar = { .current }
    ) -> (HomeViewController, AppStore) {
        var state = AppFeature.State()
        state.clips.clips = clips
        state.clips.nextCursor = nextCursor
        state.recording = recording
        state.incidents.hasLoadedStore = true
        if let world {
            state.link = .online(world)
        }
        let dependencies = AppDependencies(
            clips: clipsClient,
            incidentStore: incidentStore,
            thumbnailLoader: loader,
            preview: preview,
            recording: recordingClient,
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
            heartbeatTimeout: { throw CancellationError() },
            continuousNow: continuousNow,
            wallNow: dependencyWallNow
        )
        let store = AppStore(initialState: state, dependencies: dependencies, reduce: AppFeature.reduce)
        return (
            HomeViewController(
                dependencies: dependencies,
                store: store,
                wallNow: wallNow,
                currentCalendar: currentCalendar
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

    private func waitForCursors(_ spy: HomeFetchSpy, _ expected: [String?]) async throws {
        for _ in 0..<200 {
            if await spy.requestedCursors() == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for cursor requests.")
    }

    private func datedClip(id: Int, start: Date, bootTag: String? = nil) -> Clip {
        Clip(
            id: id,
            startMs: epochMs(start),
            durMs: 30_000,
            bytes: UInt64(id * 100),
            locked: false,
            etag: "\(id)-\(id * 100)",
            timeApproximate: false,
            bootTag: bootTag
        )
    }

    private func recordingClip(id: Int, bootTag: String, session: UInt64 = 7) -> Clip {
        Clip(
            id: id,
            startMs: nil,
            durMs: 30_000,
            bytes: UInt64(id * 100),
            locked: false,
            etag: "\(id)-\(id * 100)",
            timeApproximate: true,
            bootTag: bootTag,
            session: session
        )
    }

    private func epochMs(_ date: Date) -> UInt64 {
        UInt64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try #require(
            DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            ).date
        )
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

private actor HomeFetchSpy {
    private var cursors: [String?] = []
    private var responses: [ClipsResponse]

    init(responses: [ClipsResponse] = [ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil)]) {
        self.responses = responses
    }

    nonisolated func client() -> ClipsClient {
        ClipsClient { cursor in
            await self.response(cursor: cursor)
        }
    }

    func requestedCursors() -> [String?] {
        cursors
    }

    private func response(cursor: String?) -> ClipsResponse {
        cursors.append(cursor)
        guard responses.isEmpty == false else {
            return ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil)
        }

        return responses.removeFirst()
    }
}

/// A `ThumbnailLoader` fake for controller tests: `prefetch` returns a handle whose
/// `cancel()` records against the clip's `(id, etag)` key; `thumbnail` parks and records
/// observed cancellation. Both are asserted behaviorally -- the tests never reach into the
/// controller's private handle map.
private final class HomeLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var prefetchCancels: [String: Int] = [:]
    private var prefetchRequests: [ClipThumbnailIdentity] = []
    private var thumbnailRequests: [ClipThumbnailIdentity] = []
    private var thumbnailCalls = 0
    private var thumbnailCancels = 0
    private let thumbnailSignal = AsyncSignal()

    func loader() -> ThumbnailLoader {
        ThumbnailLoader(
            thumbnail: { [self] clip in
                noteThumbnailCall(ClipThumbnailIdentity(clip))
                await withTaskCancellationHandler {
                    await thumbnailSignal.wait()
                } onCancel: {
                    noteThumbnailCancel()
                }
                return nil
            },
            prefetch: { [self] clip in
                let key = key(clip)
                notePrefetchRequest(ClipThumbnailIdentity(clip))
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

    func prefetchIdentities() -> [ClipThumbnailIdentity] {
        lock.lock(); defer { lock.unlock() }
        return prefetchRequests
    }

    func thumbnailIdentities() -> [ClipThumbnailIdentity] {
        lock.lock(); defer { lock.unlock() }
        return thumbnailRequests
    }

    private func key(_ clip: Clip) -> String {
        "\(clip.id)-\(clip.etag)"
    }

    private func notePrefetchRequest(_ identity: ClipThumbnailIdentity) {
        lock.lock(); defer { lock.unlock() }
        prefetchRequests.append(identity)
    }

    private func notePrefetchCancel(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        prefetchCancels[key, default: 0] += 1
    }

    private func noteThumbnailCall(_ identity: ClipThumbnailIdentity) {
        lock.lock(); defer { lock.unlock() }
        thumbnailRequests.append(identity)
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
