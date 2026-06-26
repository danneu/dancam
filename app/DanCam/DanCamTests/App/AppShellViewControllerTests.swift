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
            monitor: store
        )
        shell.loadViewIfNeeded()

        store.send(.statusResponse(.failure(.http(503))))
        store.send(.statusResponse(.failure(.transport("lost"))))
        store.send(.statusResponse(.failure(.decoding("bad"))))
        #expect(spy.resumeCount == 0)

        store.send(.statusResponse(.success(.sample(recording: true))))
        #expect(spy.resumeCount == 1)

        store.send(.stop)
    }

    @Test func firstContactConnectDoesNotResume() {
        let store = makeStore()
        let spy = ResumeSpy()
        let shell = AppShellViewController(
            navigationController: UINavigationController(rootViewController: spy),
            monitor: store
        )
        shell.loadViewIfNeeded()

        store.send(.statusResponse(.success(.sample(recording: true))))
        #expect(spy.resumeCount == 0)

        store.send(.stop)
    }

    private func makeStore() -> Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies> {
        Store(
            initialState: ConnectionFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError("Health is not used by AppShellViewControllerTests.") }),
                status: StatusClient(fetch: {
                    try await Task.sleep(for: .seconds(60))
                    return StatusResponse.sample(recording: false)
                }),
                sleep: { _ in
                    try? await Task.sleep(for: .seconds(60))
                }
            ),
            reduce: ConnectionFeature.reduce
        )
    }
}

private final class ResumeSpy: UIViewController, ConnectionResumable {
    private(set) var resumeCount = 0

    func resumeLiveWork() {
        resumeCount += 1
    }
}

private extension StatusResponse {
    static func sample(recording: Bool, uptimeS: UInt64 = 1) -> StatusResponse {
        StatusResponse(
            recording: recording,
            cameraState: .running,
            bootId: "boot-123",
            uptimeS: uptimeS,
            storage: Storage(used: 100, total: 1000),
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil
        )
    }
}
