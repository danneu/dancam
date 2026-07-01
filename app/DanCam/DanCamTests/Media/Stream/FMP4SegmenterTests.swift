import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import DanCam

struct FMP4SegmenterTests {
    @Test(.timeLimit(.minutes(1)))
    func writesInitializationAndOneMediaSegmentPerGOP() throws {
        let clip = try streamingFixtureClip()
        let keyFrameCount = clip.accessUnits.filter(\.isKeyFrame).count
        try #require(keyFrameCount > 1)

        let sink = RecordingSegmentSink()
        let segmenter = FMP4Segmenter(timescale: clip.timescale, sink: sink)

        try segmenter.start(sps: clip.sps, pps: clip.pps)
        for accessUnit in clip.accessUnits {
            try segmenter.append(accessUnit)
        }
        try segmenter.finishWriting()

        let snapshot = sink.snapshot()
        #expect(snapshot.finished)
        #expect(snapshot.initializationSegments.count == 1)
        #expect(snapshot.mediaSegments.count == keyFrameCount)
        #expect(snapshot.events.first == .initialization)
        #expect(snapshot.events.last == .finish)
        #expect(snapshot.events.dropFirst().dropLast().allSatisfy { $0 == .media })

        let initializationSegment = try #require(snapshot.initializationSegments.first)
        #expect(containsBox("ftyp", in: initializationSegment))
        #expect(containsBox("moov", in: initializationSegment))

        for segment in snapshot.mediaSegments {
            #expect(segment.data.isEmpty == false)
            #expect(segment.duration.isNumeric)
            #expect(segment.duration.seconds > 0)
            #expect(containsBox("moof", in: segment.data))
            #expect(containsBox("mdat", in: segment.data))
        }

        let reportedDuration = snapshot.mediaSegments.reduce(.zero) { partial, segment in
            CMTimeAdd(partial, segment.duration)
        }
        let expectedDuration = CMTime(value: clip.durationTicks, timescale: clip.timescale)
        #expect(abs(reportedDuration.seconds - expectedDuration.seconds) < 0.5)
    }

    @Test
    func invalidSegmentReportsFailWithoutPublishingMediaSegments() throws {
        for invalidDuration in [CMTime?.none, .some(.zero), .some(.invalid)] {
            let sink = RecordingSegmentSink()
            let segmenter = FMP4Segmenter(sink: sink)

            segmenter.handleSegmentOutput(
                data: Data([0x01, 0x02, 0x03]),
                segmentType: .separable,
                reportedDuration: invalidDuration
            )

            #expect(sink.snapshot().mediaSegments.isEmpty)
            #expect(throws: ClipRemuxError.writer("Missing or invalid fMP4 segment report.")) {
                try segmenter.finishWriting()
            }
        }
    }

    private func streamingFixtureClip() throws -> DemuxedH264Clip {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let packets = try TSDemuxer.demuxH264PESPackets(from: data)
        var assembler = StreamingH264AccessUnitAssembler()
        var accessUnits: [H264AccessUnit] = []
        var sps: Data?
        var pps: Data?

        for packet in packets {
            let output = assembler.append([packet])
            accessUnits.append(contentsOf: output.accessUnits)
            if let outputSPS = output.sps {
                sps = outputSPS
            }
            if let outputPPS = output.pps {
                pps = outputPPS
            }
        }

        accessUnits.append(contentsOf: assembler.finish().accessUnits)

        return DemuxedH264Clip(
            accessUnits: accessUnits,
            sps: try #require(sps),
            pps: try #require(pps),
            timescale: 90_000
        )
    }

    private func containsBox(_ boxType: String, in data: Data) -> Bool {
        data.range(of: Data(boxType.utf8)) != nil
    }
}

private final class RecordingSegmentSink: FMP4SegmentSink {
    private let state = Mutex(State())

    func appendInitializationSegment(_ data: Data) {
        state.withLock { state in
            state.initializationSegments.append(data)
            state.events.append(.initialization)
        }
    }

    func appendMediaSegment(_ data: Data, duration: CMTime) {
        state.withLock { state in
            state.mediaSegments.append(MediaSegment(data: data, duration: duration))
            state.events.append(.media)
        }
    }

    func finish() {
        state.withLock { state in
            state.finished = true
            state.events.append(.finish)
        }
    }

    func snapshot() -> State {
        state.withLock { $0 }
    }

    struct State: Sendable {
        var initializationSegments: [Data] = []
        var mediaSegments: [MediaSegment] = []
        var events: [Event] = []
        var finished = false
    }

    struct MediaSegment: Sendable {
        var data: Data
        var duration: CMTime
    }

    enum Event: Equatable, Sendable {
        case initialization
        case media
        case finish
    }
}
