import Foundation
import Testing

enum MediaFixtureURLs {
    static func seg00000TS() throws -> URL {
        let bundle = Bundle(for: MediaFixtureBundleToken.self)

        if let nestedURL = bundle.url(
            forResource: "seg_00000",
            withExtension: "ts",
            subdirectory: "Media/Fixtures"
        ) {
            return nestedURL
        }

        if let bundledURL = bundle.url(forResource: "seg_00000", withExtension: "ts") {
            return bundledURL
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
            .appending(path: "seg_00000.ts")
        return try #require(FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil)
    }
}

private final class MediaFixtureBundleToken {}

/// Byte offsets, counts, and timestamps verified against the bundled
/// `seg_00000.ts` fixture (5387 x 188-byte packets, sync-aligned). The
/// TS-demuxer corruption-tolerance tests flip specific header fields in a copy
/// of the fixture, so they depend on these staying in sync with the file.
enum TSFixtureLayout {
    static let packetCount = 5387
    static let videoPESCount = 900

    /// TS-packet byte offsets. PES#0 carries SPS/PPS/IDR; SPS/PPS recur only at
    /// PES 0/250/500/750, so a wide pre-latch gap can starve the streaming path.
    static let pes0PacketOffset = 564
    static let pes1PacketOffset = 5452
    static let pes1ContinuationOffset = 5640
    static let pes2PacketOffset = 6016

    /// 5-byte PTS/DTS field offsets inside the PES headers above.
    static let pes0DTSField = 590
    static let pes1PTSField = 5465
    static let pes1DTSField = 5470
    static let pes2DTSField = 6152
    /// PES#1 PES-header flags byte (PTS_DTS_flags live in the top two bits).
    static let pes1FlagsByte = 5463

    /// section_length high byte of the initial (latching) PMT @376 and the next
    /// PMT @6392 that re-latches after it.
    static let initialPMTSectionLengthHi = 382
    static let laterPMTSectionLengthHi = 6398

    static let pes0DTS: Int64 = 126_000
    static let pes1DTS: Int64 = 129_000
    static let pes250DTS: Int64 = 876_000
}
