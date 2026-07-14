import Foundation

nonisolated enum IncidentListItemID: Hashable, Sendable {
    case readable(UUID)
    case unreadable(String)
}

nonisolated enum IncidentListStatus: Equatable, Sendable {
    case saving
    case saved
    case partial
    case unreadable
}

nonisolated struct IncidentListRow: Equatable, Sendable, Identifiable {
    var id: IncidentListItemID
    var record: IncidentRecord?
    var pressedAt: Date?
    var coveredDurationMs: UInt64
    var bytes: UInt64
    var status: IncidentListStatus
}

nonisolated struct IncidentListProjection: Equatable, Sendable {
    var rows: [IncidentListRow]
    var count: Int
    var totalBytes: UInt64

    static func project(_ state: IncidentsFeature.State) -> IncidentListProjection {
        let readableRows = state.incidents
            .sorted { $0.pressedAtMs > $1.pressedAtMs }
            .map { record in
                let status: IncidentListStatus = switch record.status {
                case .pending: .saving
                case .saved: .saved
                case .partial: .partial
                }
                return IncidentListRow(
                    id: .readable(record.id),
                    record: record,
                    pressedAt: Date(timeIntervalSince1970: Double(record.pressedAtMs) / 1_000),
                    coveredDurationMs: record.coveredDurationMs,
                    bytes: record.pulledBytes,
                    status: status
                )
            }
        let unreadableRows = state.unreadableDirectoryNames.sorted().map { directoryName in
            IncidentListRow(
                id: .unreadable(directoryName),
                record: nil,
                pressedAt: nil,
                coveredDurationMs: 0,
                bytes: 0,
                status: .unreadable
            )
        }
        return IncidentListProjection(
            rows: readableRows + unreadableRows,
            count: readableRows.count + unreadableRows.count,
            totalBytes: readableRows.reduce(0) { $0 + $1.bytes }
        )
    }
}
