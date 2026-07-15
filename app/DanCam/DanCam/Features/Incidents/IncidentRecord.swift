import Foundation

nonisolated enum IncidentStatus: String, Codable, Equatable, Sendable {
    case pending
    case saved
    case partial

    var isTerminal: Bool { self != .pending }
}

nonisolated enum IncidentSegmentState: String, Codable, Equatable, Sendable {
    case unresolved
    case wanted
    case pulled
    case lost
    case clipped
}

nonisolated enum IncidentLossEvidence: String, Codable, Equatable, Sendable {
    case inferredAbsence = "inferred_absence"
    case confirmedMissing = "confirmed_missing"
}

nonisolated struct IncidentSegment: Codable, Equatable, Sendable, Identifiable {
    var seq: Int
    var state: IncidentSegmentState
    var etag: String?
    var durMs: UInt64?
    var bytes: UInt64?
    var lossEvidence: IncidentLossEvidence?

    var id: Int { seq }

    init(
        seq: Int,
        state: IncidentSegmentState = .unresolved,
        etag: String? = nil,
        durMs: UInt64? = nil,
        bytes: UInt64? = nil,
        lossEvidence: IncidentLossEvidence? = nil
    ) {
        self.seq = seq
        self.state = state
        self.etag = etag
        self.durMs = durMs
        self.bytes = bytes
        self.lossEvidence = lossEvidence
    }

    mutating func resolve(etag: String, durMs: UInt64) {
        guard state == .unresolved else { return }
        state = .wanted
        self.etag = etag
        self.durMs = durMs
        lossEvidence = nil
    }

    mutating func markPulled(bytes: UInt64) {
        state = .pulled
        self.bytes = bytes
        lossEvidence = nil
    }

    mutating func markLost(_ evidence: IncidentLossEvidence) {
        guard state == .unresolved || state == .wanted else { return }
        state = .lost
        lossEvidence = evidence
    }

    mutating func confirmMissing() {
        guard state == .unresolved
            || state == .wanted
            || (state == .lost && lossEvidence == .inferredAbsence) else { return }
        state = .lost
        lossEvidence = .confirmedMissing
    }

    mutating func markClipped() {
        guard state == .unresolved else { return }
        state = .clipped
    }

    mutating func reopen(etag: String, durMs: UInt64) {
        guard state == .clipped || (state == .lost && lossEvidence == .inferredAbsence) else { return }
        state = .wanted
        self.etag = etag
        self.durMs = durMs
        bytes = nil
        lossEvidence = nil
    }

    private enum CodingKeys: String, CodingKey {
        case seq
        case state
        case etag
        case durMs
        case bytes
        case lossEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        state = try container.decode(IncidentSegmentState.self, forKey: .state)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        durMs = try container.decodeIfPresent(UInt64.self, forKey: .durMs)
        bytes = try container.decodeIfPresent(UInt64.self, forKey: .bytes)
        lossEvidence = try container.decodeIfPresent(IncidentLossEvidence.self, forKey: .lossEvidence)
        if state == .lost, lossEvidence == nil {
            lossEvidence = etag == nil && durMs == nil ? .inferredAbsence : .confirmedMissing
        }
    }
}

nonisolated struct IncidentRecord: Codable, Equatable, Sendable, Identifiable {
    static let defaultPreMs: UInt64 = 30_000
    static let defaultPostMs: UInt64 = 15_000
    static let defaultSlackMs: UInt64 = 2_000
    static let pressLockoutSpan: TimeInterval = TimeInterval(defaultPostMs + defaultSlackMs) / 1_000

    var id: UUID
    var pressedAtMs: UInt64
    var bootTag: String
    var session: UInt64
    var markSeq: Int
    var markAgeMs: UInt64
    var preMs: UInt64
    var postMs: UInt64
    var slackMs: UInt64
    var wanted: [IncidentSegment]

    init(
        id: UUID = UUID(),
        pressedAtMs: UInt64,
        recordingID: RecordingID,
        markSeq: Int,
        markAgeMs: UInt64,
        preMs: UInt64 = Self.defaultPreMs,
        postMs: UInt64 = Self.defaultPostMs,
        slackMs: UInt64 = Self.defaultSlackMs,
        wanted: [IncidentSegment]? = nil
    ) {
        self.id = id
        self.pressedAtMs = pressedAtMs
        bootTag = recordingID.bootTag
        session = recordingID.session
        self.markSeq = markSeq
        self.markAgeMs = markAgeMs
        self.preMs = preMs
        self.postMs = postMs
        self.slackMs = slackMs
        self.wanted = wanted ?? [IncidentSegment(seq: markSeq)]
    }

    var recordingID: RecordingID {
        RecordingID(bootTag: bootTag, session: session)
    }

    var coveredDurationMs: UInt64 {
        wanted.lazy
            .filter { $0.state == .pulled }
            .compactMap(\.durMs)
            .reduce(0, +)
    }

    var pulledBytes: UInt64 {
        wanted.lazy
            .filter { $0.state == .pulled }
            .compactMap(\.bytes)
            .reduce(0, +)
    }

    var status: IncidentStatus {
        guard wanted.allSatisfy({ $0.state != .unresolved && $0.state != .wanted }) else {
            return .pending
        }
        return wanted.contains { $0.state == .lost } ? .partial : .saved
    }

    mutating func updateSegment(_ segment: IncidentSegment) {
        if let index = wanted.firstIndex(where: { $0.seq == segment.seq }) {
            wanted[index] = segment
        } else {
            wanted.append(segment)
            wanted.sort { $0.seq < $1.seq }
        }
    }

    func segment(seq: Int) -> IncidentSegment? {
        wanted.first { $0.seq == seq }
    }
}
