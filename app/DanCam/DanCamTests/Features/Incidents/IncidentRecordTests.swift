import Foundation
import Testing
@testable import DanCam

struct IncidentRecordTests {
    @Test func recordRoundTripsUsingSelfDescribingSnakeCaseJSON() throws {
        var record = fixtureRecord()
        record.wanted = [
            IncidentSegment(seq: 41, state: .pulled, etag: "41-etag", durMs: 30_016, bytes: 123),
            IncidentSegment(seq: 42, state: .wanted, etag: "42-etag", durMs: 29_984),
            IncidentSegment(seq: 43)
        ]

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["pressed_at_ms"] as? UInt64 == record.pressedAtMs)
        #expect(object["mark_seq"] as? Int == 43)
        #expect(object["status"] as? String == "pending")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(IncidentRecord.self, from: data) == record)
    }

    @Test func derivedPropertiesCountOnlyPulledArtifacts() {
        var record = fixtureRecord()
        record.wanted = [
            IncidentSegment(seq: 41, state: .pulled, etag: "a", durMs: 30_000, bytes: 100),
            IncidentSegment(seq: 42, state: .lost, etag: "b", durMs: 30_000, bytes: 200),
            IncidentSegment(seq: 43, state: .pulled, etag: "c", durMs: 5_000, bytes: 50)
        ]

        #expect(record.coveredDurationMs == 35_000)
        #expect(record.pulledBytes == 150)
        #expect(record.derivedTerminalStatus == .partial)

        record.wanted[1].state = .clipped
        #expect(record.derivedTerminalStatus == .saved)
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
