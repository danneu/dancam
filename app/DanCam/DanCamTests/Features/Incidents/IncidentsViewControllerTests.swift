import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct IncidentsViewControllerTests {
    @Test func deleteRemovesDirectoryAndProjectedRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "dancam-incident-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let incidentStore = IncidentStore.live(rootDirectory: root)
        let record = fixtureRecord()
        try await incidentStore.create(record)
        var initialState = IncidentsFeature.State()
        initialState.incidents = [record]
        let testStore = TestStore(
            initialState: initialState,
            dependencies: AppDependencies(incidentStore: incidentStore),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: nil,
                    dependencies: dependencies
                )
            }
        )

        await testStore.send(.deleteTapped(.readable(record.id)))
        await testStore.receive(.deleteResponded(.readable(record.id), success: true)) {
            $0.incidents = []
        }

        #expect(FileManager.default.fileExists(atPath: incidentStore.directoryURL(record.id).path) == false)
        #expect(IncidentListProjection.project(testStore.state).rows.isEmpty)
    }

    @Test func storeLoadKeepsUnreadableDirectoryAsDeletableRow() async throws {
        let directory = URL(filePath: "/tmp/opaque")
        let stored: StoredIncident = .unreadable(directoryName: "opaque", directoryURL: directory)
        let testStore = TestStore(
            initialState: IncidentsFeature.State(),
            dependencies: AppDependencies(),
            reduce: { state, action, dependencies in
                IncidentsFeature.reduce(
                    state: &state,
                    action: action,
                    world: nil,
                    dependencies: dependencies
                )
            }
        )

        await testStore.send(.storeLoaded([stored])) {
            $0.hasLoadedStore = true
            $0.unreadableDirectoryNames = ["opaque"]
        }

        #expect(IncidentListProjection.project(testStore.state).rows.first?.id == .unreadable("opaque"))
    }

    @Test(.timeLimit(.minutes(1)))
    func coveredUpdateKeepsProjectionCurrentAndRefreshesLatestHeaderOnReturn() async throws {
        let first = fixtureRecord()
        let second = fixtureRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!,
            pressedAtMs: first.pressedAtMs + 1_000
        )
        var state = AppFeature.State()
        state.incidents.hasLoadedStore = true
        state.incidents.incidents = [first]
        let dependencies = AppDependencies(heartbeatTimeout: { throw CancellationError() })
        let store = AppStore(initialState: state, dependencies: dependencies, reduce: AppFeature.reduce)
        let controller = IncidentsViewController(dependencies: dependencies, store: store)
        let navigationController = UINavigationController(rootViewController: controller)
        let window = try embed(navigationController)
        defer { window.isHidden = true }

        try await waitUntil {
            controller.layoutCollectionForTesting()
            return controller.presentedItemIDsForTesting == [.readable(first.id)] &&
                controller.presentedHeaderTextForTesting == "1 incident - Zero KB"
        }
        let cover = UIViewController()
        navigationController.pushViewController(cover, animated: false)
        window.layoutIfNeeded()

        store.send(.incidents(.storeLoaded([
            .readable(record: first, directoryURL: URL(filePath: "/tmp/first")),
            .readable(record: second, directoryURL: URL(filePath: "/tmp/second")),
        ])))

        #expect(controller.projectionForTesting.rows.map(\.id) == [
            .readable(second.id),
            .readable(first.id),
        ])
        #expect(controller.presentedItemIDsForTesting == [.readable(first.id)])

        navigationController.popViewController(animated: false)
        window.layoutIfNeeded()

        try await waitUntil {
            controller.layoutCollectionForTesting()
            return controller.presentedItemIDsForTesting == [.readable(second.id), .readable(first.id)] &&
                controller.presentedHeaderTextForTesting == "2 incidents - Zero KB"
        }
    }

    private func fixtureRecord(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
        pressedAtMs: UInt64 = 1_784_480_523_000
    ) -> IncidentRecord {
        IncidentRecord(
            id: id,
            pressedAtMs: pressedAtMs,
            recordingID: RecordingID(bootTag: "boot", session: 7),
            markSeq: 43,
            markAgeMs: 12_000
        )
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

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
    }
}
