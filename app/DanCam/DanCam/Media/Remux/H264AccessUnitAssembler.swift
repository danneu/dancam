import Foundation
import OSLog

nonisolated enum H264AccessUnitAssembler {
    private static let logger = Log.h264

    /// Strictly-increasing DTS is the per-clip assembler contract (see the Pi recording
    /// design's timestamp invariant). Returns the positive tick gap, or nil when `next` does
    /// not strictly advance `previous` (duplicate DTS, backward corruption, or a 33-bit
    /// wrap) -- callers drop the offending access unit.
    static func strictlyIncreasingGap(after previous: Int64, to next: Int64) -> Int64? {
        let gap = next - previous
        return gap > 0 ? gap : nil
    }

    static func assemble(
        packets: [H264PESPacket],
        timescale: Int32,
        clipID: Int? = nil
    ) throws -> DemuxedH264Clip {
        var sps: Data?
        var pps: Data?
        var pendingUnits: [PendingAccessUnit] = []

        for index in packets.indices {
            let packet = packets[index]
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
                in: packets,
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
        guard let firstKeyFrameIndex = pendingUnits.firstIndex(where: \.isKeyFrame) else {
            throw ClipRemuxError.invalidH264("No H.264 keyframe found.")
        }
        if firstKeyFrameIndex > 0 {
            logger.notice(
                "Dropped \(firstKeyFrameIndex) leading access unit(s) before the first keyframe (head-truncated clip)."
            )
        }
        let decodableUnits = Array(pendingUnits[firstKeyFrameIndex...])

        let frameDuration = inferredFrameDuration(from: decodableUnits)
        var accessUnits: [H264AccessUnit] = []
        accessUnits.reserveCapacity(decodableUnits.count)
        var held: PendingAccessUnit?
        var didLogDiscontinuity = false

        for pending in decodableUnits {
            if let heldUnit = held {
                guard let duration = strictlyIncreasingGap(
                    after: heldUnit.dtsTicks,
                    to: pending.dtsTicks
                ) else {
                    if didLogDiscontinuity == false {
                        didLogDiscontinuity = true
                        if let clipID {
                            logger.notice(
                                "clip_id=\(clipID, privacy: .public) Dropped an access unit whose DTS did not strictly increase."
                            )
                        } else {
                            logger.notice("Dropped an access unit whose DTS did not strictly increase.")
                        }
                    }
                    continue
                }
                accessUnits.append(heldUnit.accessUnit(durationTicks: duration))
            }
            held = pending
        }

        if let held {
            accessUnits.append(held.accessUnit(durationTicks: frameDuration))
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
}
