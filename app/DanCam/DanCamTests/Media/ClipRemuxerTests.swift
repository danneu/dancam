import AVFoundation
import Foundation
import Testing
@testable import DanCam

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
        assertSyncSamples(on: track)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: CMTime(seconds: 15, preferredTimescale: 600)).image
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

    private func assertSyncSamples(on track: AVAssetTrack) {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else {
            Issue.record("Expected the remuxed MP4 to vend sample cursors.")
            return
        }

        var sampleCount = 0
        var fullSyncCount = 0
        var dependentCount = 0

        while sampleCount < 5_000 {
            sampleCount += 1

            let syncInfo = cursor.currentSampleSyncInfo
            if sampleCount == 1 {
                #expect(syncInfo.sampleIsFullSync.boolValue)
            }
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

        #expect(sampleCount > 800)
        #expect(fullSyncCount > 1)
        #expect(dependentCount > 0)
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
