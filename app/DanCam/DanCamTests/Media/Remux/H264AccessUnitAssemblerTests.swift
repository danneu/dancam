import Foundation
import Testing
@testable import DanCam

struct H264AccessUnitAssemblerTests {
    @Test
    func parsesAnnexBStartCodesAndNALTypes() throws {
        let units = H264AccessUnitAssembler.splitAnnexB(Data([
            0x00, 0x00, 0x00, 0x01, 0x67, 0xaa,
            0x00, 0x00, 0x01, 0x68, 0xbb,
            0x00, 0x00, 0x00, 0x01, 0x65, 0xcc,
        ]))

        #expect(units.map(\.type) == [7, 8, 5])
        #expect(units.map(\.data) == [
            Data([0x67, 0xaa]),
            Data([0x68, 0xbb]),
            Data([0x65, 0xcc]),
        ])
    }

    @Test
    func extractsParameterSetsAndBuildsAVCCSamples() throws {
        let packet = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                nal(7, [0x64, 0x00, 0x15]),
                nal(8, [0xee, 0x3c]),
                nal(5, [0x88, 0x99]),
            ]),
            ptsTicks: 6_000,
            dtsTicks: 0
        )

        let clip = try H264AccessUnitAssembler.assemble(
            packets: [packet],
            timescale: 90_000
        )

        #expect(clip.sps == nal(7, [0x64, 0x00, 0x15]))
        #expect(clip.pps == nal(8, [0xee, 0x3c]))
        #expect(clip.accessUnits.count == 1)
        #expect(clip.accessUnits[0].isKeyFrame)
        #expect(clip.accessUnits[0].nalTypes == [9, 7, 8, 5])
        #expect(clip.accessUnits[0].sampleData == avcc([nal(5, [0x88, 0x99])]))
    }

    @Test
    func splitsMultipleAccessUnitsOnAUD() throws {
        let packet = H264PESPacket(
            payload: annexB([
                nal(7, [0x64]),
                nal(8, [0xee]),
                nal(9, [0xf0]),
                nal(5, [0x88]),
                nal(9, [0xf0]),
                nal(1, [0x99]),
            ]),
            ptsTicks: 0,
            dtsTicks: 0
        )

        let clip = try H264AccessUnitAssembler.assemble(
            packets: [packet],
            timescale: 90_000
        )

        #expect(clip.accessUnits.count == 2)
        #expect(clip.accessUnits.map(\.isKeyFrame) == [true, false])
        #expect(clip.accessUnits.map(\.nalTypes) == [[7, 8, 9, 5], [9, 1]])
    }

    @Test
    func skipsPESWithoutAnnexBStartCode() throws {
        let first = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                nal(7, [0x64, 0x00, 0x15]),
                nal(8, [0xee, 0x3c]),
                nal(5, [0x88, 0x99]),
            ]),
            ptsTicks: 0,
            dtsTicks: 0
        )
        let malformed = H264PESPacket(
            payload: Data([0xde, 0xad, 0xbe, 0xef]),
            ptsTicks: 3_000,
            dtsTicks: 3_000
        )
        let second = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                nal(1, [0x77, 0x66]),
            ]),
            ptsTicks: 6_000,
            dtsTicks: 6_000
        )

        let batch = try H264AccessUnitAssembler.assemble(
            packets: [first, malformed, second],
            timescale: 90_000
        )
        #expect(batch.accessUnits.count == 2)
        #expect(batch.accessUnits.map(\.isKeyFrame) == [true, false])
        #expect(batch.accessUnits.map(\.nalTypes) == [[9, 7, 8, 5], [9, 1]])

        var assembler = StreamingH264AccessUnitAssembler()
        var streamingUnits: [H264AccessUnit] = []
        var readyEventCount = 0

        for packet in [first, malformed, second] {
            let output = assembler.append([packet])
            streamingUnits.append(contentsOf: output.accessUnits)
            if output.didBecomeReady {
                readyEventCount += 1
            }
        }
        streamingUnits.append(contentsOf: assembler.finish().accessUnits)

        #expect(readyEventCount == 1)
        #expect(streamingUnits == batch.accessUnits)
    }

    @Test(.timeLimit(.minutes(1)))
    func streamingAssemblerMatchesBatchAssemblerOnFixture() throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let packets = try TSDemuxer.demuxH264PESPackets(from: data)
        let expected = try H264AccessUnitAssembler.assemble(
            packets: packets,
            timescale: 90_000
        )

        var assembler = StreamingH264AccessUnitAssembler()
        var actualUnits: [H264AccessUnit] = []
        var actualSPS: Data?
        var actualPPS: Data?
        var readyEventCount = 0

        for packet in packets {
            let output = assembler.append([packet])
            actualUnits.append(contentsOf: output.accessUnits)
            if let sps = output.sps {
                actualSPS = sps
            }
            if let pps = output.pps {
                actualPPS = pps
            }
            if output.didBecomeReady {
                readyEventCount += 1
            }
        }

        actualUnits.append(contentsOf: assembler.finish().accessUnits)

        #expect(actualSPS == expected.sps)
        #expect(actualPPS == expected.pps)
        #expect(readyEventCount == 1)
        try assertAccessUnits(
            actualUnits,
            match: expected.accessUnits,
            finalDurationToleranceTicks: 3_000
        )
    }

    @Test
    func streamingAssemblerBecomesReadyOnlyAfterBothParameterSets() throws {
        let sps = nal(7, [0x64, 0x00, 0x15])
        let pps = nal(8, [0xee, 0x3c])
        var assembler = StreamingH264AccessUnitAssembler()

        let spsOutput = assembler.append([
            H264PESPacket(payload: annexB([sps]), ptsTicks: 0, dtsTicks: 0),
        ])
        #expect(spsOutput.sps == sps)
        #expect(spsOutput.pps == nil)
        #expect(spsOutput.didBecomeReady == false)
        #expect(spsOutput.accessUnits.isEmpty)

        let ppsOutput = assembler.append([
            H264PESPacket(payload: annexB([pps]), ptsTicks: 3_000, dtsTicks: 3_000),
        ])
        #expect(ppsOutput.sps == nil)
        #expect(ppsOutput.pps == pps)
        #expect(ppsOutput.didBecomeReady)
        #expect(ppsOutput.accessUnits.isEmpty)

        let sliceOutput = assembler.append([
            H264PESPacket(
                payload: annexB([
                    nal(9, [0xf0]),
                    nal(7, [0x65]),
                    nal(8, [0xef]),
                    nal(5, [0x88]),
                ]),
                ptsTicks: 6_000,
                dtsTicks: 6_000
            ),
        ])
        #expect(sliceOutput.sps == nil)
        #expect(sliceOutput.pps == nil)
        #expect(sliceOutput.didBecomeReady == false)
        #expect(sliceOutput.accessUnits.isEmpty)

        let finalOutput = assembler.finish()
        #expect(finalOutput.didBecomeReady == false)
        #expect(finalOutput.accessUnits.count == 1)
    }

    @Test
    func streamingAssemblerSubdividesMultiAccessUnitPESWhenNextDTSArrives() throws {
        var assembler = StreamingH264AccessUnitAssembler()
        let multiUnitPacket = H264PESPacket(
            payload: annexB([
                nal(7, [0x64]),
                nal(8, [0xee]),
                nal(9, [0xf0]),
                nal(5, [0x88]),
                nal(9, [0xf0]),
                nal(1, [0x99]),
            ]),
            ptsTicks: 0,
            dtsTicks: 0
        )
        let nextPacket = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                nal(1, [0xaa]),
            ]),
            ptsTicks: 6_000,
            dtsTicks: 6_000
        )

        let firstOutput = assembler.append([multiUnitPacket])
        #expect(firstOutput.didBecomeReady)
        #expect(firstOutput.accessUnits.isEmpty)

        let secondOutput = assembler.append([nextPacket])
        #expect(secondOutput.accessUnits.count == 2)
        #expect(secondOutput.accessUnits.map(\.dtsTicks) == [0, 3_000])
        #expect(secondOutput.accessUnits.map(\.durationTicks) == [3_000, 3_000])
        #expect(secondOutput.accessUnits.map(\.isKeyFrame) == [true, false])
        #expect(secondOutput.accessUnits.map(\.nalTypes) == [[7, 8, 9, 5], [9, 1]])

        let finalOutput = assembler.finish()
        #expect(finalOutput.accessUnits.count == 1)
        let finalAccessUnit = try #require(finalOutput.accessUnits.first)
        #expect(finalAccessUnit.dtsTicks == 6_000)
        #expect(finalAccessUnit.durationTicks == 3_000)
    }

    @Test
    func streamingAssemblerDropsOutOfOrderDTS() {
        let packets = outOfOrderDTSPackets()

        var assembler = StreamingH264AccessUnitAssembler()
        var units: [H264AccessUnit] = []
        for packet in packets {
            units.append(contentsOf: assembler.append([packet]).accessUnits)
        }
        units.append(contentsOf: assembler.finish().accessUnits)

        #expect(units.count == 3)
        #expect(units.map(\.dtsTicks) == [0, 3_000, 6_000])
        #expect(units.map(\.isKeyFrame) == [true, false, false])
    }

    @Test
    func batchAssemblerDropsOutOfOrderDTS() throws {
        let clip = try H264AccessUnitAssembler.assemble(
            packets: outOfOrderDTSPackets(),
            timescale: 90_000
        )

        #expect(clip.accessUnits.count == 3)
        #expect(clip.accessUnits.map(\.dtsTicks) == [0, 3_000, 6_000])
        #expect(clip.accessUnits.map(\.isKeyFrame) == [true, false, false])
    }

    @Test
    func assemblersTruncateAndAgreeAtDTSWrap() throws {
        let base = Int64(1) << 33
        let p0 = H264PESPacket(
            payload: annexB([nal(9, [0xf0]), nal(7, [0x64]), nal(8, [0xee]), nal(5, [0x88])]),
            ptsTicks: base - 6_000,
            dtsTicks: base - 6_000
        )
        let p1 = H264PESPacket(
            payload: annexB([nal(9, [0xf0]), nal(1, [0x11])]),
            ptsTicks: base - 3_000,
            dtsTicks: base - 3_000
        )
        let p2 = H264PESPacket(
            payload: annexB([nal(9, [0xf0]), nal(1, [0x22])]),
            ptsTicks: 0,
            dtsTicks: 0
        )
        let p3 = H264PESPacket(
            payload: annexB([nal(9, [0xf0]), nal(1, [0x33])]),
            ptsTicks: 3_000,
            dtsTicks: 3_000
        )
        let packets = [p0, p1, p2, p3]

        let batch = try H264AccessUnitAssembler.assemble(packets: packets, timescale: 90_000)

        var assembler = StreamingH264AccessUnitAssembler()
        var streamingUnits: [H264AccessUnit] = []
        for packet in packets {
            streamingUnits.append(contentsOf: assembler.append([packet]).accessUnits)
        }
        streamingUnits.append(contentsOf: assembler.finish().accessUnits)

        #expect(batch.accessUnits.count == 2)
        #expect(batch.accessUnits.map(\.dtsTicks) == [base - 6_000, base - 3_000])
        try assertAccessUnits(
            streamingUnits,
            match: batch.accessUnits,
            finalDurationToleranceTicks: 3_000
        )
    }

    /// An isolated backward-DTS glitch: `P_bad` (dts 1000) steps back between `P1`
    /// (dts 3000) and `P2` (dts 6000). Both assemblers drop `P_bad` and keep the
    /// three in-order units.
    private func outOfOrderDTSPackets() -> [H264PESPacket] {
        [
            H264PESPacket(
                payload: annexB([nal(9, [0xf0]), nal(7, [0x64]), nal(8, [0xee]), nal(5, [0x88])]),
                ptsTicks: 0,
                dtsTicks: 0
            ),
            H264PESPacket(
                payload: annexB([nal(9, [0xf0]), nal(1, [0x11])]),
                ptsTicks: 3_000,
                dtsTicks: 3_000
            ),
            H264PESPacket(
                payload: annexB([nal(9, [0xf0]), nal(1, [0x22])]),
                ptsTicks: 1_000,
                dtsTicks: 1_000
            ),
            H264PESPacket(
                payload: annexB([nal(9, [0xf0]), nal(1, [0x33])]),
                ptsTicks: 6_000,
                dtsTicks: 6_000
            ),
        ]
    }

    private func annexB(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { output, unit in
            output.append(Data([0x00, 0x00, 0x00, 0x01]))
            output.append(unit)
        }
    }

    private func nal(_ type: UInt8, _ payload: [UInt8]) -> Data {
        var data = Data([type])
        data.append(contentsOf: payload)
        return data
    }

    private func avcc(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { output, unit in
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
    }

    private func assertAccessUnits(
        _ actual: [H264AccessUnit],
        match expected: [H264AccessUnit],
        finalDurationToleranceTicks: Int64,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try #require(actual.count == expected.count, sourceLocation: sourceLocation)
        try #require(expected.isEmpty == false, sourceLocation: sourceLocation)

        let lastIndex = expected.count - 1
        for index in expected.indices {
            let actualUnit = actual[index]
            let expectedUnit = expected[index]

            #expect(
                actualUnit.sampleData == expectedUnit.sampleData,
                "sample data at \(index)",
                sourceLocation: sourceLocation
            )
            #expect(
                actualUnit.ptsTicks == expectedUnit.ptsTicks,
                "PTS at \(index)",
                sourceLocation: sourceLocation
            )
            #expect(
                actualUnit.dtsTicks == expectedUnit.dtsTicks,
                "DTS at \(index)",
                sourceLocation: sourceLocation
            )
            #expect(
                actualUnit.isKeyFrame == expectedUnit.isKeyFrame,
                "key frame at \(index)",
                sourceLocation: sourceLocation
            )
            #expect(
                actualUnit.nalTypes == expectedUnit.nalTypes,
                "NAL types at \(index)",
                sourceLocation: sourceLocation
            )

            if index == lastIndex {
                let difference = abs(actualUnit.durationTicks - expectedUnit.durationTicks)
                #expect(
                    difference <= finalDurationToleranceTicks,
                    "final duration at \(index)",
                    sourceLocation: sourceLocation
                )
            } else {
                #expect(
                    actualUnit.durationTicks == expectedUnit.durationTicks,
                    "duration at \(index)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}
