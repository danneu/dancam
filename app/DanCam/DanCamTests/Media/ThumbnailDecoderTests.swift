import AVFoundation
import Foundation
import Testing
import UIKit
@testable import DanCam

struct ThumbnailDecoderTests {
    private let maxPixelSize = CGSize(width: 160, height: 90)

    @Test(.timeLimit(.minutes(1)))
    func decodesFirstFrameFromTruncatedTSPrefixDownscaled() async throws {
        let data = try Data(contentsOf: MediaFixtureURLs.seg00000TS())
        // A truncated one-GOP-plus prefix: the fail-soft remuxer still yields the first IDR.
        let prefix = Data(data.prefix(data.count / 2))

        let image = try await ThumbnailDecoder.firstFrameImage(
            fromTSPrefix: prefix,
            clipID: 91_100,
            maxPixelSize: maxPixelSize
        )

        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        #expect(image.size.width <= maxPixelSize.width)
        #expect(image.size.height <= maxPixelSize.height)
    }

    @Test(.timeLimit(.minutes(1)))
    func decodesFirstFrameFromCachedMP4Downscaled() async throws {
        let sourceURL = try MediaFixtureURLs.seg00000TS()
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "dancam-thumb-decoder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        _ = try await ClipRemuxerEngine.remux(sourceURL: sourceURL, outputURL: outputURL, clipID: 91_101)

        let image = try await ThumbnailDecoder.firstFrameImage(
            fromMP4: outputURL,
            maxPixelSize: maxPixelSize
        )

        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        #expect(image.size.width <= maxPixelSize.width)
        #expect(image.size.height <= maxPixelSize.height)
    }
}
