import Foundation

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
            let nalUnits = try splitAnnexB(packet.payload)
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

    static func splitAnnexB(_ data: Data) throws -> [H264NALUnit] {
        var nalUnits: [H264NALUnit] = []

        guard var startCode = findStartCode(in: data, from: 0) else {
            throw ClipRemuxError.invalidH264("Missing Annex B start code.")
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

    private static func splitAccessUnitGroups(_ nalUnits: [H264NALUnit]) -> [[H264NALUnit]] {
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

    private static func findStartCode(
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

    private static func avccSampleData(from nalUnits: [H264NALUnit]) -> Data {
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

    private static func isSliceNAL(_ nalUnit: H264NALUnit) -> Bool {
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
