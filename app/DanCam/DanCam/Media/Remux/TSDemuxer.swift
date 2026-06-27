import Foundation
import OSLog

nonisolated enum TSDemuxer {
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
        let packets = try demuxH264PESPackets(from: data)

        return try H264AccessUnitAssembler.assemble(
            packets: packets,
            timescale: TransportStreamH264Parser.clockTimescale
        )
    }

    static func demuxH264PESPackets(from data: Data) throws -> [H264PESPacket] {
        guard data.count >= TransportStreamH264Parser.packetSize,
              data.count % TransportStreamH264Parser.packetSize == 0
        else {
            throw ClipRemuxError.invalidTransportStream("Transport stream size is not packet-aligned.")
        }

        var parserState = TransportStreamH264Parser.State()

        for packetOffset in stride(from: 0, to: data.count, by: TransportStreamH264Parser.packetSize) {
            try TransportStreamH264Parser.processPacket(
                from: data,
                packetOffset: packetOffset,
                packetIndex: packetOffset / TransportStreamH264Parser.packetSize,
                state: &parserState
            )
        }

        TransportStreamH264Parser.finish(&parserState)

        guard parserState.packets.isEmpty == false else {
            throw ClipRemuxError.invalidTransportStream("No H.264 PES packets found.")
        }

        return parserState.packets
    }
}

nonisolated struct IncrementalTSDemuxer {
    private static let logger = Logger(subsystem: "com.danneu.dancam", category: "ts-demux")

    private var residual = Data()
    private var parserState = TransportStreamH264Parser.State()
    private var packetIndex = 0
    private var isSynced = true
    private var didLogResync = false

    init(clockTimescale _: Int32 = TransportStreamH264Parser.clockTimescale) {
    }

    mutating func append(_ chunk: Data) throws -> [H264PESPacket] {
        residual.append(chunk)

        var consumed = 0
        while residual.count - consumed >= TransportStreamH264Parser.packetSize {
            if isSynced == false || residual[consumed] != 0x47 {
                guard let resyncOffset = Self.findResyncOffset(in: residual, from: consumed) else {
                    isSynced = false
                    preserveUnvalidatedTail(startingAt: consumed)
                    return parserState.drainPackets()
                }

                logResyncIfNeeded(skippedByteCount: resyncOffset - consumed)
                consumed = resyncOffset
                isSynced = true
            }

            try TransportStreamH264Parser.processPacket(
                from: residual,
                packetOffset: consumed,
                packetIndex: packetIndex,
                state: &parserState
            )
            consumed += TransportStreamH264Parser.packetSize
            packetIndex += 1
        }

        if consumed > 0 {
            residual = Data(residual[consumed...])
        }

        return parserState.drainPackets()
    }

    mutating func finish() -> [H264PESPacket] {
        residual.removeAll(keepingCapacity: true)
        TransportStreamH264Parser.finish(&parserState)
        return parserState.drainPackets()
    }

    private static func findResyncOffset(in data: Data, from start: Int) -> Int? {
        var offset = start
        while offset + (TransportStreamH264Parser.packetSize * 2) < data.count {
            if data[offset] == 0x47,
               data[offset + TransportStreamH264Parser.packetSize] == 0x47,
               data[offset + (TransportStreamH264Parser.packetSize * 2)] == 0x47 {
                return offset
            }
            offset += 1
        }

        return nil
    }

    private mutating func preserveUnvalidatedTail(startingAt start: Int) {
        let tailLength = TransportStreamH264Parser.packetSize * 2
        let preserveStart = max(start, residual.count - tailLength)
        residual = Data(residual[preserveStart...])
    }

    private mutating func logResyncIfNeeded(skippedByteCount: Int) {
        guard didLogResync == false else { return }

        didLogResync = true
        Self.logger.notice("Resynchronized TS parser after dropping \(skippedByteCount) bytes.")
    }
}

nonisolated enum TransportStreamH264Parser {
    static let packetSize = 188
    static let clockTimescale: Int32 = 90_000

    struct State {
        fileprivate var pmtPID: UInt16?
        fileprivate var videoPID: UInt16?
        private var currentPES: PartialPES?
        fileprivate(set) var packets: [H264PESPacket] = []

        fileprivate mutating func startPES(from payload: Data) throws {
            finishCurrentPES()
            currentPES = try TransportStreamH264Parser.parsePESStart(payload)
        }

        fileprivate mutating func appendToCurrentPES(_ payload: Data) {
            currentPES?.payload.append(payload)
        }

        fileprivate mutating func finishCurrentPES() {
            TransportStreamH264Parser.finishCurrentPES(&currentPES, into: &packets)
        }

        fileprivate mutating func drainPackets() -> [H264PESPacket] {
            defer { packets.removeAll(keepingCapacity: true) }
            return packets
        }
    }

    static func processPacket(
        from data: Data,
        packetOffset: Int,
        packetIndex: Int,
        state: inout State
    ) throws {
        guard data[packetOffset] == 0x47 else {
            throw ClipRemuxError.invalidTransportStream("Missing sync byte at TS packet \(packetIndex).")
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
            return
        }
        guard payloadOffset <= packetOffset + packetSize else {
            throw ClipRemuxError.invalidTransportStream("Adaptation field overruns TS packet.")
        }

        let payload = Data(data[payloadOffset..<(packetOffset + packetSize)])
        guard payload.isEmpty == false else { return }

        if pid == 0 {
            if let parsedPMTPID = try parsePAT(payload, payloadUnitStart: payloadUnitStart) {
                state.pmtPID = parsedPMTPID
            }
            return
        }

        if let pmtPID = state.pmtPID, pid == pmtPID {
            if let parsedVideoPID = try parsePMT(payload, payloadUnitStart: payloadUnitStart) {
                state.videoPID = parsedVideoPID
            }
            return
        }

        guard let videoPID = state.videoPID, pid == videoPID else {
            return
        }

        if payloadUnitStart {
            try state.startPES(from: payload)
        } else {
            state.appendToCurrentPES(payload)
        }
    }

    static func finish(_ state: inout State) {
        state.finishCurrentPES()
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

    private static func finishCurrentPES(
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
