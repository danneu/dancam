import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct DebugViewControllerTests {
    @Test func buildExportTextAddsSnapshotHeaderAndRecordsSuccess() async {
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

    @Test func exportFailureRecordsOutcomeAndShowsInlineError() async {
        let controller = makeController(logExporter: LogExporter { _ in throw ExportTestError.denied })
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
        #expect(controller.rowForTesting(.exportError) == .exportError("Log export failed: Denied"))
    }

    @Test func successfulExportClearsPriorInlineErrorOnSameController() async {
        let exporter = ExportSequence()
        let controller = makeController(logExporter: LogExporter { _ in
            try await exporter.next()
        })
        controller.loadViewIfNeeded()

        await controller.exportLogsForTesting()
        #expect(controller.rowForTesting(.exportError) == .exportError("Log export failed: Denied"))

        await controller.exportLogsForTesting()
        #expect(controller.rowForTesting(.exportError) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func pullToRefreshReconnectsOfflineAppStoreAndEndsSpinnerImmediately() async throws {
        let world = CameraSamples.world()
        let (controller, appStore) = makeControllerAndAppStore(
            appState: appState(link: .offline(last: nil)),
            events: EventsClient {
                AsyncThrowingStream { continuation in
                    continuation.yield(.snapshot(world))
                }
            }
        )
        controller.loadViewIfNeeded()

        controller.pullToRefreshForTesting()

        #expect(controller.isRefreshingForTesting == false)
        try await waitUntil { appStore.state.link == .online(world) }
    }

    @Test func snapshotRendersStorageGauge() {
        let world = CameraSamples.world(storage: Storage(used: 250, total: 1_000))
        let (controller, appStore) = makeControllerAndAppStore()
        controller.loadViewIfNeeded()

        appStore.send(.event(.snapshot(world)))

        #expect(controller.rowForTesting(.gauge(.storage)) == .gauge(
            id: .storage,
            title: "Storage",
            detail: "250 bytes of 1 KB -- 750 bytes free",
            fraction: 0.25,
            tint: .neutral
        ))
    }

    @Test func liveTelemetryUpdateReconfiguresStableGaugeRows() throws {
        let world = CameraSamples.world(
            storage: Storage(used: 100, total: 1_000),
            mem: Mem(total: 1_000, available: 800, swapTotal: 1_000, swapUsed: 100)
        )
        let (controller, appStore) = makeControllerAndAppStore(appState: appState(link: .online(world)))
        let window = try embed(controller)
        defer { window.isHidden = true }
        let originalIDs = controller.rowIDsForTesting
        _ = try #require(controller.presentedGaugeForTesting(.storage))
        _ = try #require(controller.presentedGaugeForTesting(.ram))
        _ = try #require(controller.presentedGaugeForTesting(.swap))

        appStore.send(.event(.storageChanged(used: 600, total: 1_000)))
        appStore.send(.event(.memChanged(total: 1_000, available: 100, swapTotal: 1_000, swapUsed: 800)))

        #expect(controller.rowIDsForTesting == originalIDs)
        #expect(controller.presentedGaugeForTesting(.storage) == .gauge(
            id: .storage,
            title: "Storage",
            detail: "600 bytes of 1 KB -- 400 bytes free",
            fraction: 0.6,
            tint: .neutral
        ))
        #expect(controller.presentedGaugeForTesting(.ram) == .gauge(
            id: .ram,
            title: "RAM",
            detail: "900 bytes of 1 KB",
            fraction: 0.9,
            tint: .critical
        ))
        #expect(controller.presentedGaugeForTesting(.swap) == .gauge(
            id: .swap,
            title: "Swap",
            detail: "800 bytes of 1 KB",
            fraction: 0.8,
            tint: .critical
        ))
    }

    @Test func temperatureValueRendersIndependentAttributedTintRuns() throws {
        let world = CameraSamples.world(tempC: TempC(
            soc: TempReading(current: 45, max: 72)
        ))
        let controller = makeController(appState: appState(link: .online(world)))
        let window = try embed(controller)
        defer { window.isHidden = true }

        let attributed = try #require(controller.secondaryAttributedTextForTesting(.socTemperature))
        let detailStart = "45.0 C ".utf16.count

        #expect(attributed.string == "45.0 C (max 72.0)")
        #expect(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .secondaryLabel)
        #expect(
            attributed.attribute(.foregroundColor, at: detailStart, effectiveRange: nil) as? UIColor == .systemOrange
        )
    }

    private func makeController(
        appState: AppFeature.State = AppFeature.State(),
        logExporter: LogExporter = .noop,
        events: EventsClient = .noop
    ) -> DebugViewController {
        makeControllerAndAppStore(
            appState: appState,
            logExporter: logExporter,
            events: events
        ).0
    }

    private func makeControllerAndAppStore(
        appState: AppFeature.State = AppFeature.State(),
        logExporter: LogExporter = .noop,
        events: EventsClient = .noop
    ) -> (DebugViewController, AppStore) {
        let dependencies = AppDependencies(
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
            DebugViewController(dependencies: dependencies, store: appStore),
            appStore
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
    }

    private func embed(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
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

private actor ExportSequence {
    private var attempt = 0

    func next() throws -> String {
        defer { attempt += 1 }
        if attempt == 0 {
            throw ExportTestError.denied
        }
        return "logs"
    }
}

private enum ExportTestError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Denied"
    }
}
