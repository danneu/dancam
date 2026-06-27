import Foundation
import Testing
@testable import DanCam

struct H264AccessUnitAssemblerTests {
    @Test
    func parsesAnnexBStartCodesAndNALTypes() throws {
        let units = try H264AccessUnitAssembler.splitAnnexB(Data([
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
