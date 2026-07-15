import Foundation
import Testing
@testable import DanCam

struct IncidentPlannerTests {
    @Test(arguments: [
        PlannerCase(duration: 30_000, markAge: 1_000, expected: [41, 42, 43]),
        PlannerCase(duration: 30_000, markAge: 29_000, expected: [42, 43, 44]),
        PlannerCase(duration: 5_000, markAge: 2_000, expected: [44, 45, 46, 47, 48, 49, 50, 51, 52, 53]),
        PlannerCase(duration: 5_000, markAge: 4_000, expected: [44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54])
    ])
    func walksWholeSegmentsAtRealAndMockDurations(testCase: PlannerCase) throws {
        let record = fixtureRecord(markSeq: 43, markAge: testCase.markAge)
        let center = testCase.duration == 5_000 ? 50 : 43
        let adjusted = fixtureRecord(markSeq: center, markAge: testCase.markAge)
        let clips = (35...60).map { clip(seq: $0, duration: testCase.duration) }

        let persisted = try persistedRecord(from: IncidentPlanner.plan(
            incidents: [testCase.duration == 5_000 ? adjusted : record],
            clips: clips,
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .recording(recordingID)
        ))

        #expect(persisted.wanted.map(\.seq) == testCase.expected)
        #expect(persisted.wanted.allSatisfy { $0.state == .wanted })
    }

    @Test(arguments: [
        BoundaryCase(preMs: 28_000, expected: [42, 43]),
        BoundaryCase(preMs: 28_001, expected: [41, 42, 43])
    ])
    func exactPreRollBoundaryIncludesOnlySegmentsWithPositiveRemaining(testCase: BoundaryCase) throws {
        var record = fixtureRecord(markSeq: 43, markAge: 0)
        record.preMs = testCase.preMs
        record.postMs = 0

        let persisted = try persistedRecord(from: IncidentPlanner.plan(
            incidents: [record],
            clips: (40...43).map { clip(seq: $0, duration: 30_000) },
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .recording(recordingID)
        ))

        #expect(persisted.wanted.map(\.seq) == testCase.expected)
    }

    @Test func absenceOutsideCursorCoverageStaysUnresolvedAndRequestsPaging() throws {
        let commands = IncidentPlanner.plan(
            incidents: [fixtureRecord(markSeq: 43, markAge: 0)],
            clips: [clip(seq: 42), clip(seq: 43)],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: ClipCursor(42)),
            recorder: .recording(recordingID)
        )
        let persisted = try persistedRecord(from: commands)

        #expect(persisted.segment(seq: 41)?.state == .unresolved)
        #expect(commands.contains(.requireCoverage(ClipCursor(41))))
    }

    @Test func sessionStartAndEndAbsencesClipWithoutMakingIncidentPartial() throws {
        var record = fixtureRecord(markSeq: 43, markAge: 0)
        record.wanted = [
            IncidentSegment(seq: 42),
            IncidentSegment(seq: 43, state: .pulled, etag: "43-etag", durMs: 30_000, bytes: 10),
            IncidentSegment(seq: 44)
        ]
        record.preMs = 30_001
        record.postMs = 31_000

        let persisted = try persistedRecord(from: IncidentPlanner.plan(
            incidents: [record],
            clips: [],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .notRecording
        ))

        #expect(persisted.segment(seq: 42)?.state == .clipped)
        #expect(persisted.segment(seq: 44)?.state == .clipped)
        #expect(persisted.status == .saved)
    }

    @Test func coveredInteriorGapIsLostWhenAnOutwardSameSessionWitnessExists() throws {
        var record = fixtureRecord(markSeq: 43, markAge: 0)
        record.preMs = 60_001

        let persisted = try persistedRecord(from: IncidentPlanner.plan(
            incidents: [record],
            clips: [clip(seq: 40), clip(seq: 42), clip(seq: 43)],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .recording(recordingID)
        ))

        #expect(persisted.segment(seq: 41)?.state == .lost)
        #expect(persisted.status == .pending)
    }

    @Test func vanishedOpenMarkPersistsLossBeforeFinalizingPartial() throws {
        let record = fixtureRecord(markSeq: 43, markAge: 1_000, preMs: 0, postMs: 0, slackMs: 0)

        let firstPass = IncidentPlanner.plan(
            incidents: [record],
            clips: [],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .notRecording
        )
        let persisted = try persistedRecord(from: firstPass)
        #expect(persisted.segment(seq: 43)?.state == .lost)

        let secondPass = IncidentPlanner.plan(
            incidents: [persisted],
            clips: [],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .notRecording
        )

        #expect(secondPass.isEmpty)
    }

    @Test func unknownDurationLossStopsWalkButKnownOuterArtifactsRemainSalvageable() throws {
        var record = fixtureRecord(markSeq: 43, markAge: 0)
        record.preMs = 60_001
        record.wanted = [
            IncidentSegment(seq: 40, state: .wanted, etag: "40", durMs: 30_000),
            IncidentSegment(seq: 41, state: .lost),
            IncidentSegment(seq: 42, state: .wanted, etag: "42", durMs: 30_000),
            IncidentSegment(seq: 43, state: .wanted, etag: "43", durMs: 30_000)
        ]

        let commands = IncidentPlanner.plan(
            incidents: [record],
            clips: [],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .recording(recordingID)
        )

        #expect(pullSeqs(commands) == [40, 42, 43])
        #expect(commands.contains { if case .persist = $0 { true } else { false } } == false)
    }

    @Test func resolutionsPersistOnePassBeforePullsAndSharedSegmentsDeduplicate() throws {
        let first = fixtureRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, preMs: 0, postMs: 0, slackMs: 0)
        let second = fixtureRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, preMs: 0, postMs: 0, slackMs: 0)
        let firstPass = IncidentPlanner.plan(
            incidents: [first, second],
            clips: [clip(seq: 43)],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .recording(recordingID)
        )
        #expect(pullSeqs(firstPass).isEmpty)
        let persisted = firstPass.compactMap { command -> IncidentRecord? in
            guard case .persist(let record) = command else { return nil }
            return record
        }

        let secondPass = IncidentPlanner.plan(
            incidents: persisted,
            clips: [clip(seq: 43)],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .recording(recordingID)
        )

        #expect(secondPass == [.pull(seq: 43, etag: "43-etag", incidentIDs: [first.id, second.id])])
    }

    @Test func terminalStatusNeverRegressesOnReplay() {
        var record = fixtureRecord(markAge: 0, preMs: 0, postMs: 0, slackMs: 0)
        record.wanted = [IncidentSegment(seq: 43, state: .pulled, etag: "old", durMs: 30_000, bytes: 10)]

        #expect(IncidentPlanner.plan(
            incidents: [record],
            clips: [clip(seq: 43)],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .notRecording
        ).isEmpty)
    }

    @Test func finalizingSameRecordingDoesNotProveOpenMarkMissing() {
        let record = fixtureRecord(markSeq: 43, markAge: 1_000, preMs: 0, postMs: 0, slackMs: 0)

        let commands = IncidentPlanner.plan(
            incidents: [record],
            clips: [],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .recording(recordingID)
        )

        #expect(commands.isEmpty)
        #expect(record.status == .pending)
    }

    @Test(arguments: [IncidentSegmentState.lost, .clipped])
    func positiveWitnessReopensCorrectableTerminalFactBeforePull(state: IncidentSegmentState) throws {
        var segment = IncidentSegment(seq: 43, state: state)
        if state == .lost {
            segment.lossEvidence = .inferredAbsence
        }
        var record = fixtureRecord(markSeq: 43, markAge: 1_000, preMs: 0, postMs: 0, slackMs: 0)
        record.wanted = [segment]

        let firstPass = IncidentPlanner.plan(
            incidents: [record],
            clips: [clip(seq: 43)],
            listCoverage: .unloaded,
            recorder: .notRecording
        )
        let reopened = try persistedRecord(from: firstPass)

        #expect(reopened.status == .pending)
        #expect(reopened.segment(seq: 43)?.state == .wanted)
        #expect(pullSeqs(firstPass).isEmpty)

        let secondPass = IncidentPlanner.plan(
            incidents: [reopened],
            clips: [clip(seq: 43)],
            listCoverage: .unloaded,
            recorder: .notRecording
        )
        #expect(pullSeqs(secondPass) == [43])
    }

    @Test func confirmedMissingNeverReopensFromListWitness() {
        var record = fixtureRecord(markSeq: 43, markAge: 1_000, preMs: 0, postMs: 0, slackMs: 0)
        record.wanted = [IncidentSegment(
            seq: 43,
            state: .lost,
            etag: "43-etag",
            durMs: 30_000,
            lossEvidence: .confirmedMissing
        )]

        #expect(IncidentPlanner.plan(
            incidents: [record],
            clips: [clip(seq: 43)],
            listCoverage: .loaded(epoch: ClipCoverageEpoch(rawValue: 1), nextCursor: nil),
            recorder: .notRecording
        ).isEmpty)
        #expect(record.status == .partial)
    }

    private let recordingID = RecordingID(bootTag: "boot", session: 7)

    private func fixtureRecord(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
        markSeq: Int = 43,
        markAge: UInt64 = 12_000,
        preMs: UInt64 = 30_000,
        postMs: UInt64 = 15_000,
        slackMs: UInt64 = 2_000
    ) -> IncidentRecord {
        IncidentRecord(
            id: id,
            pressedAtMs: 1_000,
            recordingID: recordingID,
            markSeq: markSeq,
            markAgeMs: markAge,
            preMs: preMs,
            postMs: postMs,
            slackMs: slackMs
        )
    }

    private func clip(seq: Int, duration: UInt64 = 30_000) -> Clip {
        Clip(
            id: seq,
            startMs: nil,
            durMs: duration,
            bytes: UInt64(seq * 100),
            locked: false,
            etag: "\(seq)-etag",
            timeApproximate: true,
            bootTag: recordingID.bootTag,
            session: recordingID.session
        )
    }

    private func persistedRecord(from commands: [IncidentPlannerCommand]) throws -> IncidentRecord {
        try #require(commands.compactMap { command -> IncidentRecord? in
            guard case .persist(let record) = command else { return nil }
            return record
        }.first)
    }

    private func pullSeqs(_ commands: [IncidentPlannerCommand]) -> [Int] {
        commands.compactMap { command in
            guard case .pull(let seq, _, _) = command else { return nil }
            return seq
        }
    }
}

struct PlannerCase: Sendable {
    var duration: UInt64
    var markAge: UInt64
    var expected: [Int]
}

struct BoundaryCase: Sendable {
    var preMs: UInt64
    var expected: [Int]
}
