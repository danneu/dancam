import Foundation

nonisolated enum HomeSection: Hashable, Sendable {
    case main
}

nonisolated enum HomeRowID: Hashable, Sendable {
    case live(session: UInt64, id: Int)
    case finished(Int)
}

nonisolated enum HomeRowDiff {
    static func reconfiguredIDs(old: [HomeRow], new: [HomeRow]) -> [HomeRowID] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        return new.compactMap { row in
            guard let old = oldByID[row.id], old != row else { return nil }
            return row.id
        }
    }
}
