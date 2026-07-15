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
        #expect(object["status"] == nil)

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
        #expect(record.status == .partial)

        record.wanted[1].state = .clipped
        #expect(record.status == .saved)
    }

    @Test(arguments: [
        LegacyLossCase(etag: nil, durMs: nil, expected: .inferredAbsence),
        LegacyLossCase(etag: "445-31098020", durMs: 24_100, expected: .confirmedMissing),
    ])
    func legacyStatusIsIgnoredAndLostEvidenceIsInferred(testCase: LegacyLossCase) throws {
        let etag = testCase.etag.map { "\"etag\": \"\($0)\"," } ?? ""
        let duration = testCase.durMs.map { "\"dur_ms\": \($0)," } ?? ""
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000445",
          "pressed_at_ms": 1784480523000,
          "boot_tag": "boot",
          "session": 194,
          "mark_seq": 445,
          "mark_age_ms": 12000,
          "pre_ms": 30000,
          "post_ms": 15000,
          "slack_ms": 2000,
          "status": "partial",
          "wanted": [{
            "seq": 445,
            "state": "lost",
            \(etag)
            \(duration)
            "bytes": null
          }]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let record = try decoder.decode(IncidentRecord.self, from: Data(json.utf8))

        #expect(record.status == .partial)
        #expect(record.wanted[0].lossEvidence == testCase.expected)
    }

    @Test func newLossEvidenceRoundTripsWithoutPersistingStatus() throws {
        var record = fixtureRecord()
        record.wanted = [IncidentSegment(
            seq: 43,
            state: .lost,
            etag: "43-etag",
            durMs: 30_000,
            lossEvidence: .confirmedMissing
        )]
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wanted = try #require((object["wanted"] as? [[String: Any]])?.first)

        #expect(object["status"] == nil)
        #expect(wanted["loss_evidence"] as? String == "confirmed_missing")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(IncidentRecord.self, from: data) == record)
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

struct LegacyLossCase: Sendable {
    var etag: String?
    var durMs: UInt64?
    var expected: IncidentLossEvidence
}
