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
        shell.loadViewIfNeeded()

        store.send(.connection(.statusResponse(.failure(.http(503)))))
        store.send(.connection(.statusResponse(.failure(.transport("lost")))))
        store.send(.connection(.statusResponse(.failure(.decoding("bad")))))
        #expect(spy.resumeCount == 0)

        store.send(.connection(.statusResponse(.success(.sample(recording: true)))))
        #expect(spy.resumeCount == 1)

        store.send(.connection(.stop))
    }

    @Test func firstContactConnectDoesNotResume() {
        let store = makeStore()
        let spy = ResumeSpy()
        let shell = AppShellViewController(
            navigationController: UINavigationController(rootViewController: spy),
            store: store
        )
        shell.loadViewIfNeeded()

        store.send(.connection(.statusResponse(.success(.sample(recording: true)))))
        #expect(spy.resumeCount == 0)

        store.send(.connection(.stop))
    }

    private func makeStore() -> AppStore {
        AppStore(
            initialState: AppFeature.State(),
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
