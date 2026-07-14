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

    @Test(.timeLimit(.minutes(1)))
    func coveredUpdateKeepsProjectionCurrentAndPresentsLatestSnapshotOnReturn() async throws {
        let (controller, appStore) = makeControllerAndAppStore()
        let navigationController = UINavigationController(rootViewController: controller)
        let window = try embed(navigationController)
        defer { window.isHidden = true }
        try await waitUntil {
            controller.layoutCollectionForTesting()
            return controller.rowIDsForTesting.isEmpty == false
        }
        #expect(controller.rowIDsForTesting.contains(.gauge(.storage)) == false)

        let cover = UIViewController()
        navigationController.pushViewController(cover, animated: false)
        window.layoutIfNeeded()
        appStore.send(.event(.snapshot(CameraSamples.world(storage: Storage(used: 600, total: 1_000)))))

        #expect(controller.rowForTesting(.gauge(.storage)) == .gauge(
            id: .storage,
            title: "Storage",
            detail: "600 bytes of 1 KB -- 400 bytes free",
            fraction: 0.6,
            tint: .neutral
        ))
        #expect(controller.rowIDsForTesting.contains(.gauge(.storage)) == false)

        navigationController.popViewController(animated: false)
        window.layoutIfNeeded()

        try await waitUntil {
            controller.layoutCollectionForTesting()
            return controller.rowIDsForTesting.contains(.gauge(.storage))
        }
        #expect(controller.presentedGaugeForTesting(.storage) == .gauge(
            id: .storage,
            title: "Storage",
            detail: "600 bytes of 1 KB -- 400 bytes free",
            fraction: 0.6,
            tint: .neutral
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func liveTelemetryUpdateReconfiguresStableGaugeRows() async throws {
        let world = CameraSamples.world(
            storage: Storage(used: 100, total: 1_000),
            mem: Mem(total: 1_000, available: 800, swapTotal: 1_000, swapUsed: 100)
        )
        let (controller, appStore) = makeControllerAndAppStore(appState: appState(link: .online(world)))
        let window = try embed(controller)
        defer { window.isHidden = true }
        try await waitUntil {
            controller.presentedGaugeForTesting(.storage) != nil &&
                controller.presentedGaugeForTesting(.ram) != nil &&
                controller.presentedGaugeForTesting(.swap) != nil
        }
        let originalIDs = controller.rowIDsForTesting

        appStore.send(.event(.storageChanged(Storage(used: 600, total: 1_000, recordingCapacityBytes: 800))))
        appStore.send(.event(.memChanged(total: 1_000, available: 100, swapTotal: 1_000, swapUsed: 800)))

        try await waitUntil {
            let storage = controller.presentedGaugeForTesting(.storage)
            let ram = controller.presentedGaugeForTesting(.ram)
            let swap = controller.presentedGaugeForTesting(.swap)
            return storage == .gauge(
                id: .storage,
                title: "Storage",
                detail: "600 bytes of 1 KB -- 400 bytes free",
                fraction: 0.6,
                tint: .neutral
            ) && ram == .gauge(
                id: .ram,
                title: "RAM",
                detail: "900 bytes of 1 KB",
                fraction: 0.9,
                tint: .critical
            ) && swap == .gauge(
                id: .swap,
                title: "Swap",
                detail: "800 bytes of 1 KB",
                fraction: 0.8,
                tint: .critical
            )
        }

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

    @Test func temperatureRowsRenderPlainTextWithIndependentTints() throws {
        let world = CameraSamples.world(tempC: TempC(
            soc: TempReading(current: 45, max: 72)
        ))
        let controller = makeController(appState: appState(link: .online(world)))
        let window = try embed(controller)
        defer { window.isHidden = true }

        let current = try #require(controller.secondaryTextForTesting(.socTemperature))
        #expect(current.text == "45.0 C")
        #expect(current.color == .secondaryLabel)

        let max = try #require(controller.secondaryTextForTesting(.socMaxTemperature))
        #expect(max.text == "72.0 C")
        #expect(max.color == .systemOrange)
    }

    @Test func cpuRowUsesFullWidthConfigurationAndSpokenUnavailable() throws {
        let world = CameraSamples.world(cpu: CPU(cores: [
            CPUCore(id: 7, currentPct: nil, oneMinutePct: 95, fiveMinutePct: 52, fifteenMinutePct: 40),
        ]))
        let controller = makeController(appState: appState(link: .online(world)))
        let window = try embed(controller)
        defer { window.isHidden = true }
        #expect(controller.presentedCPUForTesting(7) == DebugCPUConfiguration(
            title: "Core 7",
            detail: "Now -- | 1m 95% | 5m 52% | 15m 40%",
            accessibilityValue: "Now unavailable, 1 minute 95 percent, 5 minutes 52 percent, 15 minutes 40 percent",
            tint: .critical
        ))
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
