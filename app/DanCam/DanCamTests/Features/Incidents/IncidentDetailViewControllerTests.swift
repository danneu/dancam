import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct IncidentDetailViewControllerTests {
    @Test func rawFallbackIsShareOnlyAndUsesFriendlyTSFilename() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "dancam-incident-detail-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let incidentStore = IncidentStore.live(rootDirectory: root)
        let record = fixtureRecord()
        let directory = incidentStore.directoryURL(record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "seg_00043.ts")
        try Data([0x47, 0x00]).write(to: source)
        var appState = AppFeature.State()
        appState.incidents.incidents = [record]
        let store = AppStore(
            initialState: appState,
            dependencies: AppDependencies(incidentStore: incidentStore),
            reduce: AppFeature.reduce
        )
        let controller = IncidentDetailViewController(
            dependencies: AppDependencies(incidentStore: incidentStore),
            store: store,
            incidentID: record.id
        )
        controller.exportTimeZone = try #require(TimeZone(secondsFromGMT: 0))

        controller.loadViewIfNeeded()

        let row = try #require(controller.rowsForTesting.first)
        #expect(row.isPlayable == false)
        #expect(row.kind == .ts)
        let artifact = try #require(controller.makeShareArtifactForTesting(row: row))
        defer { if let directory = artifact.temporaryDirectory { try? FileManager.default.removeItem(at: directory) } }
        #expect(artifact.url.lastPathComponent == "Dashcam Incident 2026-07-19 17-02-03 seg_00043.ts")
        #expect(try Data(contentsOf: artifact.url) == Data([0x47, 0x00]))
    }

    private func fixtureRecord() -> IncidentRecord {
        IncidentRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            pressedAtMs: 1_784_480_523_000,
            recordingID: RecordingID(bootTag: "boot", session: 7),
            markSeq: 43,
            markAgeMs: 12_000,
            wanted: [
                IncidentSegment(seq: 42, state: .lost, lossEvidence: .inferredAbsence),
                IncidentSegment(seq: 43, state: .pulled, durMs: 30_000, bytes: 2),
            ]
        )
    }
}
