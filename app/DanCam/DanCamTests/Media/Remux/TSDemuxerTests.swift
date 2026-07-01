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

    // MARK: - Sync-aligned corruption (fail-soft per packet, drop one PES)

    @Test(.timeLimit(.minutes(1)))
    func toleratesReservedAdaptationControlOnContinuation() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)
        try #require(clean.count == TSFixtureLayout.videoPESCount)

        let offset = TSFixtureLayout.pes1ContinuationOffset
        try #require(data[offset] == 0x47)
        try #require((data[offset + 3] & 0x30) >> 4 == 1)

        var corrupted = data
        corrupted[offset + 3] &= ~UInt8(0x30) // adaptation-control -> 0 (reserved)

        let actual = try demuxBothPaths(corrupted)
        assertDropsExactlyOnePESPreservingOthers(clean: clean, corrupted: actual)
    }

    @Test(.timeLimit(.minutes(1)))
    func toleratesReservedAdaptationControlOnPUSIPreservingPreviousPES() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)

        let offset = TSFixtureLayout.pes1PacketOffset
        try #require((data[offset + 1] & 0x40) != 0) // payload-unit-start
        try #require((data[offset + 3] & 0x30) >> 4 == 1)

        var corrupted = data
        corrupted[offset + 3] &= ~UInt8(0x30) // adaptation-control -> 0 (reserved)

        // The previous PES (PES#0, the SPS/PPS/IDR carrier) is complete and must be
        // flushed, not discarded -- this pins the recovery-granularity decision.
        let actual = try demuxBothPaths(corrupted)
        assertDropsExactlyOnePESPreservingOthers(clean: clean, corrupted: actual)
        #expect(actual.first == clean.first)
    }

    @Test(.timeLimit(.minutes(1)))
    func toleratesMissingPTSPES() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)

        let flagsByte = TSFixtureLayout.pes1FlagsByte
        try #require((data[flagsByte] & 0xc0) >> 6 == 0b11)

        var corrupted = data
        corrupted[flagsByte] &= ~UInt8(0xc0) // PTS_DTS_flags -> 00

        let actual = try demuxBothPaths(corrupted)
        assertDropsExactlyOnePESPreservingOthers(clean: clean, corrupted: actual)
    }

    @Test(.timeLimit(.minutes(1)))
    func dropsPESWithBrokenTimestampMarkerBit() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)

        let field = TSFixtureLayout.pes1PTSField
        try #require((data[field + 4] & 0x01) == 1) // trailing PTS marker bit is set

        var corrupted = data
        clearTimestampMarker(&corrupted, fieldOffset: field)

        // Clearing a marker bit does not change the decoded PTS, so without the
        // section-4 syntax gate this frame would survive (count stays 900). The
        // 899 count discriminates the gate.
        let actual = try demuxBothPaths(corrupted)
        assertDropsExactlyOnePESPreservingOthers(clean: clean, corrupted: actual)
    }

    @Test(.timeLimit(.minutes(1)))
    func dropsMarkerValidDTSSpikeUpOnPES() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)

        let field = TSFixtureLayout.pes1DTSField
        try #require((data[TSFixtureLayout.pes1FlagsByte] & 0xc0) >> 6 == 0b11)
        try #require((data[field] >> 4) == 0b0001) // DTS prefix nibble intact

        var corrupted = data
        // A marker-valid value spike far above every real DTS: the section-4 gate
        // cannot see it; only the ordering check fires.
        writeTimestampValue(&corrupted, fieldOffset: field, value: 8_000_000)

        let actual = try demuxBothPaths(corrupted)
        assertDropsExactlyOnePESPreservingOthers(clean: clean, corrupted: actual)
        assertStrictlyIncreasing(actual.map(\.dtsTicks))
    }

    @Test(.timeLimit(.minutes(1)))
    func dropsMarkerValidDTSFlipDownPreservingParameterSets() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)

        let field = TSFixtureLayout.pes1DTSField
        try #require((data[TSFixtureLayout.pes1FlagsByte] & 0xc0) >> 6 == 0b11)
        try #require((data[field] >> 4) == 0b0001) // DTS prefix nibble intact

        var corrupted = data
        // Dip below PES#0's DTS while no baseline exists yet (the F1 path): the
        // held SPS/PPS/IDR carrier must survive and only PES#1 is dropped.
        writeTimestampValue(&corrupted, fieldOffset: field, value: TSFixtureLayout.pes0DTS - 3_000)

        let actual = try demuxBothPaths(corrupted)
        assertDropsExactlyOnePESPreservingOthers(clean: clean, corrupted: actual)

        let clip = try TSDemuxer.demuxH264(from: corrupted)
        #expect(clip.sps.isEmpty == false)
        #expect(clip.pps.isEmpty == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func toleratesMarkerValidDTSSpikeUpOnFirstPES() throws {
        let data = try loadFixture()
        try #require((data[TSFixtureLayout.pes0DTSField] >> 4) == 0b0001) // DTS prefix nibble intact

        var corrupted = data
        // Spike-up on the very first PES, before any baseline exists: the documented
        // residual floor. It degrades toward first-frame-only but never aborts and
        // preserves SPS/PPS -- assert only that floor, not a frame count.
        writeTimestampValue(&corrupted, fieldOffset: TSFixtureLayout.pes0DTSField, value: 8_000_000)

        let actual = try demuxBothPaths(corrupted)
        #expect(actual.isEmpty == false)
        assertStrictlyIncreasing(actual.map(\.dtsTicks))

        let clip = try TSDemuxer.demuxH264(from: corrupted)
        #expect(clip.sps.isEmpty == false)
        #expect(clip.pps.isEmpty == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func boundsInBandDTSFlipToExactlyOnePES() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)
        try #require((data[TSFixtureLayout.pes2DTSField] >> 4) == 0b0001) // DTS prefix nibble intact

        var corrupted = data
        // A small in-band dip on PES#2, into (lastFinishedDTS, currentPES] with a
        // real baseline: lookahead-of-one blames the held good neighbor instead of
        // PES#2. The guarantee is bounded (exactly one PES, still monotonic), not
        // that the corrupt frame itself is the one dropped.
        writeTimestampValue(&corrupted, fieldOffset: TSFixtureLayout.pes2DTSField, value: 127_500)

        let actual = try demuxBothPaths(corrupted)
        #expect(actual.count == clean.count - 1)
        assertStrictlyIncreasing(actual.map(\.dtsTicks))
    }

    @Test(.timeLimit(.minutes(1)))
    func toleratesOverlongAdaptationField() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)

        let offset = TSFixtureLayout.pes1ContinuationOffset
        try #require((data[offset + 3] & 0x30) >> 4 == 1)

        var corrupted = data
        corrupted[offset + 3] |= 0x30 // adaptation-control -> 3 (adaptation + payload)
        corrupted[offset + 4] = 200 // adaptation_field_length overruns the packet

        let actual = try demuxBothPaths(corrupted)
        assertDropsExactlyOnePESPreservingOthers(clean: clean, corrupted: actual)
    }

    @Test(.timeLimit(.minutes(1)))
    func skipsRedundantCorruptPMTAfterLatch() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)
        try #require(clean.count == TSFixtureLayout.videoPESCount)

        var corrupted = data
        corruptPMTSectionLength(&corrupted, sectionLengthHi: TSFixtureLayout.laterPMTSectionLengthHi)

        // videoPID is already latched from PMT@376, so the redundant later PMT is
        // skipped with no effect on the PES stream.
        let actual = try demuxBothPaths(corrupted)
        #expect(actual == clean)
    }

    @Test(.timeLimit(.minutes(1)))
    func recoversAfterCorruptInitialPMT() throws {
        let data = try loadFixture()
        let clean = try demuxBothPaths(data)
        try #require(clean.count == TSFixtureLayout.videoPESCount)

        var corrupted = data
        corruptPMTSectionLength(&corrupted, sectionLengthHi: TSFixtureLayout.initialPMTSectionLengthHi)

        // The latching PMT is skipped, so PES#0-2 land in the pre-latch gap and are
        // dropped; the next PMT @6392 re-latches videoPID, and the batch demux
        // recovers a contiguous suffix from PES#3. These constants are measured.
        let actual = try demuxBothPaths(corrupted)
        #expect(actual == Array(clean.dropFirst(3)))
    }

    // MARK: - Helpers

    private func loadFixture() throws -> Data {
        try Data(contentsOf: MediaFixtureURLs.seg00000TS())
    }

    /// Runs the (possibly mutated) fixture through both the one-shot finalizer path
    /// and a jittered incremental feed and asserts they agree, so every skip stays
    /// chunk-boundary invariant. Returns the chunk-invariant packet list.
    private func demuxBothPaths(
        _ data: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [H264PESPacket] {
        let oneShot = try TSDemuxer.demuxH264PESPackets(from: data)
        let jittered = try incrementalPESPackets(
            from: data,
            chunkSizes: [31, 509, 7, 188, 23, 4093, 2, 997]
        )
        #expect(jittered == oneShot, "skip must stay invariant to chunk boundaries", sourceLocation: sourceLocation)
        return oneShot
    }

    /// Asserts exactly one PES was dropped and every survivor is byte- and
    /// timestamp-identical to the clean decode (used when the drop falls on the
    /// corrupt frame, leaving neighbors pristine).
    private func assertDropsExactlyOnePESPreservingOthers(
        clean: [H264PESPacket],
        corrupted: [H264PESPacket],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(corrupted.count == clean.count - 1, sourceLocation: sourceLocation)
        guard corrupted.count == clean.count - 1 else { return }

        var dropIndex = clean.count - 1
        for index in corrupted.indices where corrupted[index] != clean[index] {
            dropIndex = index
            break
        }
        var expected = clean
        expected.remove(at: dropIndex)
        #expect(corrupted == expected, "one PES dropped; all survivors identical", sourceLocation: sourceLocation)
    }

    private func assertStrictlyIncreasing(
        _ values: [Int64],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for index in values.indices.dropFirst() {
            #expect(values[index] > values[index - 1], "must be strictly increasing at \(index)", sourceLocation: sourceLocation)
        }
    }

    /// Overwrites the 33-bit value of a 5-byte PTS/DTS field while preserving the
    /// prefix nibble and the three interleaved marker bits, so the section-4 gate
    /// still passes and only the section-5 ordering check can react.
    private func writeTimestampValue(_ data: inout Data, fieldOffset: Int, value: Int64) {
        let bits = UInt64(value)
        data[fieldOffset] = (data[fieldOffset] & 0xf1) | UInt8(((bits >> 30) & 0x07) << 1)
        data[fieldOffset + 1] = UInt8((bits >> 22) & 0xff)
        data[fieldOffset + 2] = (data[fieldOffset + 2] & 0x01) | UInt8(((bits >> 15) & 0x7f) << 1)
        data[fieldOffset + 3] = UInt8((bits >> 7) & 0xff)
        data[fieldOffset + 4] = (data[fieldOffset + 4] & 0x01) | UInt8((bits & 0x7f) << 1)
    }

    private func clearTimestampMarker(_ data: inout Data, fieldOffset: Int) {
        data[fieldOffset + 4] &= ~UInt8(0x01)
    }

    private func corruptPMTSectionLength(_ data: inout Data, sectionLengthHi: Int) {
        data[sectionLengthHi] |= 0x0f
        data[sectionLengthHi + 1] = 0xff // section_length overruns the single PSI packet
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
            packets.append(contentsOf: demuxer.append(Data(data[offset..<end])))
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
