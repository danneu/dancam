import AVFoundation
import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct IncidentDetailViewControllerTests {
    @Test(.timeLimit(.minutes(1)))
    func unifiedTimelineGrowsWithoutReplacingStablePlayerInstancesOrEvidenceOnlyItems() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [42, 43], frameCount: 180)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builds = TimelineBuildCounter()
        let hosted = try host(makeController(
            fixture: fixture,
            preparer: .unavailable,
            timelineBuild: { segments, directoryURL in
                await builds.increment()
                return await IncidentPlaybackTimelineBuilder.build(
                    segments: segments,
                    directoryURL: directoryURL
                )
            }
        ))
        let controller = hosted.controller
        controller.loadViewIfNeeded()
        try await waitUntilAsync {
            await builds.value == 1 && controller.timelineForTesting?.segments.map(\.seq) == [42, 43]
        }
        let player = controller.playerForTesting
        let playerController = controller.playerViewControllerForTesting
        let originalItem = try #require(player.currentItem)
        #expect(player.rate != 0)

        var evidenceOnly = fixture.record
        evidenceOnly.wanted[0].bytes = 999
        send(evidenceOnly, fixture: fixture)
        try await waitUntilAsync {
            await builds.value == 2 && controller.rowsForTesting.first?.artifact?.bytes == 999
        }
        #expect(player.currentItem === originalItem)

        let oldTimeline = try #require(controller.timelineForTesting)
        let oldSegment = try #require(oldTimeline.segments.first(where: { $0.seq == 43 }))
        let offset = CMTime(value: 1, timescale: 1)
        await player.seek(
            to: CMTimeAdd(oldSegment.start, offset),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()

        let appendedURL = artifactURL(seq: 44, kind: .mp4, fixture: fixture)
        _ = try await makeTemporaryPlayableVideoFile(at: appendedURL, frameCount: 180)
        var appended = evidenceOnly
        appended.wanted.append(IncidentSegment(seq: 44, state: .pulled, durMs: 100, bytes: 3))
        send(appended, fixture: fixture)
        try await waitUntil { controller.timelineForTesting?.segments.map(\.seq) == [42, 43, 44] }

        #expect(controller.playerForTesting === player)
        #expect(controller.playerViewControllerForTesting === playerController)
        #expect(player.currentItem !== originalItem)
        #expect(player.rate != 0)
        player.pause()
        let restored = try #require(controller.timelineForTesting?.anchor(at: player.currentTime()))
        #expect(restored.seq == 43)
        #expect(CMTimeCompare(restored.offset, offset) >= 0)
        #expect(CMTimeCompare(restored.offset, CMTimeAdd(offset, CMTime(value: 1, timescale: 1))) < 0)
        _ = hosted.window
    }

    @Test(.timeLimit(.minutes(1)))
    func rebuildRestoresSequenceRelativePositionAcrossLowerBackfill() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [42, 43])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = makeController(fixture: fixture, preparer: .unavailable)
        controller.loadViewIfNeeded()
        try await waitUntil { controller.timelineForTesting?.segments.map(\.seq) == [42, 43] }
        let oldTimeline = try #require(controller.timelineForTesting)
        let oldSegment = try #require(oldTimeline.segments.first(where: { $0.seq == 43 }))
        let offset = CMTime(value: 1, timescale: 60)
        controller.playerForTesting.pause()
        await controller.playerForTesting.seek(
            to: CMTimeAdd(oldSegment.start, offset),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        let backfillURL = artifactURL(seq: 41, kind: .mp4, fixture: fixture)
        _ = try await makeTemporaryPlayableVideoFile(at: backfillURL, frameCount: 4)
        var backfilled = fixture.record
        backfilled.wanted.append(IncidentSegment(seq: 41, state: .pulled, durMs: 133, bytes: 4))
        send(backfilled, fixture: fixture)
        try await waitUntil { controller.timelineForTesting?.segments.map(\.seq) == [41, 42, 43] }
        let newSegment = try #require(controller.timelineForTesting?.segments.first(where: { $0.seq == 43 }))

        #expect(CMTimeCompare(
            controller.playerForTesting.currentTime(),
            CMTimeAdd(newSegment.start, offset)
        ) == 0)
        #expect(controller.playerForTesting.rate == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleBuildCannotReplaceNewerTimeline() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [42])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = TimelineBuildGate()
        let controller = makeController(
            fixture: fixture,
            preparer: .unavailable,
            timelineBuild: { segments, directoryURL in
                await gate.build(segments: segments, directoryURL: directoryURL)
            }
        )
        controller.loadViewIfNeeded()
        await gate.firstBuildStarted.wait()

        _ = try await makeTemporaryPlayableVideoFile(
            at: artifactURL(seq: 43, kind: .mp4, fixture: fixture),
            frameCount: 2
        )
        var newer = fixture.record
        newer.wanted.append(IncidentSegment(seq: 43, state: .pulled, durMs: 67, bytes: 2))
        send(newer, fixture: fixture)
        try await waitUntil { controller.timelineForTesting?.segments.map(\.seq) == [42, 43] }

        await gate.releaseFirstBuild.signal()
        await Task.yield()
        #expect(controller.timelineForTesting?.segments.map(\.seq) == [42, 43])
    }

    @Test
    func rowsIncludeOnlyWaitingAndInstalledSegmentsInSequenceOrder() throws {
        let fixture = try makeFixture(kind: .ts)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = fixture.record
        record.wanted = [
            IncidentSegment(seq: 45, state: .pulled, durMs: 100, bytes: 5),
            IncidentSegment(seq: 44, state: .lost, durMs: 100),
            IncidentSegment(seq: 43, state: .pulled, durMs: 100, bytes: 2),
            IncidentSegment(seq: 42, state: .clipped),
            IncidentSegment(seq: 41, state: .wanted, durMs: 100),
            IncidentSegment(seq: 40, state: .unresolved),
        ]
        send(record, fixture: fixture)
        let controller = makeController(fixture: fixture, preparer: .unavailable)

        controller.loadViewIfNeeded()

        #expect(controller.rowsForTesting.map(\.seq) == [40, 41, 43])
        #expect(controller.rowsForTesting.map(\.isWaiting) == [true, true, false])
        #expect(controller.rowsForTesting.last?.artifact?.kind == .ts)
    }

    @Test(.timeLimit(.minutes(1)))
    func waitingRowIsInertThenTransitionsAndAcceptsLowerBackfill() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [43])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var pending = fixture.record
        pending.updateSegment(IncidentSegment(seq: 42, state: .wanted, durMs: 100))
        send(pending, fixture: fixture)
        let controller = makeController(fixture: fixture, preparer: .unavailable)
        controller.loadViewIfNeeded()
        try await waitUntil { controller.timelineForTesting?.segments.map(\.seq) == [43] }
        controller.playerForTesting.pause()
        await controller.playerForTesting.seek(
            to: controller.timelineForTesting?.duration ?? .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        let timeBeforeSelection = controller.playerForTesting.currentTime()
        let waitingCell = controller.cellForTesting(at: 0)

        controller.selectRowForTesting(at: 0)

        #expect(controller.hasSelectedRowForTesting == false)
        #expect(controller.isShareButtonEnabledForTesting == false)
        #expect(CMTimeCompare(controller.playerForTesting.currentTime(), timeBeforeSelection) == 0)
        #expect(waitingCell.accessibilityTraits.contains(.notEnabled))
        #expect(waitingCell.accessoryType == .none)
        #expect(waitingCell.selectionStyle == .none)
        let indicator = try #require(waitingCell.accessoryView as? UIActivityIndicatorView)
        #expect(indicator.isAnimating)

        _ = try await makeTemporaryPlayableVideoFile(
            at: artifactURL(seq: 42, kind: .mp4, fixture: fixture),
            frameCount: 3
        )
        var installed = pending
        var segment = try #require(installed.segment(seq: 42))
        segment.markPulled(bytes: 3)
        installed.updateSegment(segment)
        send(installed, fixture: fixture)
        try await waitUntil {
            controller.timelineForTesting?.segments.map(\.seq) == [42, 43]
                && controller.rowsForTesting.first?.artifact?.isPlayable == true
        }

        controller.selectRowForTesting(at: 0)
        let installedStart = try #require(controller.timelineForTesting?.startTime(for: 42))
        try await waitUntil {
            CMTimeCompare(controller.playerForTesting.currentTime(), installedStart) == 0
        }
        #expect(controller.hasSelectedRowForTesting)
        #expect(controller.isShareButtonEnabledForTesting)

        var backfilled = installed
        backfilled.updateSegment(IncidentSegment(seq: 41, state: .unresolved))
        send(backfilled, fixture: fixture)

        #expect(controller.rowsForTesting.map(\.seq) == [41, 42, 43])
        #expect(controller.rowsForTesting.map(\.isWaiting) == [true, false, false])
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyTimelineTransitionsBetweenSavingPlayingAndNothingPlayable() async throws {
        let fixture = try makeFixture(kind: .ts)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.sourceURL)
        var pending = fixture.record
        pending.wanted = [IncidentSegment(seq: 43, state: .wanted, durMs: 100)]
        fixture.store.send(.incidents(.storeLoaded([
            .readable(record: pending, directoryURL: fixture.incidentStore.directoryURL(pending.id)),
        ])))
        let controller = makeController(fixture: fixture, preparer: .unavailable)
        controller.loadViewIfNeeded()
        #expect(controller.placeholderTextForTesting == "Saving incident video...")
        #expect(controller.isJumpToPressEnabledForTesting == false)
        #expect(controller.progressTextForTesting == "Saving 0 of 1 segments")
        #expect(controller.gapTextForTesting == nil)
        #expect(controller.rowsForTesting.map(\.seq) == [43])
        #expect(controller.rowsForTesting.first?.isWaiting == true)

        let url = artifactURL(seq: 43, kind: .mp4, fixture: fixture)
        _ = try await makeTemporaryPlayableVideoFile(at: url, frameCount: 180)
        var pulled = pending
        pulled.wanted[0].markPulled(bytes: 3)
        send(pulled, fixture: fixture)
        await controller.waitForTimelineBuildForTesting()
        #expect(controller.timelineForTesting?.segments.map(\.seq) == [43])
        #expect(controller.placeholderTextForTesting == nil)
        #expect(controller.isJumpToPressEnabledForTesting)
        #expect(controller.gapTextForTesting == "All saved segments are playable.")
        #expect(controller.playerForTesting.rate != 0)
        #expect(CMTimeCompare(controller.playerForTesting.currentTime(), CMTime(value: 1, timescale: 1)) < 0)

        try FileManager.default.removeItem(at: url)
        pulled.wanted[0].bytes = 4
        pulled.wanted.append(IncidentSegment(seq: 44, state: .lost, durMs: 100))
        send(pulled, fixture: fixture)
        await controller.waitForTimelineBuildForTesting()
        #expect(controller.timelineForTesting?.segments.isEmpty == true)
        #expect(controller.placeholderTextForTesting == "No playable video is available.")
        #expect(controller.isJumpToPressEnabledForTesting == false)
        #expect(controller.progressTextForTesting == "1 of 2 segments saved")
        #expect(controller.gapTextForTesting == "Missing: 44\nUnavailable for playback: 43")
    }

    @Test(.timeLimit(.minutes(1)))
    func correctivePendingRecordClearsAllPlayableClaimBeforeTimelineRebuild() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [43])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = CorrectiveTimelineBuildGate()
        let controller = makeController(
            fixture: fixture,
            preparer: .unavailable,
            timelineBuild: { segments, directoryURL in
                await gate.build(segments: segments, directoryURL: directoryURL)
            }
        )
        controller.loadViewIfNeeded()
        try await waitUntil {
            controller.gapTextForTesting == "All saved segments are playable."
        }

        var corrective = fixture.record
        corrective.updateSegment(IncidentSegment(seq: 44, state: .wanted, durMs: 100))
        send(corrective, fixture: fixture)
        await gate.correctiveBuildStarted.wait()

        #expect(controller.progressTextForTesting == "Saving 1 of 2 segments")
        #expect(controller.gapTextForTesting == nil)
        #expect(controller.rowsForTesting.map(\.seq) == [43, 44])
        await gate.releaseCorrectiveBuild.signal()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedItemSelfHealsOncePerPlayableSetThenLeavesActionsUsable() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [42])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = TimelineBuildCounter()
        let controller = makeController(
            fixture: fixture,
            preparer: .unavailable,
            timelineBuild: { segments, directoryURL in
                await calls.increment()
                return await IncidentPlaybackTimelineBuilder.build(
                    segments: segments,
                    directoryURL: directoryURL
                )
            }
        )
        controller.loadViewIfNeeded()
        try await waitUntilAsync { await calls.value == 1 && controller.playerForTesting.currentItem != nil }
        let firstItem = try #require(controller.playerForTesting.currentItem)

        controller.failCurrentPlayerForTesting()
        try await waitUntilAsync { await calls.value == 2 && controller.playerForTesting.currentItem !== firstItem }
        controller.selectRowForTesting(at: 0)
        controller.failCurrentPlayerForTesting()
        await Task.yield()

        #expect(await calls.value == 2)
        #expect(controller.placeholderTextForTesting?.hasPrefix("Playback failed.") == true)
        #expect(controller.hasSelectedRowForTesting)
        #expect(controller.isShareButtonEnabledForTesting)
        #expect(controller.isDeleteButtonEnabledForTesting)
    }

    @Test(.timeLimit(.minutes(1)))
    func playableRowAndJumpSeekUnifiedTimelineWhileTSRowDoesNotSeek() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [41, 43], markSeq: 42, markAgeMs: 12)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = fixture.record
        record.wanted.insert(IncidentSegment(seq: 42, state: .pulled, durMs: 100, bytes: 2), at: 1)
        try Data([0x47, 0x00]).write(to: artifactURL(seq: 42, kind: .ts, fixture: fixture))
        send(record, fixture: fixture)
        let controller = makeController(fixture: fixture, preparer: .unavailable)
        controller.loadViewIfNeeded()
        try await waitUntil { controller.timelineForTesting?.segments.map(\.seq) == [41, 43] }
        controller.playerForTesting.pause()
        await controller.playerForTesting.seek(to: controller.timelineForTesting?.duration ?? .zero)

        controller.selectRowForTesting(at: 0)
        let firstStart = try #require(controller.timelineForTesting?.startTime(for: 41))
        try await waitUntil { CMTimeCompare(controller.playerForTesting.currentTime(), firstStart) == 0 }
        let beforeTS = controller.playerForTesting.currentTime()
        controller.selectRowForTesting(at: 1)
        await Task.yield()
        #expect(CMTimeCompare(controller.playerForTesting.currentTime(), beforeTS) == 0)

        controller.jumpToPressForTesting()
        let forwardStart = try #require(controller.timelineForTesting?.startTime(for: 43))
        try await waitUntil { CMTimeCompare(controller.playerForTesting.currentTime(), forwardStart) == 0 }
    }

    @Test(.timeLimit(.minutes(1)))
    func recordRemovalTearsDownPlaybackAndFullscreenBeforePopping() async throws {
        let fixture = try await makePlaybackFixture(playableSeqs: [42])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = makeController(fixture: fixture, preparer: .unavailable)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let navigationController = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()
        try await waitUntil { controller.playerForTesting.currentItem != nil }
        controller.enterFullScreenForTesting()

        fixture.store.send(.incidents(.storeLoaded([])))

        #expect(controller.playerForTesting.currentItem == nil)
        #expect(controller.isPresentingFullScreenForTesting == false)
        #expect(navigationController.topViewController !== controller)
        _ = window
    }

    @Test(.timeLimit(.minutes(1)), arguments: [IncidentArtifactKind.mp4, .ts])
    func preparationIsImmediateSingleFlightAndPresentsFriendlyURL(kind: IncidentArtifactKind) async throws {
        let fixture = try makeFixture(kind: kind)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cloneStarted = AsyncSignal()
        let allowClone = AsyncSignal()
        let calls = ShareRequestLog()
        let artifactDirectory = fixture.root.appending(path: "prepared", directoryHint: .isDirectory)
        let preparedURL = artifactDirectory.appending(path: "friendly.\(kind.rawValue)")
        let presentation = VideoSharePresentationSpy()
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        try Data([0x47]).write(to: preparedURL)
        let preparer = ShareArtifactPreparer { request in
            await calls.append(request)
            await cloneStarted.signal()
            await allowClone.wait()
            return PreparedShareArtifact(url: preparedURL, ownedDirectory: artifactDirectory)
        }
        let hosted = try host(makeController(
            fixture: fixture,
            preparer: preparer,
            sharePresentation: presentation.presentation
        ))
        let controller = hosted.controller
        controller.loadViewIfNeeded()
        controller.selectRowForTesting(at: 0)

        controller.shareTappedForTesting()
        controller.shareTappedForTesting()

        #expect(controller.isSharePreparingForTesting)
        #expect(controller.sharePreparationAccessibilityLabelForTesting == "Preparing video")
        #expect(controller.isShareButtonEnabledForTesting == false)
        #expect(controller.isDeleteButtonEnabledForTesting == false)
        #expect(controller.allowsSelectionForTesting == false)
        await cloneStarted.wait()
        #expect(await calls.count() == 1)

        await allowClone.signal()
        try await waitUntil { presentation.presentedURL == preparedURL }
        try await waitUntil { controller.isSharePreparingForTesting == false }
        #expect(controller.isShareButtonEnabledForTesting)
        #expect(controller.isDeleteButtonEnabledForTesting)
        #expect(controller.allowsSelectionForTesting)

        #expect(FileManager.default.fileExists(atPath: artifactDirectory.path))
        presentation.complete()
        try await waitUntil { FileManager.default.fileExists(atPath: artifactDirectory.path) == false }
        controller.didMove(toParent: nil)
        _ = hosted.window
    }

    @Test(.timeLimit(.minutes(1)))
    func missingFileClearsSelectionAndShowsUnavailableAlert() async throws {
        let fixture = try makeFixture(kind: .ts)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let hosted = try host(makeController(fixture: fixture, preparer: .live(
            stagingRoot: fixture.root.appending(path: "staging")
        )))
        let controller = hosted.controller
        controller.loadViewIfNeeded()
        controller.selectRowForTesting(at: 0)
        try FileManager.default.removeItem(at: fixture.sourceURL)

        controller.shareTappedForTesting()

        try await waitUntil { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == "Unable to Share Video")
        #expect(alert.message == "The video file is no longer available.")
        #expect(controller.hasSelectedRowForTesting == false)
        #expect(controller.isShareButtonEnabledForTesting == false)
        _ = hosted.window
    }

    @Test(.timeLimit(.minutes(1)))
    func selectedSegmentRemovalCancelsAndCleansLateArtifact() async throws {
        let fixture = try makeFixture(kind: .mp4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cloneStarted = AsyncSignal()
        let allowClone = AsyncSignal()
        let artifactDirectory = fixture.root.appending(path: "late", directoryHint: .isDirectory)
        let preparedURL = artifactDirectory.appending(path: "late.mp4")
        let preparer = ShareArtifactPreparer { _ in
            await cloneStarted.signal()
            await allowClone.wait()
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            try Data([0x01]).write(to: preparedURL)
            return PreparedShareArtifact(url: preparedURL, ownedDirectory: artifactDirectory)
        }
        let controller = makeController(fixture: fixture, preparer: preparer)
        controller.loadViewIfNeeded()
        controller.selectRowForTesting(at: 0)
        controller.shareTappedForTesting()
        await cloneStarted.wait()

        var updated = fixture.record
        updated.wanted.removeAll()
        fixture.store.send(.incidents(.storeLoaded([
            .readable(record: updated, directoryURL: fixture.incidentStore.directoryURL(updated.id)),
        ])))

        #expect(controller.isSharePreparingForTesting == false)
        #expect(controller.hasSelectedRowForTesting == false)
        await allowClone.signal()
        try await waitUntil { FileManager.default.fileExists(atPath: artifactDirectory.path) == false }
        #expect(controller.presentedShareURLForTesting == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func retainedSelectedSegmentKeepsInFlightSharePreparationAcrossRebuild() async throws {
        let fixture = try makeFixture(kind: .mp4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cloneStarted = AsyncSignal()
        let allowClone = AsyncSignal()
        let artifactDirectory = fixture.root.appending(path: "retained", directoryHint: .isDirectory)
        let preparedURL = artifactDirectory.appending(path: "retained.mp4")
        let presentation = VideoSharePresentationSpy()
        let preparer = ShareArtifactPreparer { _ in
            await cloneStarted.signal()
            await allowClone.wait()
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            try Data([0x01]).write(to: preparedURL)
            return PreparedShareArtifact(url: preparedURL, ownedDirectory: artifactDirectory)
        }
        let controller = makeController(
            fixture: fixture,
            preparer: preparer,
            sharePresentation: presentation.presentation
        )
        controller.loadViewIfNeeded()
        controller.selectRowForTesting(at: 0)
        controller.shareTappedForTesting()
        await cloneStarted.wait()

        var updated = fixture.record
        updated.wanted[0].bytes = 3
        send(updated, fixture: fixture)

        #expect(controller.isSharePreparingForTesting)
        #expect(controller.hasSelectedRowForTesting)
        await allowClone.signal()
        try await waitUntil { presentation.presentedURL == preparedURL }
        presentation.complete()
    }

    private func makeFixture(kind: IncidentArtifactKind) throws -> IncidentFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "dancam-incident-detail-\(UUID().uuidString)", directoryHint: .isDirectory)
        let incidentStore = IncidentStore.live(rootDirectory: root)
        let record = fixtureRecord()
        let directory = incidentStore.directoryURL(record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appending(path: "seg_00043.\(kind.rawValue)")
        try Data([0x47, 0x00]).write(to: sourceURL)
        var appState = AppFeature.State()
        appState.incidents.incidents = [record]
        let dependencies = AppDependencies(incidentStore: incidentStore)
        let store = AppStore(initialState: appState, dependencies: dependencies, reduce: AppFeature.reduce)
        return IncidentFixture(
            root: root,
            sourceURL: sourceURL,
            record: record,
            incidentStore: incidentStore,
            store: store
        )
    }

    private func makeController(
        fixture: IncidentFixture,
        preparer: ShareArtifactPreparer,
        sharePresentation: VideoSharePresentation? = nil,
        timelineBuild: @escaping IncidentTimelineBuild = { segments, directoryURL in
            await IncidentPlaybackTimelineBuilder.build(segments: segments, directoryURL: directoryURL)
        }
    ) -> IncidentDetailViewController {
        let dependencies = AppDependencies(
            incidentStore: fixture.incidentStore,
            shareArtifactPreparer: preparer
        )
        let controller = IncidentDetailViewController(
            dependencies: dependencies,
            store: fixture.store,
            incidentID: fixture.record.id,
            sharePresentation: sharePresentation,
            timelineBuild: timelineBuild
        )
        controller.exportTimeZone = TimeZone(secondsFromGMT: 0)!
        return controller
    }

    private func host(
        _ controller: IncidentDetailViewController
    ) throws -> (window: UIWindow, controller: IncidentDetailViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        return (window, controller)
    }

    private func fixtureRecord() -> IncidentRecord {
        IncidentRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            pressedAtMs: 1_784_480_523_000,
            recordingID: RecordingID(bootTag: "boot", session: 7),
            markSeq: 43,
            markAgeMs: 12_000,
            wanted: [IncidentSegment(seq: 43, state: .pulled, durMs: 30_000, bytes: 2)]
        )
    }

    private func makePlaybackFixture(
        playableSeqs: [Int],
        markSeq: Int = 42,
        markAgeMs: UInt64 = 20,
        frameCount: Int = 3
    ) async throws -> IncidentFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "dancam-incident-playback-\(UUID().uuidString)", directoryHint: .isDirectory)
        let incidentStore = IncidentStore.live(rootDirectory: root)
        let id = UUID()
        let wanted = playableSeqs.map {
            IncidentSegment(seq: $0, state: .pulled, durMs: 100, bytes: 3)
        }
        let record = IncidentRecord(
            id: id,
            pressedAtMs: 1_784_480_523_000,
            recordingID: RecordingID(bootTag: "boot", session: 7),
            markSeq: markSeq,
            markAgeMs: markAgeMs,
            wanted: wanted
        )
        let directory = incidentStore.directoryURL(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for seq in playableSeqs {
            _ = try await makeTemporaryPlayableVideoFile(
                at: directory.appending(path: String(format: "seg_%05d.mp4", seq)),
                frameCount: frameCount
            )
        }
        var appState = AppFeature.State()
        appState.incidents.incidents = [record]
        let dependencies = AppDependencies(incidentStore: incidentStore)
        let store = AppStore(initialState: appState, dependencies: dependencies, reduce: AppFeature.reduce)
        return IncidentFixture(
            root: root,
            sourceURL: directory.appending(path: String(format: "seg_%05d.mp4", playableSeqs[0])),
            record: record,
            incidentStore: incidentStore,
            store: store
        )
    }

    private func artifactURL(
        seq: Int,
        kind: IncidentArtifactKind,
        fixture: IncidentFixture
    ) -> URL {
        fixture.incidentStore.directoryURL(fixture.record.id)
            .appending(path: String(format: "seg_%05d.%@", seq, kind.rawValue))
    }

    private func send(_ record: IncidentRecord, fixture: IncidentFixture) {
        fixture.store.send(.incidents(.storeLoaded([
            .readable(record: record, directoryURL: fixture.incidentStore.directoryURL(record.id)),
        ])))
    }

    private func waitUntil(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.", sourceLocation: sourceLocation)
    }

    private func waitUntilAsync(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @escaping () async -> Bool
    ) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for async condition.", sourceLocation: sourceLocation)
    }
}

@MainActor
private struct IncidentFixture {
    var root: URL
    var sourceURL: URL
    var record: IncidentRecord
    var incidentStore: IncidentStore
    var store: AppStore
}

private actor ShareRequestLog {
    private var requests: [SharePreparationRequest] = []

    func append(_ request: SharePreparationRequest) { requests.append(request) }
    func count() -> Int { requests.count }
}

private actor TimelineBuildCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private actor TimelineBuildGate {
    let firstBuildStarted = AsyncSignal()
    let releaseFirstBuild = AsyncSignal()

    func build(
        segments: [IncidentSegment],
        directoryURL: URL
    ) async -> sending IncidentPlaybackTimeline {
        if segments.count == 1 {
            await firstBuildStarted.signal()
            await releaseFirstBuild.wait()
        }
        return await IncidentPlaybackTimelineBuilder.build(
            segments: segments,
            directoryURL: directoryURL
        )
    }
}

private actor CorrectiveTimelineBuildGate {
    let correctiveBuildStarted = AsyncSignal()
    let releaseCorrectiveBuild = AsyncSignal()

    func build(
        segments: [IncidentSegment],
        directoryURL: URL
    ) async -> sending IncidentPlaybackTimeline {
        if segments.contains(where: { $0.state == .wanted }) {
            await correctiveBuildStarted.signal()
            await releaseCorrectiveBuild.wait()
        }
        return await IncidentPlaybackTimelineBuilder.build(
            segments: segments,
            directoryURL: directoryURL
        )
    }
}
