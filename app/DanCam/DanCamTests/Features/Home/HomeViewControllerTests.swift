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
    func driveCardUsesOnlyRepresentativeThumbnailForDisplayAndPrefetch() async throws {
        let probe = HomeLoaderProbe()
        let oldest = driveClip(id: 1, bootTag: "boot-a")
        let middle = driveClip(id: 2, bootTag: "boot-a")
        let newest = driveClip(id: 3, bootTag: "boot-a")
        let (controller, store) = makeControllerAndStore(
            clips: [newest, middle, oldest],
            loader: probe.loader()
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            probe.thumbnailIdentities() == [ClipThumbnailIdentity(oldest)]
        }

        let driveIndexPath = try #require(controller.indexPathForTesting(rowID: .drive(bootTag: "boot-a", occurrence: 0)))
        controller.tableView(UITableView(), prefetchRowsAt: [driveIndexPath])

        #expect(probe.prefetchIdentities() == [ClipThumbnailIdentity(oldest)])

        store.send(.clips(.clipFinalized(driveClip(id: 4, bootTag: "boot-a"))))
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
        controller.loadViewIfNeeded()

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
    func paginationTriggersFromTailDriveRows() async throws {
        let fetchSpy = HomeFetchSpy()
        let controller = makeController(
            clips: [
                driveClip(id: 10, bootTag: "boot-a"),
                driveClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop,
            clipsClient: fetchSpy.client(),
            nextCursor: "8"
        )
        controller.loadViewIfNeeded()

        let driveIndexPath = try #require(controller.indexPathForTesting(rowID: .drive(bootTag: "boot-a", occurrence: 0)))
        controller.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: driveIndexPath)

        try await waitForCursors(fetchSpy, [Optional("8")])
    }

    @Test(.timeLimit(.minutes(1)))
    func pageAbsorbedByVisibleBottomDriveIssuesNextFetch() async throws {
        let fetchSpy = HomeFetchSpy(responses: [
            ClipsResponse(clips: [driveClip(id: 8, bootTag: "boot-a")], serverTimeMs: nil, nextCursor: "7"),
            ClipsResponse(clips: [], serverTimeMs: nil, nextCursor: nil),
        ])
        let controller = makeController(
            clips: [
                driveClip(id: 10, bootTag: "boot-a"),
                driveClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop,
            clipsClient: fetchSpy.client(),
            nextCursor: "8"
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        let driveIndexPath = try #require(controller.indexPathForTesting(rowID: .drive(bootTag: "boot-a", occurrence: 0)))
        controller.tableView(UITableView(), willDisplay: UITableViewCell(), forRowAt: driveIndexPath)

        try await waitForCursors(fetchSpy, [Optional("8"), Optional("7")])
    }

    @Test func tappingDriveCardPushesDriveDetail() throws {
        let controller = makeController(
            clips: [
                driveClip(id: 10, bootTag: "boot-a"),
                driveClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop
        )
        let (window, navigationController) = try embedInNavigationController(controller)
        defer { window.isHidden = true }

        let driveIndexPath = try #require(controller.indexPathForTesting(rowID: .drive(bootTag: "boot-a", occurrence: 0)))
        controller.tableView(UITableView(), didSelectRowAt: driveIndexPath)

        #expect(navigationController.topViewController is DriveDetailViewController)
        #expect(navigationController.viewControllers.count == 2)
    }

    @Test func driveCardSwipeHasNoActions() throws {
        let controller = makeController(
            clips: [
                driveClip(id: 10, bootTag: "boot-a"),
                driveClip(id: 9, bootTag: "boot-a"),
            ],
            loader: .noop
        )
        controller.loadViewIfNeeded()

        let driveIndexPath = try #require(controller.indexPathForTesting(rowID: .drive(bootTag: "boot-a", occurrence: 0)))

        #expect(controller.tableView(
            UITableView(),
            trailingSwipeActionsConfigurationForRowAt: driveIndexPath
        ) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func dayRolloverMovesLiveRowAndRefreshesVisibleHeaders() async throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        var now = try date(2026, 1, 3, hour: 23, minute: 59, calendar: calendar)
        let finishedClip = datedClip(id: 21, start: try date(2026, 1, 3, hour: 12, calendar: calendar))
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000)
        )
        let controller = makeController(
            clips: [finishedClip],
            loader: .noop,
            world: world,
            recording: .recording,
            wallNow: { now },
            currentCalendar: { calendar }
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.layoutClipsTableForTesting()
            return controller.sectionHeaderTitlesForTesting == ["Today"] &&
                controller.indexPathForTesting(rowID: .live(session: 7, id: 24))?.section == 0 &&
                controller.indexPathForTesting(rowID: .finished(finishedClip.id))?.section == 0
        }
        let todayHeader = try #require(controller.dayHeaderViewForTesting(section: 0))
        #expect(todayHeader.titleTextForTesting == "Today")

        now = try date(2026, 1, 4, hour: 0, minute: 1, calendar: calendar)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)

        try await waitUntil {
            controller.layoutClipsTableForTesting()
            return controller.sectionHeaderTitlesForTesting == ["Today", "Yesterday"] &&
                controller.indexPathForTesting(rowID: .live(session: 7, id: 24))?.section == 0 &&
                controller.indexPathForTesting(rowID: .finished(finishedClip.id))?.section == 1 &&
                controller.dayHeaderViewForTesting(section: 1)?.titleTextForTesting == "Yesterday"
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

    @Test(.timeLimit(.minutes(1)))
    func liveRecordingRowFreezesOfflineAndThawsOnReconnectSnapshot() async throws {
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
            controller.liveClipCellForTesting() != nil
        }

        let liveCell = try #require(controller.liveClipCellForTesting())
        let initialElapsed = try #require(liveCell.elapsedTextForTesting)
        #expect(colorMatches(liveCell.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(initialElapsed.hasPrefix("~") == false)
        #expect(controller.isLiveTickTimerRunningForTesting)
        #expect(controller.isRecPillVisibleForTesting)
        #expect(controller.recordButtonForTesting.configuration?.title == "Stop")
        #expect(controller.recordButtonForTesting.isEnabled)

        store.send(.heartbeatTimedOut)

        try await waitUntil {
            self.colorMatches(liveCell.recBadgeForTesting.dotColorForTesting, .systemGray) &&
                liveCell.elapsedTextForTesting?.hasPrefix("~") == true
        }

        let frozenCell = try #require(controller.liveClipCellForTesting())
        let frozenElapsed = try #require(liveCell.elapsedTextForTesting)
        #expect(frozenCell === liveCell)
        #expect(liveCell.accessibilityLabel?.hasPrefix("seg_00024.ts, last known recording, ~") == true)
        #expect(controller.isLiveTickTimerRunningForTesting == false)
        controller.tickLiveElapsedForTesting()
        #expect(liveCell.elapsedTextForTesting == frozenElapsed)
        #expect(controller.isRecPillVisibleForTesting == false)
        #expect(controller.recordButtonForTesting.configuration?.title == "Record")
        #expect(controller.recordButtonForTesting.isEnabled == false)

        store.send(.event(.snapshot(world)))

        try await waitUntil {
            self.colorMatches(liveCell.recBadgeForTesting.dotColorForTesting, .systemRed) &&
                liveCell.elapsedTextForTesting?.hasPrefix("~") == false
        }

        let thawedCell = try #require(controller.liveClipCellForTesting())
        #expect(thawedCell === liveCell)
        #expect(controller.isLiveTickTimerRunningForTesting)
        #expect(controller.isRecPillVisibleForTesting)
        #expect(controller.recordButtonForTesting.configuration?.title == "Stop")
        #expect(controller.recordButtonForTesting.isEnabled)
    }

    @Test(.timeLimit(.minutes(1)))
    func tappingRecordShowsPendingRowImmediatelyWithoutTickTimer() async throws {
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
            controller.isShowingPendingRowForTesting
        }
        let pendingCell = try #require(controller.pendingCellForTesting)
        #expect(pendingCell.accessibilityLabel == "Starting recording")
        #expect(colorMatches(pendingCell.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(controller.isLiveTickTimerRunningForTesting == false)

        await releaseStart.signal()
        try await waitUntil {
            controller.recordButtonForTesting.configuration?.title == "Stop"
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func segmentOpenedReplacesPendingWithLiveRow() async throws {
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
            controller.isShowingPendingRowForTesting
        }

        store.send(.event(.segmentOpened(session: 7, id: 43, atMs: 5_400)))

        try await waitUntil {
            controller.isShowingPendingRowForTesting == false &&
                controller.liveClipCellForTesting() != nil
        }
        #expect(controller.pendingCellForTesting == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedStartRemovesPendingRowSilently() async throws {
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
            controller.isShowingPendingRowForTesting
        }

        await releaseStart.signal()

        try await waitUntil {
            controller.isShowingPendingRowForTesting == false
        }
        #expect(controller.liveClipCellForTesting() == nil)
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
            controller.isShowingPendingRowForTesting
        }

        store.send(.event(.recorderFailed(session: 7, detail: "sensor lost", atMs: 1)))

        try await waitUntil {
            controller.isShowingPendingRowForTesting == false
        }
        #expect(controller.liveClipCellForTesting() == nil)
        #expect(controller.recordButtonForTesting.isEnabled)

        await releaseStart.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func heartbeatTimeoutHidesPendingRow() async throws {
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
            controller.isShowingPendingRowForTesting
        }

        store.send(.heartbeatTimedOut)

        try await waitUntil {
            controller.isShowingPendingRowForTesting == false
        }
        store.send(.streamStopped)
    }

    @Test func configurePendingResetsGrayFrozenBadgeToRed() {
        let clock = ContinuousClock()
        let cell = LiveClipCell(style: .default, reuseIdentifier: "liveClip")
        let segment = LiveSegment(
            sessionId: 7,
            id: 43,
            elapsed: .frozen(durMs: 1_000)
        )

        cell.configure(segment: segment, now: clock.now)
        #expect(colorMatches(cell.recBadgeForTesting.dotColorForTesting, .systemGray))

        cell.configurePending()

        #expect(colorMatches(cell.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(cell.elapsedTextForTesting == "00:00")
    }

    @Test func recordButtonLivesBelowPreviewNotInToolbar() throws {
        let controller = makeController(clips: [], loader: .noop)
        controller.loadViewIfNeeded()

        #expect(controller.isTableHeaderInstalledForTesting == false)

        let (window, navigationController) = try embedInNavigationController(controller)
        defer { window.isHidden = true }

        #expect(controller.isTableHeaderInstalledForTesting)
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
        recording: RecordingFeature.State = .unknown,
        clipsClient: ClipsClient = .noop,
        nextCursor: String? = nil,
        preview: PreviewClient = .noop,
        recordingClient: RecordingClient = .noop,
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
        wallNow: @escaping () -> Date = Date.init,
        currentCalendar: @escaping () -> Calendar = { .current }
    ) -> (HomeViewController, AppStore) {
        var state = AppFeature.State()
        state.clips.clips = clips
        state.clips.nextCursor = nextCursor
        state.recording = recording
        if let world {
            state.link = .online(world)
        }
        let dependencies = AppDependencies(
            health: HealthClient(fetch: { fatalError("Health is not used by HomeViewControllerTests.") }),
            clips: clipsClient,
            thumbnailLoader: loader,
            preview: preview,
            recording: recordingClient,
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
            heartbeatTimeout: { throw CancellationError() }
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

    private func driveClip(id: Int, bootTag: String) -> Clip {
        Clip(
            id: id,
            startMs: nil,
            durMs: 30_000,
            bytes: UInt64(id * 100),
            locked: false,
            etag: "\(id)-\(id * 100)",
            timeApproximate: true,
            bootTag: bootTag
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
