import Testing
import UIKit
@testable import DanCam

@MainActor
struct AppShellViewControllerTests {
    @Test func sceneTabsAreHomeIncidentsDebugSettings() {
        let tabs = SceneDelegate.makeTabs(dependencies: .init(), store: makeStore())

        #expect(tabs.map { $0.tabBarItem.title } == ["Home", "Incidents", "Debug", "Settings"])
        #expect(tabs[0].viewControllers.first is HomeViewController)
        #expect(tabs[1].viewControllers.first is IncidentsViewController)
        #expect(tabs[2].viewControllers.first is DebugViewController)
        #expect(tabs[3].viewControllers.first is SettingsViewController)
    }

    @Test func incidentsTabBadgeFollowsPendingCount() {
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        var pending = IncidentRecord(
            id: id,
            pressedAtMs: 1_784_480_523_000,
            recordingID: RecordingID(bootTag: "boot", session: 7),
            markSeq: 43,
            markAgeMs: 12_000
        )
        var initialState = AppFeature.State()
        initialState.incidents.incidents = [pending]
        let store = makeStore(initialState: initialState)
        let tabs = SceneDelegate.makeTabs(dependencies: .init(), store: store)
        let shell = AppShellViewController(tabs: tabs, store: store)
        shell.loadViewIfNeeded()

        #expect(tabs[1].tabBarItem.badgeValue == "1")

        pending.status = .saved
        store.send(.incidents(.recordPersisted(pending, cancelNudge: false, success: true)))
        #expect(tabs[1].tabBarItem.badgeValue == nil)
    }

    @Test func stripHidesRecordingPillWhileConnecting() {
        let store = makeStore()
        let shell = AppShellViewController(
            tabs: [UINavigationController(rootViewController: UIViewController())],
            store: store
        )
        shell.loadViewIfNeeded()

        #expect(shell.stripForTesting.connectionPillForTesting.captionForTesting == "Connecting")
        #expect(shell.stripForTesting.isRecordingPillVisibleForTesting == false)
    }

    @Test func stripShowsRedRecordingPillForLiveRecordingSnapshot() {
        let store = makeStore()
        let shell = AppShellViewController(
            tabs: [UINavigationController(rootViewController: UIViewController())],
            store: store
        )
        shell.loadViewIfNeeded()

        store.send(.event(.snapshot(CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000)
        ))))

        #expect(shell.stripForTesting.connectionPillForTesting.captionForTesting == "Connected")
        #expect(shell.stripForTesting.recordingPillForTesting.captionForTesting == "REC")
        #expect(shell.stripForTesting.recordingPillForTesting.accessibilityLabel == "Recording")
        #expect(colorMatches(shell.stripForTesting.recordingPillForTesting.dotColorForTesting, .systemRed))

        store.send(.streamStopped)
    }

    @Test func stripKeepsGrayRecordingPillAfterHeartbeatTimeout() {
        let store = makeStore()
        let shell = AppShellViewController(
            tabs: [UINavigationController(rootViewController: UIViewController())],
            store: store
        )
        shell.loadViewIfNeeded()

        store.send(.event(.snapshot(CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000)
        ))))
        store.send(.heartbeatTimedOut)

        #expect(shell.stripForTesting.connectionPillForTesting.captionForTesting == "Not connected")
        #expect(shell.stripForTesting.recordingPillForTesting.captionForTesting == "REC")
        #expect(shell.stripForTesting.recordingPillForTesting.accessibilityLabel == "Last known recording")
        #expect(colorMatches(shell.stripForTesting.recordingPillForTesting.dotColorForTesting, .systemGray))

        store.send(.streamStopped)
    }

    @Test func stripShowsNotRecordingForAffirmativeIdleSnapshot() {
        let store = makeStore()
        let shell = AppShellViewController(
            tabs: [UINavigationController(rootViewController: UIViewController())],
            store: store
        )
        shell.loadViewIfNeeded()

        store.send(.event(.snapshot(CameraSamples.world(phase: .idle, currentSegment: nil))))

        #expect(shell.stripForTesting.connectionPillForTesting.captionForTesting == "Connected")
        #expect(shell.stripForTesting.recordingPillForTesting.captionForTesting == "Not recording")
        #expect(colorMatches(shell.stripForTesting.recordingPillForTesting.dotColorForTesting, .secondaryLabel))

        store.send(.streamStopped)
    }

    @Test func stripRecordingPillReleasesWidthWhenHidden() {
        let connection = StripCoordination.ConnectionPill(caption: "Not connected", tone: .negative)
        let transitionStrip = laidOutStrip(width: 180, connection: connection, recording: .idle)

        transitionStrip.configure(connection: connection, recording: nil)
        transitionStrip.setNeedsLayout()
        transitionStrip.layoutIfNeeded()

        let hiddenFromTransitionWidth = transitionStrip.connectionPillForTesting.bounds.width
        let hiddenFromStartStrip = laidOutStrip(
            width: 180,
            connection: connection,
            recording: nil
        )
        let hiddenFromStartWidth = hiddenFromStartStrip.connectionPillForTesting.bounds.width

        #expect(abs(hiddenFromTransitionWidth - hiddenFromStartWidth) <= 0.5)
    }

    @Test func resumesTopVCOnReconnectEdge() {
        let store = makeStore()
        let spy = ResumeSpy()
        let shell = AppShellViewController(
            tabs: [UINavigationController(rootViewController: spy)],
            store: store
        )
        let world = CameraSamples.world()
        shell.loadViewIfNeeded()

        store.send(.streamFailed)
        #expect(spy.resumeCount == 0)

        store.send(.event(.snapshot(world)))
        #expect(spy.resumeCount == 1)

        store.send(.streamStopped)
    }

    @Test func firstContactConnectDoesNotResume() {
        let store = makeStore()
        let spy = ResumeSpy()
        let shell = AppShellViewController(
            tabs: [UINavigationController(rootViewController: spy)],
            store: store
        )
        shell.loadViewIfNeeded()

        store.send(.event(.snapshot(CameraSamples.world())))
        #expect(spy.resumeCount == 0)

        store.send(.streamStopped)
    }

    @Test func reconnectResumeTargetsSelectedTab() {
        let store = makeStore()
        let firstSpy = ResumeSpy()
        let secondSpy = ResumeSpy()
        let shell = AppShellViewController(
            tabs: [
                UINavigationController(rootViewController: firstSpy),
                UINavigationController(rootViewController: secondSpy),
            ],
            store: store
        )
        shell.loadViewIfNeeded()
        shell.selectTabForTesting(1)

        store.send(.streamFailed)
        store.send(.event(.snapshot(CameraSamples.world())))

        #expect(firstSpy.resumeCount == 0)
        #expect(secondSpy.resumeCount == 1)

        store.send(.streamStopped)
    }

    @Test func navigationStackSurvivesTabSwitch() {
        let homeNavigationController = UINavigationController(rootViewController: UIViewController())
        let settingsNavigationController = UINavigationController(rootViewController: UIViewController())
        let shell = AppShellViewController(
            tabs: [homeNavigationController, settingsNavigationController],
            store: makeStore()
        )
        shell.loadViewIfNeeded()

        let pushed = UIViewController()
        homeNavigationController.pushViewController(pushed, animated: false)
        shell.selectTabForTesting(1)
        shell.selectTabForTesting(0)

        #expect(shell.topViewController === pushed)
    }

    private func laidOutStrip(
        width: CGFloat,
        connection: StripCoordination.ConnectionPill,
        recording: StripCoordination.RecordingPill?
    ) -> StatusStripView {
        let strip = StatusStripView(frame: CGRect(x: 0, y: 0, width: width, height: 64))
        strip.configure(connection: connection, recording: recording)
        strip.setNeedsLayout()
        strip.layoutIfNeeded()
        return strip
    }

    private func makeStore(initialState: AppFeature.State = .init()) -> AppStore {
        AppStore(
            initialState: initialState,
            dependencies: AppDependencies(
                events: .noop,
                clips: .noop,
                sleep: { _ in
                    try? await Task.sleep(for: .seconds(60))
                },
                heartbeatTimeout: { throw CancellationError() }
            ),
            reduce: AppFeature.reduce
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

private final class ResumeSpy: UIViewController, ConnectionResumable {
    private(set) var resumeCount = 0

    func resumeLiveWork() {
        resumeCount += 1
    }
}
