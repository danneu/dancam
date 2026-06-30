import Testing
import UIKit
@testable import DanCam

@MainActor
struct AppShellViewControllerTests {
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
}

private final class ResumeSpy: UIViewController, ConnectionResumable {
    private(set) var resumeCount = 0

    func resumeLiveWork() {
        resumeCount += 1
    }
}
