import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct HealthViewControllerTests {
    @Test func buildExportTextAddsSnapshotHeaderAndRecordsSuccess() async throws {
        let controller = makeController(
            appState: appState(link: .online(CameraSamples.world(phase: .recording))),
            logExporter: LogExporter { since in
                #expect(since == .seconds(600))
                return "[2026-07-01T00:00:00.000Z] [reducer] [notice] action=snapshot"
            }
        )

        let result = await controller.buildExportText()

        let text: String
        switch result {
        case .success(let value):
            text = value
        case .failure(let error):
            Issue.record("Expected export success, got \(error).")
            return
        }

        #expect(text.contains("DanCam log export"))
        #expect(text.contains("App version:"))
        #expect(text.contains("State snapshot: link=online"))
        #expect(text.contains("recording=unknown"))
        #expect(text.contains("[reducer] [notice] action=snapshot"))

        switch controller.lastExportOutcome {
        case .success(let recorded)?:
            #expect(recorded == text)
        case .failure(let error)?:
            Issue.record("Expected recorded success, got \(error).")
        case nil:
            Issue.record("Expected buildExportText to record its outcome.")
        }
    }

    @Test func exportLogsFailureRecordsOutcomeAndShowsVisibleError() async {
        let controller = makeController(
            logExporter: LogExporter { _ in
                throw ExportTestError.denied
            }
        )
        controller.loadViewIfNeeded()

        await controller.exportLogsForTesting()

        switch controller.lastExportOutcome {
        case .failure(let error)?:
            #expect(error.localizedDescription == "Denied")
        case .success(let text)?:
            Issue.record("Expected recorded failure, got \(text).")
        case nil:
            Issue.record("Expected exportLogsForTesting to record its outcome.")
        }

        #expect(controller.isErrorVisible)
        #expect(controller.errorText == "Log export failed: Denied")
    }

    @Test(.timeLimit(.minutes(1)))
    func pullToRefreshLoadsHealthAndEndsSpinnerOnSuccess() async throws {
        let releaseHealth = AsyncSignal()
        let controller = makeController(
            health: gatedHealthClient(
                release: releaseHealth,
                result: .success(healthResponse)
            )
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.pullToRefreshForTesting()

        #expect(controller.statusTextForTesting == "Loading health...")
        #expect(controller.isRefreshingForTesting)
        #expect(controller.isManualRefreshingForTesting)

        await releaseHealth.signal()
        try await waitUntil { controller.statusTextForTesting == "Connected" }

        #expect(controller.isRefreshingForTesting == false)
        #expect(controller.isManualRefreshingForTesting == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func pullToRefreshEndsSpinnerOnHealthFailure() async throws {
        let releaseHealth = AsyncSignal()
        let controller = makeController(
            health: gatedHealthClient(
                release: releaseHealth,
                result: .failure(.http(503))
            )
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.pullToRefreshForTesting()
        await releaseHealth.signal()
        try await waitUntil { controller.statusTextForTesting == "Unable to reach camera" }

        #expect(controller.isRefreshingForTesting == false)
        #expect(controller.isManualRefreshingForTesting == false)
        #expect(controller.isErrorVisible)
        #expect(controller.errorText == "HTTP 503")
    }

    @Test(.timeLimit(.minutes(1)))
    func pullToRefreshReconnectsOfflineAppStore() async throws {
        let world = CameraSamples.world()
        let releaseHealth = AsyncSignal()
        let (controller, appStore) = makeControllerAndAppStore(
            appState: appState(link: .offline(last: nil)),
            health: gatedHealthClient(
                release: releaseHealth,
                result: .success(healthResponse)
            ),
            events: EventsClient {
                AsyncThrowingStream { continuation in
                    continuation.yield(.snapshot(world))
                }
            }
        )
        let window = try embed(controller)
        defer { window.isHidden = true }

        controller.pullToRefreshForTesting()

        try await waitUntil { appStore.state.link == .online(world) }

        await releaseHealth.signal()
        try await waitUntil { controller.statusTextForTesting == "Connected" }
    }

    private func makeController(
        appState: AppFeature.State = AppFeature.State(),
        health: HealthClient = HealthClient(fetch: { throw CancellationError() }),
        logExporter: LogExporter = .noop,
        events: EventsClient = .noop
    ) -> HealthViewController {
        makeControllerAndAppStore(
            appState: appState,
            health: health,
            logExporter: logExporter,
            events: events
        ).0
    }

    private func makeControllerAndAppStore(
        appState: AppFeature.State = AppFeature.State(),
        health: HealthClient = HealthClient(fetch: { throw CancellationError() }),
        logExporter: LogExporter = .noop,
        events: EventsClient = .noop
    ) -> (HealthViewController, AppStore) {
        let dependencies = AppDependencies(
            health: health,
            events: events,
            logExporter: logExporter,
            heartbeatTimeout: { throw CancellationError() }
        )
        let appStore = AppStore(
            initialState: appState,
            dependencies: dependencies,
            reduce: AppFeature.reduce
        )

        return (
            HealthViewController(
                dependencies: dependencies,
                store: appStore
            ),
            appStore
        )
    }

    private var healthResponse: HealthResponse {
        HealthResponse(bootId: "boot-123", uptimeS: 42, recording: true, tMs: 1_000)
    }

    private func gatedHealthClient(
        release: AsyncSignal,
        result: Result<HealthResponse, HealthError>
    ) -> HealthClient {
        HealthClient {
            await release.wait()
            return try result.get()
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
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

    private func appState(link: Link) -> AppFeature.State {
        var state = AppFeature.State()
        state.link = link
        return state
    }
}

private enum ExportTestError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Denied"
    }
}
