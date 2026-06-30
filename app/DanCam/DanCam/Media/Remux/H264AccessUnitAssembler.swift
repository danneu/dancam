import Foundation
import OSLog

nonisolated enum H264AccessUnitAssembler {
    static func assemble(
        packets: [H264PESPacket],
        timescale: Int32
    ) throws -> DemuxedH264Clip {
        var sps: Data?
        var pps: Data?
        var pendingUnits: [PendingAccessUnit] = []

        let sortedPackets = packets.sorted(by: { $0.dtsTicks < $1.dtsTicks })
        for index in sortedPackets.indices {
            let packet = sortedPackets[index]
            let nalUnits = splitAnnexB(packet.payload)
            guard nalUnits.isEmpty == false else { continue }

            for nalUnit in nalUnits {
                switch nalUnit.type {
                case 7:
                    if sps == nil {
                        sps = nalUnit.data
                    }
                case 8:
                    if pps == nil {
                        pps = nalUnit.data
                    }
                default:
                    break
                }
            }

            let groups = splitAccessUnitGroups(nalUnits)
            let packetDuration = inferredPacketDuration(
                at: index,
                in: sortedPackets,
                groupCount: groups.count
            )

            for groupIndex in groups.indices {
                let group = groups[groupIndex]
                let sampleNALs = group.filter { nalUnit in
                    switch nalUnit.type {
                    case 7, 8, 9:
                        return false
                    default:
                        return true
                    }
                }
                guard sampleNALs.contains(where: isSliceNAL) else { continue }

                let offset = Int64(groupIndex) * packetDuration
                pendingUnits.append(PendingAccessUnit(
                    sampleData: avccSampleData(from: sampleNALs),
                    ptsTicks: packet.ptsTicks + offset,
                    dtsTicks: packet.dtsTicks + offset,
                    isKeyFrame: sampleNALs.contains { $0.type == 5 },
                    nalTypes: group.map(\.type)
                ))
            }
        }

        guard let sps, let pps else {
            throw ClipRemuxError.invalidH264("Missing SPS/PPS parameter sets.")
        }
        guard pendingUnits.isEmpty == false else {
            throw ClipRemuxError.invalidH264("No H.264 access units found.")
        }

        let frameDuration = inferredFrameDuration(from: pendingUnits)
        var accessUnits: [H264AccessUnit] = []
        accessUnits.reserveCapacity(pendingUnits.count)

        for index in pendingUnits.indices {
            let current = pendingUnits[index]
            let duration: Int64
            if pendingUnits.indices.contains(index + 1) {
                duration = pendingUnits[index + 1].dtsTicks - current.dtsTicks
                guard duration > 0 else {
                    throw ClipRemuxError.invalidH264("Access-unit DTS values are not strictly increasing.")
                }
            } else {
                duration = frameDuration
            }

            accessUnits.append(H264AccessUnit(
                sampleData: current.sampleData,
                ptsTicks: current.ptsTicks,
                dtsTicks: current.dtsTicks,
                durationTicks: duration,
                isKeyFrame: current.isKeyFrame,
                nalTypes: current.nalTypes
            ))
        }

        return DemuxedH264Clip(
            accessUnits: accessUnits,
            sps: sps,
            pps: pps,
            timescale: timescale
        )
    }

    static func splitAnnexB(_ data: Data) -> [H264NALUnit] {
        var nalUnits: [H264NALUnit] = []

        guard var startCode = findStartCode(in: data, from: 0) else {
            return []
        }

        while true {
            let nalStart = startCode.end
            let nextStartCode = findStartCode(in: data, from: nalStart)
            let nalEnd = nextStartCode?.start ?? data.count
            appendNALUnit(from: data, start: nalStart, end: nalEnd, into: &nalUnits)

            guard let nextStartCode else {
                break
            }
            startCode = nextStartCode
        }

        return nalUnits
    }

    static func splitAccessUnitGroups(_ nalUnits: [H264NALUnit]) -> [[H264NALUnit]] {
        var groups: [[H264NALUnit]] = []
        var current: [H264NALUnit] = []

        for nalUnit in nalUnits {
            if nalUnit.type == 9, current.contains(where: isSliceNAL) {
                groups.append(current)
                current = [nalUnit]
            } else {
                current.append(nalUnit)
            }
        }

        if current.isEmpty == false {
            groups.append(current)
        }

        return groups
    }

    private static func appendNALUnit(
        from data: Data,
        start: Int,
        end: Int,
        into nalUnits: inout [H264NALUnit]
    ) {
        var trimmedEnd = end
        while trimmedEnd > start, data[trimmedEnd - 1] == 0 {
            trimmedEnd -= 1
        }
        guard trimmedEnd > start else { return }

        let nalData = Data(data[start..<trimmedEnd])
        guard let header = nalData.first else { return }

        nalUnits.append(H264NALUnit(
            type: header & 0x1f,
            data: nalData
        ))
    }

    static func findStartCode(
        in data: Data,
        from start: Int
    ) -> (start: Int, end: Int)? {
        guard data.count >= 3, start <= data.count - 3 else { return nil }

        var index = start
        while index <= data.count - 3 {
            if data[index] == 0, data[index + 1] == 0 {
                if data[index + 2] == 1 {
                    return (index, index + 3)
                }
                if index <= data.count - 4, data[index + 2] == 0, data[index + 3] == 1 {
                    return (index, index + 4)
                }
            }
            index += 1
        }

        return nil
    }

    static func avccSampleData(from nalUnits: [H264NALUnit]) -> Data {
        var sample = Data()

        for nalUnit in nalUnits {
            var length = UInt32(nalUnit.data.count).bigEndian
            withUnsafeBytes(of: &length) { lengthBytes in
                sample.append(contentsOf: lengthBytes)
            }
            sample.append(nalUnit.data)
        }

        return sample
    }

    static func isSliceNAL(_ nalUnit: H264NALUnit) -> Bool {
        nalUnit.type == 1 || nalUnit.type == 5
    }

    private static func inferredFrameDuration(from units: [PendingAccessUnit]) -> Int64 {
        let durations = zip(units, units.dropFirst())
            .map { $1.dtsTicks - $0.dtsTicks }
            .filter { $0 > 0 }
            .sorted()

        guard durations.isEmpty == false else {
            return 3_000
        }

        return durations[durations.count / 2]
    }

    private static func inferredPacketDuration(
        at index: Int,
        in packets: [H264PESPacket],
        groupCount: Int
    ) -> Int64 {
        guard groupCount > 0 else { return 3_000 }
        guard packets.indices.contains(index + 1) else { return 3_000 }

        let packetDuration = packets[index + 1].dtsTicks - packets[index].dtsTicks
        guard packetDuration > 0 else { return 3_000 }

        return max(1, packetDuration / Int64(groupCount))
    }

    private struct PendingAccessUnit {
        var sampleData: Data
        var ptsTicks: Int64
        var dtsTicks: Int64
        var isKeyFrame: Bool
        var nalTypes: [UInt8]
    }
}

nonisolated struct StreamingH264AccessUnitAssembler {
    private static let logger = Logger(subsystem: "com.danneu.dancam", category: "h264-au")

    private let frameDurationWindow: Int

    private var sps: Data?
    private var pps: Data?
    private var didBecomeReady = false
    private var held: PendingAccessUnit?
    private var deferredPacket: DeferredPacket?
    private var recentDurations: [Int64] = []
    private var didLogMultiAccessUnitPES = false

    init(
        timescale: Int32 = 90_000,
        frameDurationWindow: Int = 32
    ) {
        _ = timescale
        self.frameDurationWindow = max(1, frameDurationWindow)
    }

    struct Output: Sendable {
        var accessUnits: [H264AccessUnit]
        var sps: Data?
        var pps: Data?
        var didBecomeReady: Bool
    }

    mutating func append(_ packets: [H264PESPacket]) throws -> Output {
        var output = makeOutput()

        for packet in packets {
            try flushDeferredPacket(nextDTS: packet.dtsTicks, into: &output)
            try append(packet, into: &output)
        }

        return output
    }

    mutating func finish() throws -> Output {
        var output = makeOutput()
        try flushDeferredPacket(nextDTS: nil, into: &output)

        if let held {
            output.accessUnits.append(held.accessUnit(durationTicks: inferredFrameDuration()))
            self.held = nil
        }

        return output
    }

    private mutating func append(
        _ packet: H264PESPacket,
        into output: inout Output
    ) throws {
        let nalUnits = H264AccessUnitAssembler.splitAnnexB(packet.payload)
        latchParameterSets(from: nalUnits, into: &output)

        guard sps != nil, pps != nil else { return }

        let pendingUnits = makePendingUnits(from: nalUnits, packet: packet)
        guard pendingUnits.isEmpty == false else { return }

        if pendingUnits.count == 1 {
            try push(pendingUnits[0], into: &output)
        } else {
            logMultiAccessUnitPESIfNeeded(count: pendingUnits.count)
            deferredPacket = DeferredPacket(
                dtsTicks: packet.dtsTicks,
                units: pendingUnits
            )
        }
    }

    private func makeOutput() -> Output {
        Output(
            accessUnits: [],
            sps: nil,
            pps: nil,
            didBecomeReady: false
        )
    }

    private mutating func latchParameterSets(
        from nalUnits: [H264NALUnit],
        into output: inout Output
    ) {
        for nalUnit in nalUnits {
            switch nalUnit.type {
            case 7 where sps == nil:
                sps = nalUnit.data
                output.sps = nalUnit.data
            case 8 where pps == nil:
                pps = nalUnit.data
                output.pps = nalUnit.data
            default:
                break
            }
        }

        guard didBecomeReady == false, sps != nil, pps != nil else { return }

        didBecomeReady = true
        output.didBecomeReady = true
    }

    private func makePendingUnits(
        from nalUnits: [H264NALUnit],
        packet: H264PESPacket
    ) -> [PendingAccessUnit] {
        H264AccessUnitAssembler.splitAccessUnitGroups(nalUnits).compactMap { group in
            let sampleNALs = group.filter { nalUnit in
                switch nalUnit.type {
                case 7, 8, 9:
                    return false
                default:
                    return true
                }
            }
            guard sampleNALs.contains(where: H264AccessUnitAssembler.isSliceNAL) else {
                return nil
            }

            return PendingAccessUnit(
                sampleData: H264AccessUnitAssembler.avccSampleData(from: sampleNALs),
                ptsTicks: packet.ptsTicks,
                dtsTicks: packet.dtsTicks,
                isKeyFrame: sampleNALs.contains { $0.type == 5 },
                nalTypes: group.map(\.type)
            )
        }
    }

    private mutating func flushDeferredPacket(
        nextDTS: Int64?,
        into output: inout Output
    ) throws {
        guard let deferredPacket else { return }
        self.deferredPacket = nil

        let unitDuration: Int64
        if let nextDTS {
            let packetDuration = nextDTS - deferredPacket.dtsTicks
            guard packetDuration > 0 else {
                throw ClipRemuxError.invalidH264("DTS not strictly increasing")
            }
            unitDuration = max(1, packetDuration / Int64(deferredPacket.units.count))
        } else {
            unitDuration = inferredFrameDuration()
        }

        for index in deferredPacket.units.indices {
            var pending = deferredPacket.units[index]
            let offset = Int64(index) * unitDuration
            pending.ptsTicks += offset
            pending.dtsTicks += offset
            try push(pending, into: &output)
        }
    }

    private mutating func push(
        _ pending: PendingAccessUnit,
        into output: inout Output
    ) throws {
        if let held {
            let duration = pending.dtsTicks - held.dtsTicks
            guard duration > 0 else {
                throw ClipRemuxError.invalidH264("DTS not strictly increasing")
            }
            recordDuration(duration)
            output.accessUnits.append(held.accessUnit(durationTicks: duration))
        }

        held = pending
    }

    private mutating func recordDuration(_ duration: Int64) {
        recentDurations.append(duration)

        let overflow = recentDurations.count - frameDurationWindow
        if overflow > 0 {
            recentDurations.removeFirst(overflow)
        }
    }

    private func inferredFrameDuration() -> Int64 {
        let durations = recentDurations
            .filter { $0 > 0 }
            .sorted()

        guard durations.isEmpty == false else {
            return 3_000
        }

        return durations[durations.count / 2]
    }

    private mutating func logMultiAccessUnitPESIfNeeded(count: Int) {
        guard didLogMultiAccessUnitPES == false else { return }

        didLogMultiAccessUnitPES = true
        Self.logger.notice("Deferred \(count) H.264 access units from one PES until the next DTS.")
    }

    private struct PendingAccessUnit {
        var sampleData: Data
        var ptsTicks: Int64
        var dtsTicks: Int64
        var isKeyFrame: Bool
        var nalTypes: [UInt8]

        func accessUnit(durationTicks: Int64) -> H264AccessUnit {
            H264AccessUnit(
                sampleData: sampleData,
                ptsTicks: ptsTicks,
                dtsTicks: dtsTicks,
                durationTicks: durationTicks,
                isKeyFrame: isKeyFrame,
                nalTypes: nalTypes
            )
        }
    }

    private struct DeferredPacket {
        var dtsTicks: Int64
        var units: [PendingAccessUnit]
    }
}
