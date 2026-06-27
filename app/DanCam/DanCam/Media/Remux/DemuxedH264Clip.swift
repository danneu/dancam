import Foundation

nonisolated struct H264PESPacket: Equatable, Sendable {
    var payload: Data
    var ptsTicks: Int64
    var dtsTicks: Int64
}

nonisolated struct H264NALUnit: Equatable, Sendable {
    var type: UInt8
    var data: Data
}

nonisolated struct H264AccessUnit: Equatable, Sendable {
    var sampleData: Data
    var ptsTicks: Int64
    var dtsTicks: Int64
    var durationTicks: Int64
    var isKeyFrame: Bool
    var nalTypes: [UInt8]
}

nonisolated struct DemuxedH264Clip: Equatable, Sendable {
    var accessUnits: [H264AccessUnit]
    var sps: Data
    var pps: Data
    var timescale: Int32

    var firstDecodeTicks: Int64 {
        accessUnits.first?.dtsTicks ?? 0
    }

    var durationTicks: Int64 {
        guard let firstPTS = accessUnits.map(\.ptsTicks).min() else { return 0 }
        let lastEnd = accessUnits
            .map { $0.ptsTicks + $0.durationTicks }
            .max() ?? firstPTS
        return max(0, lastEnd - firstPTS)
    }
}

nonisolated enum ClipRemuxError: Error, Equatable, Sendable {
    case invalidTransportStream(String)
    case invalidH264(String)
    case writer(String)
    case file(String)
}
