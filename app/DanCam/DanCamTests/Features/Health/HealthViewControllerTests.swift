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

    private func makeController(
        appState: AppFeature.State = AppFeature.State(),
        logExporter: LogExporter
    ) -> HealthViewController {
        let dependencies = AppDependencies(
            health: HealthClient(fetch: { throw CancellationError() }),
            logExporter: logExporter,
            heartbeatTimeout: { throw CancellationError() }
        )

        return HealthViewController(
            dependencies: dependencies,
            store: AppStore(
                initialState: appState,
                dependencies: dependencies,
                reduce: AppFeature.reduce
            )
        )
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
