import AVFoundation
import Foundation
import Testing
@testable import DanCam

@Suite(.serialized)
struct ClipRemuxerTests {
    @Test(.timeLimit(.minutes(1)))
    func liveRemuxesTransportStreamFixtureToPlayableMP4() async throws {
        let sourceURL = try MediaFixtureURLs.seg00000TS()
        let result = try await ClipRemuxer.live.remux(sourceURL, 91_000)
        defer {
            try? FileManager.default.removeItem(at: result.fileURL)
        }

        #expect(result.fileURL.pathExtension == "mp4")
        #expect(result.bytes > 0)
        #expect(abs(durationSeconds(result.duration) - 30.0) < 0.5)

        let asset = AVURLAsset(url: result.fileURL)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 30.0) < 0.5)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(videoTracks.first)
        #expect(videoTracks.count == 1)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
        let timeRange = try await track.load(.timeRange)
        #expect(timeRange.start.isNumeric)
        #expect(abs(timeRange.start.seconds) < 0.01)
        assertSyncSamples(on: track)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: .zero).image
        _ = try await generator.image(at: CMTime(seconds: 15, preferredTimescale: 600)).image

        try assertFastStartLayout(result.fileURL)
    }

    @Test(.timeLimit(.minutes(1)))
    func liveRemuxesTruncatedTransportStreamToPlayableMP4() async throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let cut = data.count - 17_000
        try #require(cut % TransportStreamH264Parser.packetSize != 0)

        let clipID = 91_002
        let sourceURL = temporaryURL(extension: "ts")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            for url in remuxOutputs(clipID: clipID) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data(data.prefix(cut)).write(to: sourceURL)

        let result = try await ClipRemuxer.live.remux(sourceURL, clipID)

        #expect(result.fileURL.pathExtension == "mp4")
        #expect(result.bytes > 0)
        #expect(durationSeconds(result.duration) > 25.0)
        #expect(durationSeconds(result.duration) < 30.5)
        try assertFastStartLayout(result.fileURL)

        let asset = AVURLAsset(url: result.fileURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(videoTracks.first)
        #expect(videoTracks.count == 1)
        assertSyncSamples(on: track)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: .zero).image
        _ = try await generator.image(at: CMTime(seconds: 10, preferredTimescale: 600)).image
    }

    @Test(.timeLimit(.minutes(1)))
    func liveRemuxesTransportStreamWithMidStreamGarbageToPlayableMP4() async throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let insertionOffset = TransportStreamH264Parser.packetSize * 31
        try #require(data.count > insertionOffset + (TransportStreamH264Parser.packetSize * 3))

        var corrupted = Data(data[..<insertionOffset])
        corrupted.append(contentsOf: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        corrupted.append(contentsOf: data[insertionOffset...])

        let clipID = 91_003
        let sourceURL = temporaryURL(extension: "ts")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            for url in remuxOutputs(clipID: clipID) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try corrupted.write(to: sourceURL)

        let result = try await ClipRemuxer.live.remux(sourceURL, clipID)

        #expect(result.fileURL.pathExtension == "mp4")
        #expect(result.bytes > 0)
        try assertFastStartLayout(result.fileURL)

        let asset = AVURLAsset(url: result.fileURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(videoTracks.first)
        #expect(videoTracks.count == 1)
        assertSyncSamples(on: track)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: .zero).image
    }

    @Test(.timeLimit(.minutes(1)))
    func liveRemuxesTransportStreamWithSyncAlignedBitFlipToPlayableMP4() async throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let offset = TSFixtureLayout.pes1ContinuationOffset
        try #require(data[offset] == 0x47)
        try #require((data[offset + 3] & 0x30) >> 4 == 1)

        // A single alignment-preserving bit flip in a TS header: clear the
        // adaptation-control bits so the packet reads as reserved (AFC=0). The
        // demuxer must skip that packet, drop just its PES, and still remux.
        var corrupted = data
        corrupted[offset + 3] &= ~UInt8(0x30)

        let clipID = 91_004
        let sourceURL = temporaryURL(extension: "ts")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            for url in remuxOutputs(clipID: clipID) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try corrupted.write(to: sourceURL)

        let result = try await ClipRemuxer.live.remux(sourceURL, clipID)

        #expect(result.fileURL.pathExtension == "mp4")
        #expect(result.bytes > 0)
        try assertFastStartLayout(result.fileURL)

        let asset = AVURLAsset(url: result.fileURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(videoTracks.first)
        #expect(videoTracks.count == 1)
        assertSyncSamples(on: track)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: .zero).image
        _ = try await generator.image(at: CMTime(seconds: 10, preferredTimescale: 600)).image
    }

    @Test(.timeLimit(.minutes(1)))
    func remuxedMP4FromHeadTruncatedClipStartsAtSyncSample() async throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        let allPES = try TSDemuxer.demuxH264PESPackets(from: data)
        try #require(allPES.count > 253)

        let headNALs = H264AccessUnitAssembler.splitAnnexB(allPES[248].payload)
        let headGroups = H264AccessUnitAssembler.splitAccessUnitGroups(headNALs)
        let firstHeadSlice = try #require(
            headGroups.joined().first(where: H264AccessUnitAssembler.isSliceNAL)
        )
        try #require(firstHeadSlice.type == 1)

        let containsKeyFrame = allPES[249...253].contains { pes in
            H264AccessUnitAssembler.splitAnnexB(pes.payload).contains { $0.type == 5 }
        }
        try #require(containsKeyFrame)

        let clip = try H264AccessUnitAssembler.assemble(
            packets: Array(allPES[248...253]),
            timescale: TransportStreamH264Parser.clockTimescale
        )
        let outputURL = temporaryURL(extension: "mp4")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        _ = try await ClipRemuxerEngine.write(clip: clip, to: outputURL)

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(videoTracks.first)
        assertFirstSampleIsSyncSample(on: track)
    }

    @Test(.timeLimit(.minutes(1)))
    func liveRemuxFailureRemovesStaleAndPartialOutputs() async throws {
        let clipID = 91_001
        let invalidSourceURL = temporaryURL(extension: "ts")
        let staleURL = FileManager.default.temporaryDirectory
            .appending(path: "clip-\(clipID)-stale.mp4")
        FileManager.default.createFile(
            atPath: invalidSourceURL.path,
            contents: Data([0x47, 0x00]),
            attributes: nil
        )
        FileManager.default.createFile(
            atPath: staleURL.path,
            contents: Data([0x01]),
            attributes: nil
        )
        defer {
            try? FileManager.default.removeItem(at: invalidSourceURL)
            try? FileManager.default.removeItem(at: staleURL)
            for url in remuxOutputs(clipID: clipID) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            _ = try await ClipRemuxer.live.remux(invalidSourceURL, clipID)
            Issue.record("Expected invalid TS remux to throw.")
        } catch ClipRemuxError.invalidTransportStream {
        } catch {
            Issue.record("Expected ClipRemuxError.invalidTransportStream, got \(error).")
        }

        #expect(remuxOutputs(clipID: clipID).isEmpty)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }

    @discardableResult
    private func assertFirstSampleIsSyncSample(
        on track: AVAssetTrack,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else {
            Issue.record(
                "Expected the remuxed MP4 to vend sample cursors.",
                sourceLocation: sourceLocation
            )
            return false
        }

        let syncInfo = cursor.currentSampleSyncInfo
        #expect(syncInfo.sampleIsFullSync.boolValue, sourceLocation: sourceLocation)
        return true
    }

    private func assertSyncSamples(
        on track: AVAssetTrack,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard assertFirstSampleIsSyncSample(on: track, sourceLocation: sourceLocation),
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else {
            return
        }

        var sampleCount = 0
        var fullSyncCount = 0
        var dependentCount = 0

        while sampleCount < 5_000 {
            sampleCount += 1

            let syncInfo = cursor.currentSampleSyncInfo
            if syncInfo.sampleIsFullSync.boolValue {
                fullSyncCount += 1
            }

            let dependencyInfo = cursor.currentSampleDependencyInfo
            if dependencyInfo.sampleIndicatesWhetherItDependsOnOthers.boolValue,
               dependencyInfo.sampleDependsOnOthers.boolValue {
                dependentCount += 1
            }

            if cursor.stepInDecodeOrder(byCount: 1) == 0 {
                break
            }
        }

        #expect(sampleCount > 800, sourceLocation: sourceLocation)
        #expect(fullSyncCount > 1, sourceLocation: sourceLocation)
        #expect(dependentCount > 0, sourceLocation: sourceLocation)
    }

    private func assertFastStartLayout(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let moovOffset = try #require(topLevelBoxOffset(named: "moov", in: data))
        let mdatOffset = try #require(topLevelBoxOffset(named: "mdat", in: data))
        #expect(moovOffset < mdatOffset)
    }

    private func topLevelBoxOffset(named expectedName: String, in data: Data) -> Int? {
        var offset = 0

        while offset + 8 <= data.count {
            let boxStart = offset
            let size32 = uint32(in: data, at: offset)
            let typeStart = offset + 4
            let typeEnd = offset + 8
            guard let name = String(bytes: data[typeStart..<typeEnd], encoding: .ascii) else {
                return nil
            }

            var headerSize = 8
            let boxSize: UInt64
            if size32 == 1 {
                guard offset + 16 <= data.count else { return nil }
                boxSize = uint64(in: data, at: offset + 8)
                headerSize = 16
            } else if size32 == 0 {
                boxSize = UInt64(data.count - offset)
            } else {
                boxSize = UInt64(size32)
            }

            if name == expectedName {
                return boxStart
            }

            guard boxSize >= UInt64(headerSize),
                  UInt64(offset) + boxSize <= UInt64(data.count) else {
                return nil
            }
            offset += Int(boxSize)
        }

        return nil
    }

    private func uint32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    private func uint64(in data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).\(pathExtension)")
    }

    private func remuxOutputs(clipID: Int) -> [URL] {
        let prefix = "clip-\(clipID)-"
        return ((try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "mp4" }
    }
}
