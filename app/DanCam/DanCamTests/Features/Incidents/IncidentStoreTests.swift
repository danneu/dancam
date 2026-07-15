import Foundation
import Testing
@testable import DanCam

struct IncidentStoreTests {
    @Test func createUpdateListAndDeleteRoundTripAtomically() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IncidentStore.live(rootDirectory: root)
        var record = fixtureRecord()

        try await store.create(record)
        record.markAgeMs = 13_000
        try await store.update(record)

        let listed = try await store.list()
        #expect(listed == [.readable(record: record, directoryURL: store.directoryURL(record.id))])
        let recordURL = store.directoryURL(record.id).appending(path: "incident.json")
        #expect(try Data(contentsOf: recordURL).isEmpty == false)

        try await store.delete(record.id)
        #expect(try await store.list().isEmpty)
    }

    @Test func scanSurfacesCorruptedRecordWithoutDeletingDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "not-readable", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: directory.appending(path: "incident.json"))

        let store = IncidentStore.live(rootDirectory: root)
        let listed = try await store.list()

        #expect(listed == [.unreadable(directoryName: "not-readable", directoryURL: directory)])
        #expect(FileManager.default.fileExists(atPath: directory.path))

        try await store.deleteUnreadable("not-readable")
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    }

    @Test func scanRepairsInstalledArtifactBeforePlannerCanSeeStaleWantedState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IncidentStore.live(rootDirectory: root)
        var record = fixtureRecord()
        record.preMs = 0
        record.postMs = 0
        record.slackMs = 0
        record.wanted = [IncidentSegment(seq: 43, state: .wanted, etag: "etag", durMs: 30_000)]
        try await store.create(record)
        try Data(repeating: 0x2a, count: 12).write(
            to: store.directoryURL(record.id).appending(path: "seg_00043.mp4")
        )

        let listed = try await store.list()
        let repaired = try #require(listed.first?.record)
        #expect(repaired.wanted == [
            IncidentSegment(seq: 43, state: .pulled, etag: "etag", durMs: 30_000, bytes: 12)
        ])

        let commands = IncidentPlanner.plan(
            incidents: [repaired],
            clips: [],
            listCoverage: .loaded(nextCursor: nil),
            recorder: .notRecording
        )
        #expect(commands.isEmpty)

        let rescanned = try await store.list()
        #expect(rescanned.first?.record == repaired)
    }

    @Test func scanDeletesInterruptedStagingFileWithoutPromotingWantedEntry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IncidentStore.live(rootDirectory: root)
        var record = fixtureRecord()
        record.wanted = [IncidentSegment(seq: 43, state: .wanted, etag: "etag", durMs: 30_000)]
        try await store.create(record)
        let staging = store.directoryURL(record.id).appending(path: "seg_00043.mp4.part")
        try Data(repeating: 0xff, count: 7).write(to: staging)

        let listed = try await store.list()

        #expect(FileManager.default.fileExists(atPath: staging.path) == false)
        #expect(listed.first?.record == record)
    }

    @Test func finalArtifactWinsOverStaleTerminalSegmentMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IncidentStore.live(rootDirectory: root)
        var record = fixtureRecord()
        record.wanted = [IncidentSegment(seq: 43, state: .lost, etag: "etag", durMs: 30_000)]
        try await store.create(record)
        try Data(repeating: 0x11, count: 4).write(
            to: store.directoryURL(record.id).appending(path: "seg_00043.ts")
        )

        let repaired = try #require(try await store.list().first?.record)

        #expect(repaired.wanted == [
            IncidentSegment(seq: 43, state: .pulled, etag: "etag", durMs: 30_000, bytes: 4)
        ])
    }

    @Test func tornSiblingNeverReplacesLastReadableAtomicRecord() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IncidentStore.live(rootDirectory: root)
        let record = fixtureRecord()
        try await store.create(record)
        try Data("partial-json".utf8).write(
            to: store.directoryURL(record.id).appending(path: ".incident.json.tmp")
        )

        #expect(try await store.list().first?.record == record)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dancam-incident-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixtureRecord() -> IncidentRecord {
        IncidentRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            pressedAtMs: 1_000,
            recordingID: RecordingID(bootTag: "boot", session: 7),
            markSeq: 43,
            markAgeMs: 12_000
        )
    }
}

private extension StoredIncident {
    var record: IncidentRecord? {
        guard case .readable(let record, _) = self else { return nil }
        return record
    }
}
