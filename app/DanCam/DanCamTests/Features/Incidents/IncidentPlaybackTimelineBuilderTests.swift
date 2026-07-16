import AVFoundation
import Foundation
import Testing
@testable import DanCam

@MainActor
struct IncidentPlaybackTimelineBuilderTests {
    @Test(.timeLimit(.minutes(1)))
    func compositionUsesRealDurationsAndAscendingSequenceOrder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frameDuration = CMTime(value: 1_001, timescale: 30_000)
        try await makeVideo(seq: 44, frameCount: 5, frameDuration: frameDuration, root: root)
        try await makeVideo(seq: 42, frameCount: 3, frameDuration: frameDuration, root: root)
        let result = await IncidentPlaybackTimelineBuilder.build(
            segments: [
                IncidentSegment(seq: 44, state: .pulled),
                IncidentSegment(seq: 42, state: .pulled),
            ],
            directoryURL: root
        )

        #expect(result.segments.map(\.seq) == [42, 44])
        let first = try #require(result.segments.first)
        let second = try #require(result.segments.last)
        #expect(CMTimeCompare(first.start, .zero) == 0)
        #expect(CMTimeCompare(second.start, first.duration) == 0)
        #expect(CMTimeCompare(result.duration, CMTimeAdd(first.duration, second.duration)) == 0)
        #expect(first.duration.timescale != 1_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func corruptAndNonPlayableSegmentsBecomeHonestGaps() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(seq: 41, frameCount: 2, root: root)
        try Data([0x00, 0x01]).write(to: videoURL(seq: 42, root: root))
        try await makeVideo(seq: 45, frameCount: 2, root: root)
        let result = await IncidentPlaybackTimelineBuilder.build(
            segments: [
                IncidentSegment(seq: 45, state: .pulled),
                IncidentSegment(seq: 44, state: .lost),
                IncidentSegment(seq: 43, state: .wanted),
                IncidentSegment(seq: 42, state: .pulled),
                IncidentSegment(seq: 41, state: .pulled),
            ],
            directoryURL: root
        )

        #expect(result.segments.map(\.seq) == [41, 45])
        #expect(result.gaps == [
            IncidentPlaybackGap(seq: 42, reason: .unavailable),
            IncidentPlaybackGap(seq: 43, reason: .saving),
            IncidentPlaybackGap(seq: 44, reason: .missing),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func anchorRestorationAndPressMappingAreSequenceRelativeAndForwardBiased() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(seq: 41, frameCount: 6, root: root)
        try await makeVideo(seq: 43, frameCount: 6, root: root)
        let result = await IncidentPlaybackTimelineBuilder.build(
            segments: [
                IncidentSegment(seq: 41, state: .pulled),
                IncidentSegment(seq: 42, state: .lost),
                IncidentSegment(seq: 43, state: .pulled),
            ],
            directoryURL: root
        )
        let first = try #require(result.segments.first)
        let second = try #require(result.segments.last)

        #expect(result.anchor(at: first.end) == IncidentPlaybackAnchor(seq: 43, offset: .zero))
        #expect(CMTimeCompare(
            result.restorationTime(for: IncidentPlaybackAnchor(seq: 42, offset: CMTime(value: 1, timescale: 30))),
            second.start
        ) == 0)
        #expect(CMTimeCompare(
            result.restorationTime(for: IncidentPlaybackAnchor(seq: 99, offset: .zero)),
            result.duration
        ) == 0)
        #expect(CMTimeCompare(result.pressTime(markSeq: 42, markAgeMs: 10), second.start) == 0)
        #expect(CMTimeCompare(
            result.pressTime(markSeq: 41, markAgeMs: 33),
            CMTimeAdd(first.start, CMTime(value: 33, timescale: 1_000))
        ) == 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "dancam-timeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeVideo(
        seq: Int,
        frameCount: Int,
        frameDuration: CMTime = CMTime(value: 1, timescale: 30),
        root: URL
    ) async throws {
        _ = try await makeTemporaryPlayableVideoFile(
            at: videoURL(seq: seq, root: root),
            frameCount: frameCount,
            frameDuration: frameDuration
        )
    }

    private func videoURL(seq: Int, root: URL) -> URL {
        root.appending(path: String(format: "seg_%05d.mp4", seq))
    }
}
