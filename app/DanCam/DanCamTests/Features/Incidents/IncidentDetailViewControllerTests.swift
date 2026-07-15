import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct IncidentDetailViewControllerTests {
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
        sharePresentation: VideoSharePresentation? = nil
    ) -> IncidentDetailViewController {
        let dependencies = AppDependencies(
            incidentStore: fixture.incidentStore,
            shareArtifactPreparer: preparer
        )
        let controller = IncidentDetailViewController(
            dependencies: dependencies,
            store: fixture.store,
            incidentID: fixture.record.id,
            sharePresentation: sharePresentation
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

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
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
