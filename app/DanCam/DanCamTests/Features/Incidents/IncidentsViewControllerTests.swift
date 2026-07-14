import Foundation
import Testing
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

    private func fixtureRecord() -> IncidentRecord {
        IncidentRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            pressedAtMs: 1_784_480_523_000,
            recordingID: RecordingID(bootTag: "boot", session: 7),
            markSeq: 43,
            markAgeMs: 12_000
        )
    }
}
