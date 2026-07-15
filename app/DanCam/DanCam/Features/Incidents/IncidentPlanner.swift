import Foundation

nonisolated enum IncidentListCoverage: Equatable, Sendable {
    case unloaded
    case loaded(epoch: ClipCoverageEpoch, nextCursor: ClipCursor?)

    func covers(_ seq: Int) -> Bool {
        switch self {
        case .unloaded:
            false
        case .loaded(_, nil):
            true
        case .loaded(_, let cursor?):
            seq >= Int(cursor.rawValue)
        }
    }
}

nonisolated enum IncidentRecorderState: Equatable, Sendable {
    case unknown
    case recording(RecordingID)
    case notRecording

    func isActive(_ recordingID: RecordingID) -> Bool {
        self == .recording(recordingID)
    }

    func provesSessionEnded(_ recordingID: RecordingID) -> Bool {
        switch self {
        case .unknown:
            false
        case .recording(let current):
            current != recordingID
        case .notRecording:
            true
        }
    }
}

nonisolated enum IncidentPlannerCommand: Equatable, Sendable {
    case persist(IncidentRecord)
    case pull(seq: Int, etag: String, incidentIDs: [UUID])
    case requireCoverage(ClipCursor)
}

nonisolated enum IncidentPlanner {
    static func plan(
        incidents: [IncidentRecord],
        clips: [Clip],
        listCoverage: IncidentListCoverage,
        recorder: IncidentRecorderState
    ) -> [IncidentPlannerCommand] {
        let clipsBySeq = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var commands: [IncidentPlannerCommand] = []
        var pullRequests: [PullKey: Set<UUID>] = [:]
        var requiredBoundary: ClipCursor?

        for original in incidents {
            var record = original
            var changed = false
            var recordBoundary: ClipCursor?

            resolve(seq: record.markSeq, in: &record, clipsBySeq: clipsBySeq, changed: &changed)
            walkPreRoll(
                record: &record,
                clipsBySeq: clipsBySeq,
                coverage: listCoverage,
                changed: &changed,
                requiredBoundary: &recordBoundary
            )
            walkPostRoll(
                record: &record,
                clipsBySeq: clipsBySeq,
                coverage: listCoverage,
                recorder: recorder,
                changed: &changed,
                requiredBoundary: &recordBoundary
            )

            if changed {
                commands.append(.persist(record))
            } else {
                if record.status == .pending {
                    for segment in record.wanted where segment.state == .wanted {
                        guard let etag = segment.etag else { continue }
                        pullRequests[PullKey(seq: segment.seq, etag: etag), default: []].insert(record.id)
                    }
                }
            }

            if let recordBoundary {
                requiredBoundary = requiredBoundary.map { min($0, recordBoundary) } ?? recordBoundary
            }
        }

        if let requiredBoundary {
            commands.append(.requireCoverage(requiredBoundary))
        }

        for key in pullRequests.keys.sorted(by: { ($0.seq, $0.etag) < ($1.seq, $1.etag) }) {
            let ids = pullRequests[key, default: []].sorted { $0.uuidString < $1.uuidString }
            commands.append(.pull(seq: key.seq, etag: key.etag, incidentIDs: ids))
        }
        return commands
    }

    private static func walkPreRoll(
        record: inout IncidentRecord,
        clipsBySeq: [Int: Clip],
        coverage: IncidentListCoverage,
        changed: inout Bool,
        requiredBoundary: inout ClipCursor?
    ) {
        var remaining = saturatingSubtract(record.preMs + record.slackMs, record.markAgeMs)
        var seq = record.markSeq - 1

        while remaining > 0 && seq >= 0 {
            var segment = record.segment(seq: seq) ?? IncidentSegment(seq: seq)
            if record.segment(seq: seq) == nil {
                record.updateSegment(segment)
                changed = true
            }
            resolve(seq: seq, in: &record, clipsBySeq: clipsBySeq, changed: &changed)
            segment = record.segment(seq: seq) ?? segment

            if segment.state == .unresolved {
                guard coverage.covers(seq) else {
                    let boundary = ClipCursor(UInt32(clamping: seq))
                    requiredBoundary = requiredBoundary.map { min($0, boundary) } ?? boundary
                    break
                }
                if hasWitnessBeyond(seq: seq, direction: .backward, record: record, clips: clipsBySeq) {
                    segment.markLost(.inferredAbsence)
                } else {
                    segment.markClipped()
                }
                record.updateSegment(segment)
                changed = true
            }

            guard segment.state != .clipped else { break }
            guard let duration = segment.durMs else { break }
            remaining = saturatingSubtract(remaining, duration)
            seq -= 1
        }
    }

    private static func walkPostRoll(
        record: inout IncidentRecord,
        clipsBySeq: [Int: Clip],
        coverage: IncidentListCoverage,
        recorder: IncidentRecorderState,
        changed: inout Bool,
        requiredBoundary: inout ClipCursor?
    ) {
        guard var mark = record.segment(seq: record.markSeq) else { return }
        if mark.state == .unresolved {
            if recorder.provesSessionEnded(record.recordingID) && coverage.covers(record.markSeq) {
                mark.markLost(.inferredAbsence)
                record.updateSegment(mark)
                changed = true
            } else if coverage.covers(record.markSeq) == false {
                let boundary = ClipCursor(UInt32(clamping: record.markSeq))
                requiredBoundary = requiredBoundary.map { min($0, boundary) } ?? boundary
            }
        }
        guard let markDuration = mark.durMs else { return }

        var remaining = saturatingSubtract(record.markAgeMs + record.postMs + record.slackMs, markDuration)
        var seq = record.markSeq + 1
        while remaining > 0 {
            var segment = record.segment(seq: seq) ?? IncidentSegment(seq: seq)
            if record.segment(seq: seq) == nil {
                record.updateSegment(segment)
                changed = true
            }
            resolve(seq: seq, in: &record, clipsBySeq: clipsBySeq, changed: &changed)
            segment = record.segment(seq: seq) ?? segment

            if segment.state == .unresolved {
                if recorder.isActive(record.recordingID) {
                    break
                }
                guard recorder.provesSessionEnded(record.recordingID) else { break }
                guard coverage.covers(seq) else {
                    let boundary = ClipCursor(UInt32(clamping: seq))
                    requiredBoundary = requiredBoundary.map { min($0, boundary) } ?? boundary
                    break
                }
                if hasWitnessBeyond(seq: seq, direction: .forward, record: record, clips: clipsBySeq) {
                    segment.markLost(.inferredAbsence)
                } else {
                    segment.markClipped()
                }
                record.updateSegment(segment)
                changed = true
            }

            guard segment.state != .clipped else { break }
            guard let duration = segment.durMs else { break }
            remaining = saturatingSubtract(remaining, duration)
            seq += 1
        }
    }

    private static func resolve(
        seq: Int,
        in record: inout IncidentRecord,
        clipsBySeq: [Int: Clip],
        changed: inout Bool
    ) {
        guard var segment = record.segment(seq: seq),
              let clip = clipsBySeq[seq], clip.recordingID == record.recordingID,
              let duration = clip.durMs else { return }
        switch segment.state {
        case .unresolved:
            segment.resolve(etag: clip.etag, durMs: duration)
        case .clipped:
            segment.reopen(etag: clip.etag, durMs: duration)
        case .lost where segment.lossEvidence == .inferredAbsence:
            segment.reopen(etag: clip.etag, durMs: duration)
        case .lost:
            return
        case .wanted, .pulled:
            return
        }
        record.updateSegment(segment)
        changed = true
    }

    private static func hasWitnessBeyond(
        seq: Int,
        direction: WalkDirection,
        record: IncidentRecord,
        clips: [Int: Clip]
    ) -> Bool {
        let recordedSeqs = record.wanted.compactMap { segment -> Int? in
            guard segment.durMs != nil else { return nil }
            return segment.seq
        }
        let listedSeqs = clips.values.compactMap { clip -> Int? in
            guard clip.recordingID == record.recordingID, clip.durMs != nil else { return nil }
            return clip.id
        }
        switch direction {
        case .backward:
            return (recordedSeqs + listedSeqs).contains { $0 < seq }
        case .forward:
            return (recordedSeqs + listedSeqs).contains { $0 > seq }
        }
    }

    private static func saturatingSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : 0
    }

    private struct PullKey: Hashable {
        var seq: Int
        var etag: String
    }

    private enum WalkDirection {
        case backward
        case forward
    }
}
