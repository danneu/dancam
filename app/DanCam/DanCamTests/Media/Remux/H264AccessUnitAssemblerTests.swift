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
    }

    @Test
    func dropsLeadingNonKeyframeWhenParameterSetsArriveLate() throws {
        let first = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                nal(1, [0x11]),
            ]),
            ptsTicks: 0,
            dtsTicks: 0
        )
        let second = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                nal(7, [0x64, 0x00, 0x15]),
                nal(8, [0xee, 0x3c]),
                nal(5, [0x88]),
            ]),
            ptsTicks: 3_000,
            dtsTicks: 3_000
        )

        let clip = try H264AccessUnitAssembler.assemble(
            packets: [first, second],
            timescale: 90_000
        )

        #expect(clip.accessUnits.count == 1)
        #expect(clip.accessUnits[0].isKeyFrame)
        #expect(clip.accessUnits[0].nalTypes == [9, 7, 8, 5])
    }

    @Test
    func dropsLeadingNonKeyframeEvenWhenParameterSetsAlreadyLatched() throws {
        let sps = nal(7, [0x64, 0x00, 0x15])
        let pps = nal(8, [0xee, 0x3c])
        let first = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                sps,
                pps,
                nal(1, [0x11]),
            ]),
            ptsTicks: 0,
            dtsTicks: 0
        )
        let second = H264PESPacket(
            payload: annexB([
                nal(9, [0xf0]),
                nal(5, [0x88]),
            ]),
            ptsTicks: 3_000,
            dtsTicks: 3_000
        )

        let clip = try H264AccessUnitAssembler.assemble(
            packets: [first, second],
            timescale: 90_000
        )

        #expect(clip.accessUnits.count == 1)
        #expect(clip.accessUnits[0].isKeyFrame)
        #expect(clip.accessUnits[0].nalTypes == [9, 5])
        #expect(clip.sps == sps)
        #expect(clip.pps == pps)
    }

    @Test
    func throwsWhenClipHasNoKeyframe() throws {
        let packets = [
            H264PESPacket(
                payload: annexB([
                    nal(9, [0xf0]),
                    nal(7, [0x64, 0x00, 0x15]),
                    nal(8, [0xee, 0x3c]),
                    nal(1, [0x11]),
                ]),
                ptsTicks: 0,
                dtsTicks: 0
            ),
            H264PESPacket(
                payload: annexB([
                    nal(9, [0xf0]),
                    nal(1, [0x22]),
                ]),
                ptsTicks: 3_000,
                dtsTicks: 3_000
            ),
        ]

        do {
            _ = try H264AccessUnitAssembler.assemble(
                packets: packets,
                timescale: 90_000
            )
            Issue.record("Expected keyframe-less H.264 to throw.")
        } catch ClipRemuxError.invalidH264(_) {
        } catch {
            Issue.record("Expected ClipRemuxError.invalidH264, got \(error).")
        }
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

}
