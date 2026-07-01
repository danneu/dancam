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
        // The finalizer shares the tolerant incremental path: it resyncs after
        // garbage, skips per-packet anomalies (dropping at most one PES each),
        // drops any sub-188-byte residual tail, and emits the final truncated PES
        // as-is so the MP4 can play up to the cut. Appending the whole file creates
        // one transient copy into the demuxer's residual.
        var demuxer = IncrementalTSDemuxer()
        var packets = demuxer.append(data)
        packets.append(contentsOf: demuxer.finish())

        guard packets.isEmpty == false else {
            throw ClipRemuxError.invalidTransportStream("No H.264 PES packets found.")
        }

        return packets
    }
}

nonisolated struct IncrementalTSDemuxer {
    private static let logger = Log.tsDemux

    private var residual = Data()
    private var parserState = TransportStreamH264Parser.State()
    private var isSynced = true
    private var didLogResync = false
    private var droppedPacketCount = 0
    private var didLogDroppedPacket = false

    init(clockTimescale _: Int32 = TransportStreamH264Parser.clockTimescale) {
    }

    // Never throws: a per-packet anomaly can only skip that packet (dropping at
    // most one PES), never abort the clip. The only failure surfaced to callers is
    // the terminal "no packets at all" case in `demuxH264PESPackets`.
    mutating func append(_ chunk: Data) -> [H264PESPacket] {
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

            switch TransportStreamH264Parser.processPacket(
                from: residual,
                packetOffset: consumed,
                state: &parserState
            ) {
            case .parsed:
                break
            case .skipped(let reason):
                droppedPacketCount += 1
                logDroppedPacketIfNeeded(reason)
            }
            // Advance unconditionally so forward progress never depends on the
            // packet parsing cleanly (the infinite-loop defense).
            consumed += TransportStreamH264Parser.packetSize
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

    private mutating func logDroppedPacketIfNeeded(_ reason: TransportStreamH264Parser.SkipReason) {
        guard didLogDroppedPacket == false else { return }

        didLogDroppedPacket = true
        Self.logger.notice("Skipped a corrupt TS packet (\(String(describing: reason))) and continued.")
    }
}

nonisolated enum TransportStreamH264Parser {
    static let packetSize = 188
    static let clockTimescale: Int32 = 90_000

    /// Why a single packet was skipped. Every case drops at most one PES; none
    /// aborts the clip. Kept as a total-function outcome so "a per-packet anomaly
    /// can never abort a clip" is compiler-enforced.
    enum SkipReason: Error, Equatable, Sendable {
        case reservedAdaptationControl
        case missingAdaptationLength
        case adaptationOverrun
        case psiPointerMissing
        case psiPointerOverrun
        case psiSectionSpansPackets
        case pmtTooShort
        case pesHeaderTooShort
        case pesStartCodeMissing
        case pesHeaderOverrun
        case pesMissingPTS
        case pesTruncatedPTS
        case pesTruncatedDTS
        case pesTimestampMarkerInvalid
        case pesNonMonotonicDTS
    }

    enum PacketOutcome: Equatable, Sendable {
        case parsed
        case skipped(SkipReason)
    }

    struct State {
        fileprivate var pmtPID: UInt16?
        fileprivate var videoPID: UInt16?
        private var currentPES: PartialPES?
        /// The last trusted, already-emitted DTS. The ordering check demotes any
        /// later PES whose DTS falls at or below this baseline.
        private var lastFinishedDTS: Int64?
        fileprivate(set) var packets: [H264PESPacket] = []

        fileprivate mutating func startPES(from payload: Data) throws(SkipReason) {
            let candidate: PartialPES
            do {
                candidate = try TransportStreamH264Parser.parsePESStart(payload)
            } catch {
                // PES-header corruption: flush the previous good frame and drop the
                // corrupt start. The flush persists even though we then rethrow.
                finishCurrentPES()
                throw error
            }

            try admitCandidate(candidate)
        }

        // Vets a freshly-parsed PES against the one-frame lookahead (`currentPES`)
        // and the trusted baseline (`lastFinishedDTS`) so the emitted DTS stream
        // stays monotonic. A throw signals a drop; the state mutations made before
        // it (flush/discard/install) persist.
        private mutating func admitCandidate(_ candidate: PartialPES) throws(SkipReason) {
            guard let cur = currentPES else {
                // Nothing held. Install unless the candidate dips at/below the
                // trusted baseline. With no baseline yet, always install.
                if let lastFinishedDTS, candidate.dtsTicks <= lastFinishedDTS {
                    throw .pesNonMonotonicDTS
                }
                currentPES = candidate
                return
            }

            guard let lastFinishedDTS else {
                // Held frame but no baseline yet (start-of-stream window): the held
                // frame is the sole anchor, so it must never be discarded here.
                if candidate.dtsTicks > cur.dtsTicks {
                    finishCurrentPES()
                    currentPES = candidate
                    return
                }
                // Non-monotonic with no baseline: keep the held frame, drop the
                // candidate. Never discard the held frame (the F1 total-loss path).
                finishCurrentPES()
                throw .pesNonMonotonicDTS
            }

            // Steady state: the invariant `lastFinishedDTS < cur.dtsTicks` holds.
            if candidate.dtsTicks > cur.dtsTicks {
                // Monotonic: emit the held frame, install the candidate.
                finishCurrentPES()
                currentPES = candidate
                return
            }
            if candidate.dtsTicks > lastFinishedDTS {
                // The held frame is the spike: drop it unemitted, install the
                // candidate. Baseline is unchanged.
                discardCurrentPES()
                currentPES = candidate
                throw .pesNonMonotonicDTS
            }
            // The candidate is the dip: the held previous frame is good, so emit it
            // and drop the candidate.
            finishCurrentPES()
            throw .pesNonMonotonicDTS
        }

        fileprivate mutating func appendToCurrentPES(_ payload: Data) {
            currentPES?.payload.append(payload)
        }

        fileprivate mutating func finishCurrentPES() {
            guard let completed = currentPES, completed.payload.isEmpty == false else {
                currentPES = nil
                return
            }

            packets.append(H264PESPacket(
                payload: completed.payload,
                ptsTicks: completed.ptsTicks,
                dtsTicks: completed.dtsTicks
            ))
            lastFinishedDTS = completed.dtsTicks
            currentPES = nil
        }

        fileprivate mutating func discardCurrentPES() {
            currentPES = nil
        }

        // Recovery-granularity policy for an adaptation-level anomaly on the video
        // PID: at a PES boundary the previous frame is complete (flush it); on a
        // continuation the in-flight frame is gap-corrupted (drop it). Anomalies on
        // PSI or other PIDs leave the in-flight video PES intact.
        fileprivate mutating func applyAdaptationRecovery(pid: UInt16, payloadUnitStart: Bool) {
            guard let videoPID, pid == videoPID else { return }
            if payloadUnitStart {
                finishCurrentPES()
            } else {
                discardCurrentPES()
            }
        }

        fileprivate mutating func drainPackets() -> [H264PESPacket] {
            defer { packets.removeAll(keepingCapacity: true) }
            return packets
        }
    }

    static func processPacket(
        from data: Data,
        packetOffset: Int,
        state: inout State
    ) -> PacketOutcome {
        do {
            try parse(from: data, packetOffset: packetOffset, state: &state)
            return .parsed
        } catch {
            return .skipped(error)
        }
    }

    private static func parse(
        from data: Data,
        packetOffset: Int,
        state: inout State
    ) throws(SkipReason) {
        // `append`'s resync logic owns alignment; by the time a packet reaches the
        // parser it always starts on a sync byte.
        assert(data[packetOffset] == 0x47)

        let payloadUnitStart = (data[packetOffset + 1] & 0x40) != 0
        let pid = UInt16(data[packetOffset + 1] & 0x1f) << 8
            | UInt16(data[packetOffset + 2])
        let adaptationControl = (data[packetOffset + 3] & 0x30) >> 4

        let payloadOffset: Int
        do {
            payloadOffset = try adaptationPayloadOffset(
                data,
                packetOffset: packetOffset,
                adaptationControl: adaptationControl
            )
        } catch {
            // pid and PUSI are known before any anomaly, so route recovery
            // precisely, then surface the skip.
            state.applyAdaptationRecovery(pid: pid, payloadUnitStart: payloadUnitStart)
            throw error
        }

        guard adaptationControl == 1 || adaptationControl == 3 else {
            return
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

    private static func adaptationPayloadOffset(
        _ data: Data,
        packetOffset: Int,
        adaptationControl: UInt8
    ) throws(SkipReason) -> Int {
        guard adaptationControl != 0 else {
            throw .reservedAdaptationControl
        }

        var payloadOffset = packetOffset + 4
        if adaptationControl == 2 || adaptationControl == 3 {
            guard payloadOffset < packetOffset + packetSize else {
                throw .missingAdaptationLength
            }
            let adaptationLength = Int(data[payloadOffset])
            payloadOffset += 1 + adaptationLength
        }

        if adaptationControl == 1 || adaptationControl == 3 {
            guard payloadOffset <= packetOffset + packetSize else {
                throw .adaptationOverrun
            }
        }

        return payloadOffset
    }

    private static func parsePAT(
        _ payload: Data,
        payloadUnitStart: Bool
    ) throws(SkipReason) -> UInt16? {
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
    ) throws(SkipReason) -> UInt16? {
        guard payloadUnitStart else { return nil }
        let section = try psiSection(in: payload, expectedTableID: 0x02)
        guard section.count >= 16 else {
            throw .pmtTooShort
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
    ) throws(SkipReason) -> Data {
        guard let pointer = payload.first else {
            throw .psiPointerMissing
        }
        let sectionOffset = 1 + Int(pointer)
        guard sectionOffset + 3 <= payload.count else {
            throw .psiPointerOverrun
        }

        let section = Data(payload[sectionOffset...])
        guard section[0] == expectedTableID else {
            return Data()
        }

        let sectionLength = Int(section[1] & 0x0f) << 8 | Int(section[2])
        let totalLength = 3 + sectionLength
        guard totalLength <= section.count else {
            throw .psiSectionSpansPackets
        }

        return Data(section[..<totalLength])
    }

    private static func parsePESStart(_ payload: Data) throws(SkipReason) -> PartialPES {
        guard payload.count >= 9 else {
            throw .pesHeaderTooShort
        }
        guard payload[0] == 0, payload[1] == 0, payload[2] == 1 else {
            throw .pesStartCodeMissing
        }

        let timestampFlags = (payload[7] & 0xc0) >> 6
        let headerLength = Int(payload[8])
        let payloadOffset = 9 + headerLength
        guard payloadOffset <= payload.count else {
            throw .pesHeaderOverrun
        }
        guard timestampFlags == 0b10 || timestampFlags == 0b11 else {
            throw .pesMissingPTS
        }

        let ptsOffset = 9
        guard ptsOffset + 5 <= payload.count else {
            throw .pesTruncatedPTS
        }
        // Cheap syntax gate: the prefix nibble and interleaved marker bits are
        // mandated and invariant in well-formed output, so this never fires on a
        // clean stream but rejects a structurally broken timestamp header early.
        // It catches only the ~7/40 timestamp-bit flips that land on a prefix or
        // marker bit; the value-bit majority is left to the ordering check.
        let ptsPrefix: UInt8 = timestampFlags == 0b11 ? 0b0011 : 0b0010
        guard timestampMarkersValid(payload, offset: ptsOffset, expectedPrefix: ptsPrefix) else {
            throw .pesTimestampMarkerInvalid
        }
        let pts = decodeTimestamp(payload, offset: ptsOffset)

        let dts: Int64
        if timestampFlags == 0b11 {
            let dtsOffset = ptsOffset + 5
            guard dtsOffset + 5 <= payload.count else {
                throw .pesTruncatedDTS
            }
            guard timestampMarkersValid(payload, offset: dtsOffset, expectedPrefix: 0b0001) else {
                throw .pesTimestampMarkerInvalid
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

    private static func timestampMarkersValid(
        _ data: Data,
        offset: Int,
        expectedPrefix: UInt8
    ) -> Bool {
        (data[offset] >> 4) == expectedPrefix
            && (data[offset] & 0x01) == 1
            && (data[offset + 2] & 0x01) == 1
            && (data[offset + 4] & 0x01) == 1
    }

    private static func decodeTimestamp(_ data: Data, offset: Int) -> Int64 {
        let high = Int64((data[offset] >> 1) & 0x07) << 30
        let middle = (Int64(data[offset + 1]) << 7 | Int64(data[offset + 2] >> 1)) << 15
        let low = Int64(data[offset + 3]) << 7 | Int64(data[offset + 4] >> 1)
        return high | middle | low
    }

    private struct PartialPES {
        var ptsTicks: Int64
        var dtsTicks: Int64
        var payload: Data
    }
}
