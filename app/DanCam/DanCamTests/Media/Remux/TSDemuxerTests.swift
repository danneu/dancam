import Foundation
import Testing
@testable import DanCam

struct TSDemuxerTests {
    @Test(.timeLimit(.minutes(1)))
    func demuxesBundledTransportStreamFixture() throws {
        let clip = try TSDemuxer.demuxH264(from: MediaFixtureURLs.seg00000TS())

        #expect(clip.timescale == 90_000)
        #expect(clip.accessUnits.count > 800)
        #expect(clip.sps.isEmpty == false)
        #expect(clip.pps.isEmpty == false)
        #expect(clip.accessUnits.first?.isKeyFrame == true)
        #expect(clip.accessUnits.contains { $0.isKeyFrame })
        #expect(abs(durationSeconds(clip) - 30.0) < 0.2)
    }

    @Test(.timeLimit(.minutes(1)))
    func demuxedPESPacketsAreInvariantToChunkBoundaries() throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let expected = try TSDemuxer.demuxH264PESPackets(from: data)

        for chunkSize in [1, 187, 188, 189, 4096, data.count] {
            let actual = try incrementalPESPackets(from: data, chunkSizes: [chunkSize])
            #expect(actual == expected, "chunk size \(chunkSize)")
        }

        let jittered = try incrementalPESPackets(
            from: data,
            chunkSizes: [31, 509, 7, 188, 23, 4093, 2, 997]
        )
        #expect(jittered == expected, "jittered chunk sizes")
    }

    @Test(.timeLimit(.minutes(1)))
    func incrementalDemuxerHandlesPSISectionsSplitAcrossChunkBoundaries() throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let expected = try TSDemuxer.demuxH264PESPackets(from: data)
        let packetSize = TransportStreamH264Parser.packetSize

        let actual = try incrementalPESPackets(
            from: data,
            chunkSizes: [5, packetSize - 5, packetSize + 7, 11, 503]
        )

        #expect(actual == expected)
    }

    @Test(.timeLimit(.minutes(1)))
    func incrementalDemuxerResyncsAfterInjectedGarbage() throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let expected = try TSDemuxer.demuxH264PESPackets(from: data)
        let insertionOffset = TransportStreamH264Parser.packetSize * 31
        try #require(data.count > insertionOffset + (TransportStreamH264Parser.packetSize * 3))

        var corrupted = Data(data[..<insertionOffset])
        corrupted.append(contentsOf: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        corrupted.append(contentsOf: data[insertionOffset...])

        let actual = try incrementalPESPackets(
            from: corrupted,
            chunkSizes: [257, 19, 4096, 3]
        )

        #expect(actual == expected)
    }

    @Test
    func rejectsTransportStreamWithNoH264Packets() {
        #expect(throws: ClipRemuxError.invalidTransportStream("No H.264 PES packets found.")) {
            _ = try TSDemuxer.demuxH264(from: Data([0x47, 0x00]))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func toleratesUnalignedTruncatedTransportStream() throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let packetSize = TransportStreamH264Parser.packetSize
        let full = try TSDemuxer.demuxH264PESPackets(from: data)
        let cut = data.count - 750
        try #require(cut % packetSize != 0)
        let flooredByteCount = (cut / packetSize) * packetSize

        let truncated = try TSDemuxer.demuxH264PESPackets(from: Data(data.prefix(cut)))
        let floored = try TSDemuxer.demuxH264PESPackets(from: Data(data.prefix(flooredByteCount)))

        #expect(truncated == floored)
        #expect(truncated.count == full.count)

        let truncatedLast = try #require(truncated.last)
        let fullLast = try #require(full.last)
        #expect(truncatedLast.payload.count < fullLast.payload.count)
    }

    private func incrementalPESPackets(
        from data: Data,
        chunkSizes: [Int]
    ) throws -> [H264PESPacket] {
        try #require(chunkSizes.isEmpty == false)

        var demuxer = IncrementalTSDemuxer()
        var packets: [H264PESPacket] = []
        var offset = 0
        var chunkIndex = 0

        while offset < data.count {
            let chunkSize = chunkSizes[chunkIndex % chunkSizes.count]
            try #require(chunkSize > 0)

            let end = min(data.count, offset + chunkSize)
            packets.append(contentsOf: try demuxer.append(Data(data[offset..<end])))
            offset = end
            chunkIndex += 1
        }

        packets.append(contentsOf: demuxer.finish())
        return packets
    }

    private func durationSeconds(_ clip: DemuxedH264Clip) -> Double {
        Double(clip.durationTicks) / Double(clip.timescale)
    }
}
