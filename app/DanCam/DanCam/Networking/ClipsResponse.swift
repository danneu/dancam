import Foundation

nonisolated struct ClipCursor: Equatable, Comparable, Sendable {
    let rawValue: UInt32

    init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static func < (lhs: ClipCursor, rhs: ClipCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension ClipCursor: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let encoded = try? container.decode(String.self) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Clip cursor must be encoded as a string."
            )
        }
        guard let rawValue = UInt32(encoded), String(rawValue) == encoded else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Clip cursor must be a canonical UInt32 decimal string."
            )
        }
        self.init(rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(rawValue))
    }
}

nonisolated struct ClipsResponse: Codable, Equatable, Sendable {
    var clips: [Clip]
    var serverTimeMs: UInt64?
    var nextCursor: ClipCursor?
}

nonisolated struct Clip: Codable, Equatable, Sendable {
    var id: Int
    var startMs: UInt64?
    var durMs: UInt64?
    var bytes: UInt64
    var locked: Bool
    var etag: String
    var timeApproximate: Bool
    var bootTag: String? = nil
    var session: UInt64? = nil
}

nonisolated struct RecordingID: Hashable, Sendable {
    var bootTag: String
    var session: UInt64
}

extension Clip {
    /// Non-nil only when the Pi recorded this clip with verified wall-clock time.
    nonisolated var resolvedStartDate: Date? {
        guard let startMs, timeApproximate == false else { return nil }

        return Date(timeIntervalSince1970: Double(startMs) / 1_000)
    }

    /// Non-nil only when the clip carries both stamped facts (all-or-nothing on the wire).
    nonisolated var recordingID: RecordingID? {
        guard let bootTag, let session else { return nil }
        return RecordingID(bootTag: bootTag, session: session)
    }
}
