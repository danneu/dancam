import Foundation

nonisolated enum TSDemuxer {
    private static let packetSize = 188
    private static let clockTimescale: Int32 = 90_000

    static func demuxH264(from url: URL) throws -> DemuxedH264Clip {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ClipRemuxError.file("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }

        return try demuxH264(from: data)
    }

    static func demuxH264(from data: Data) throws -> DemuxedH264Clip {
        guard data.count >= packetSize, data.count % packetSize == 0 else {
            throw ClipRemuxError.invalidTransportStream("Transport stream size is not packet-aligned.")
        }

        var pmtPID: UInt16?
        var videoPID: UInt16?
        var currentPES: PartialPES?
        var packets: [H264PESPacket] = []

        for packetOffset in stride(from: 0, to: data.count, by: packetSize) {
            guard data[packetOffset] == 0x47 else {
                throw ClipRemuxError.invalidTransportStream("Missing sync byte at TS packet \(packetOffset / packetSize).")
            }

            let payloadUnitStart = (data[packetOffset + 1] & 0x40) != 0
            let pid = UInt16(data[packetOffset + 1] & 0x1f) << 8
                | UInt16(data[packetOffset + 2])
            let adaptationControl = (data[packetOffset + 3] & 0x30) >> 4

            guard adaptationControl != 0 else {
                throw ClipRemuxError.invalidTransportStream("Reserved adaptation-control value.")
            }

            var payloadOffset = packetOffset + 4
            if adaptationControl == 2 || adaptationControl == 3 {
                guard payloadOffset < packetOffset + packetSize else {
                    throw ClipRemuxError.invalidTransportStream("Missing adaptation-field length.")
                }
                let adaptationLength = Int(data[payloadOffset])
                payloadOffset += 1 + adaptationLength
            }

            guard adaptationControl == 1 || adaptationControl == 3 else {
                continue
            }
            guard payloadOffset <= packetOffset + packetSize else {
                throw ClipRemuxError.invalidTransportStream("Adaptation field overruns TS packet.")
            }

            let payload = Data(data[payloadOffset..<(packetOffset + packetSize)])
            guard payload.isEmpty == false else { continue }

            if pid == 0 {
                if let parsedPMTPID = try parsePAT(payload, payloadUnitStart: payloadUnitStart) {
                    pmtPID = parsedPMTPID
                }
                continue
            }

            if let pmtPID, pid == pmtPID {
                if let parsedVideoPID = try parsePMT(payload, payloadUnitStart: payloadUnitStart) {
                    videoPID = parsedVideoPID
                }
                continue
            }

            guard let videoPID, pid == videoPID else {
                continue
            }

            if payloadUnitStart {
                finish(&currentPES, into: &packets)
                currentPES = try parsePESStart(payload)
            } else {
                currentPES?.payload.append(payload)
            }
        }

        finish(&currentPES, into: &packets)

        guard packets.isEmpty == false else {
            throw ClipRemuxError.invalidTransportStream("No H.264 PES packets found.")
        }

        return try H264AccessUnitAssembler.assemble(
            packets: packets,
            timescale: clockTimescale
        )
    }

    private static func parsePAT(
        _ payload: Data,
        payloadUnitStart: Bool
    ) throws -> UInt16? {
        guard payloadUnitStart else { return nil }
        let section = try psiSection(in: payload, expectedTableID: 0x00)
        let end = section.count - 4
        var offset = 8

        while offset + 4 <= end {
            let programNumber = UInt16(section[offset]) << 8 | UInt16(section[offset + 1])
            let pid = UInt16(section[offset + 2] & 0x1f) << 8 | UInt16(section[offset + 3])
            if programNumber != 0 {
                return pid
            }
            offset += 4
        }

        return nil
    }

    private static func parsePMT(
        _ payload: Data,
        payloadUnitStart: Bool
    ) throws -> UInt16? {
        guard payloadUnitStart else { return nil }
        let section = try psiSection(in: payload, expectedTableID: 0x02)
        guard section.count >= 16 else {
            throw ClipRemuxError.invalidTransportStream("PMT section is too short.")
        }

        let sectionEnd = section.count - 4
        let programInfoLength = Int(section[10] & 0x0f) << 8 | Int(section[11])
        var offset = 12 + programInfoLength

        while offset + 5 <= sectionEnd {
            let streamType = section[offset]
            let elementaryPID = UInt16(section[offset + 1] & 0x1f) << 8 | UInt16(section[offset + 2])
            let esInfoLength = Int(section[offset + 3] & 0x0f) << 8 | Int(section[offset + 4])

            if streamType == 0x1b {
                return elementaryPID
            }

            offset += 5 + esInfoLength
        }

        return nil
    }

    private static func psiSection(
        in payload: Data,
        expectedTableID: UInt8
    ) throws -> Data {
        guard let pointer = payload.first else {
            throw ClipRemuxError.invalidTransportStream("Missing PSI pointer field.")
        }
        let sectionOffset = 1 + Int(pointer)
        guard sectionOffset + 3 <= payload.count else {
            throw ClipRemuxError.invalidTransportStream("PSI pointer overruns payload.")
        }

        let section = Data(payload[sectionOffset...])
        guard section[0] == expectedTableID else {
            return Data()
        }

        let sectionLength = Int(section[1] & 0x0f) << 8 | Int(section[2])
        let totalLength = 3 + sectionLength
        guard totalLength <= section.count else {
            throw ClipRemuxError.invalidTransportStream("PSI section spans multiple packets.")
        }

        return Data(section[..<totalLength])
    }

    private static func parsePESStart(_ payload: Data) throws -> PartialPES {
        guard payload.count >= 9 else {
            throw ClipRemuxError.invalidTransportStream("PES header is too short.")
        }
        guard payload[0] == 0, payload[1] == 0, payload[2] == 1 else {
            throw ClipRemuxError.invalidTransportStream("Missing PES start code.")
        }

        let timestampFlags = (payload[7] & 0xc0) >> 6
        let headerLength = Int(payload[8])
        let payloadOffset = 9 + headerLength
        guard payloadOffset <= payload.count else {
            throw ClipRemuxError.invalidTransportStream("PES header overruns payload.")
        }
        guard timestampFlags == 0b10 || timestampFlags == 0b11 else {
            throw ClipRemuxError.invalidTransportStream("PES packet is missing PTS.")
        }

        let ptsOffset = 9
        guard ptsOffset + 5 <= payload.count else {
            throw ClipRemuxError.invalidTransportStream("PES packet has truncated PTS.")
        }
        let pts = decodeTimestamp(payload, offset: ptsOffset)

        let dts: Int64
        if timestampFlags == 0b11 {
            let dtsOffset = ptsOffset + 5
            guard dtsOffset + 5 <= payload.count else {
                throw ClipRemuxError.invalidTransportStream("PES packet has truncated DTS.")
            }
            dts = decodeTimestamp(payload, offset: dtsOffset)
        } else {
            dts = pts
        }

        return PartialPES(
            ptsTicks: pts,
            dtsTicks: dts,
            payload: Data(payload[payloadOffset...])
        )
    }

    private static func decodeTimestamp(_ data: Data, offset: Int) -> Int64 {
        let high = Int64((data[offset] >> 1) & 0x07) << 30
        let middle = (Int64(data[offset + 1]) << 7 | Int64(data[offset + 2] >> 1)) << 15
        let low = Int64(data[offset + 3]) << 7 | Int64(data[offset + 4] >> 1)
        return high | middle | low
    }

    private static func finish(
        _ partial: inout PartialPES?,
        into packets: inout [H264PESPacket]
    ) {
        guard let completed = partial, completed.payload.isEmpty == false else {
            partial = nil
            return
        }

        packets.append(H264PESPacket(
            payload: completed.payload,
            ptsTicks: completed.ptsTicks,
            dtsTicks: completed.dtsTicks
        ))
        partial = nil
    }

    private struct PartialPES {
        var ptsTicks: Int64
        var dtsTicks: Int64
        var payload: Data
    }
}
