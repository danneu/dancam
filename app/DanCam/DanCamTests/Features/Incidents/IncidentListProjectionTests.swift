import Foundation
import Testing
@testable import DanCam

struct IncidentListProjectionTests {
    @Test func rowsAreNewestFirstWithLiveStatusAndHeaderTotals() {
        let older = record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pressedAtMs: 1_000,
            status: .saved,
            segments: [IncidentSegment(seq: 1, state: .pulled, durMs: 30_000, bytes: 10)]
        )
        let newer = record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            pressedAtMs: 2_000,
            status: .pending,
            segments: [IncidentSegment(seq: 2, state: .pulled, durMs: 15_000, bytes: 20)]
        )
        var state = IncidentsFeature.State()
        state.incidents = [older, newer]
        state.unreadableDirectoryNames = ["broken"]

        let projection = IncidentListProjection.project(state)

        #expect(projection.rows.map(\.id) == [
            .readable(newer.id),
            .readable(older.id),
            .unreadable("broken"),
        ])
        #expect(projection.rows.map(\.status) == [.saving, .saved, .unreadable])
        #expect(projection.rows.map(\.coveredDurationMs) == [15_000, 30_000, 0])
        #expect(projection.count == 3)
        #expect(projection.totalBytes == 30)
    }

    @Test func partialRecordProjectsPartialBadge() {
        var state = IncidentsFeature.State()
        state.incidents = [record(
            id: UUID(),
            pressedAtMs: 1_000,
            status: .partial,
            segments: []
        )]

        #expect(IncidentListProjection.project(state).rows.first?.status == .partial)
    }

    private func record(
        id: UUID,
        pressedAtMs: UInt64,
        status: IncidentStatus,
        segments: [IncidentSegment]
    ) -> IncidentRecord {
        IncidentRecord(
            id: id,
            pressedAtMs: pressedAtMs,
            recordingID: RecordingID(bootTag: "boot", session: 1),
            markSeq: segments.first?.seq ?? 1,
            markAgeMs: 0,
            status: status,
            wanted: segments
        )
    }
}
