import Testing
import UIKit
@testable import DanCam

@MainActor
struct AppShellViewControllerTests {
    @Test func stripHidesRecordingPillWhileConnecting() {
        let store = makeStore()
        let shell = AppShellViewController(
            navigationController: UINavigationController(rootViewController: UIViewController()),
            store: store
        )
        shell.loadViewIfNeeded()

        #expect(shell.stripForTesting.connectionPillForTesting.captionForTesting == "Connecting")
        #expect(shell.stripForTesting.isRecordingPillVisibleForTesting == false)
    }

    @Test func stripShowsRedRecordingPillForLiveRecordingSnapshot() {
        let store = makeStore()
        let shell = AppShellViewController(
            navigationController: UINavigationController(rootViewController: UIViewController()),
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
            navigationController: UINavigationController(rootViewController: UIViewController()),
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
            navigationController: UINavigationController(rootViewController: UIViewController()),
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
            navigationController: UINavigationController(rootViewController: spy),
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
            navigationController: UINavigationController(rootViewController: spy),
            store: store
        )
        shell.loadViewIfNeeded()

        store.send(.event(.snapshot(CameraSamples.world())))
        #expect(spy.resumeCount == 0)

        store.send(.streamStopped)
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

    private func makeStore() -> AppStore {
        AppStore(
            initialState: AppFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError("Health is not used by AppShellViewControllerTests.") }),
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
