import AVFoundation
import UIKit

/// Decodes a downscaled, display-ready first-frame `UIImage` from either a fetched TS
/// byte prefix (not-yet-watched clip) or a cached MP4 (already-watched clip). Both entry
/// points are `@concurrent` so the remux + `AVAssetImageGenerator` decode + downscale run
/// on the concurrent pool, off whatever actor (the `ThumbnailLoader` actor) awaits them --
/// the same off-main discipline `ClipRemuxerEngine.remux` already keeps for the remux.
nonisolated enum ThumbnailDecoder {
    /// Remux the fetched TS prefix to a temporary MP4, then grab its first frame. The
    /// remuxer is fail-soft on a truncated prefix by design, so a complete first IDR is
    /// all that is needed. Temp files are `thumb-<clipID>-<uuid>` so they never collide
    /// with `ClipRemuxer.live`'s `clip-<id>-` playback namespace, and are cleaned up on
    /// the way out.
    @concurrent
    static func firstFrameImage(
        fromTSPrefix data: Data,
        clipID: Int,
        maxPixelSize: CGSize
    ) async throws -> sending UIImage {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        let sourceURL = directory.appending(path: "thumb-\(clipID)-\(UUID().uuidString).ts")
        let outputURL = directory.appending(path: "thumb-\(clipID)-\(UUID().uuidString).mp4")
        defer {
            try? fileManager.removeItem(at: sourceURL)
            try? fileManager.removeItem(at: outputURL)
        }

        try data.write(to: sourceURL)
        _ = try await ClipRemuxerEngine.remux(
            sourceURL: sourceURL,
            outputURL: outputURL,
            clipID: clipID
        )
        return try await decodeFirstFrame(from: outputURL, maxPixelSize: maxPixelSize)
    }

    /// Free tier: the clip's cached MP4 already exists (it was watched), so decode its
    /// first frame directly -- no network, no remux.
    @concurrent
    static func firstFrameImage(
        fromMP4 url: URL,
        maxPixelSize: CGSize
    ) async throws -> sending UIImage {
        try await decodeFirstFrame(from: url, maxPixelSize: maxPixelSize)
    }

    private static func decodeFirstFrame(
        from url: URL,
        maxPixelSize: CGSize
    ) async throws -> sending UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxPixelSize
        // Default (infinite) tolerances: return the sync sample nearest `.zero`, i.e. the
        // first frame. A remuxed clip's first frame does not always sit at exactly PTS 0, so
        // a zero-tolerance request at `.zero` finds no frame and fails (AVFoundation -11832).

        let cgImage = try await generator.image(at: .zero).image
        let image = UIImage(cgImage: cgImage)
        // Force the decode + colorspace conversion now, off the caller's actor.
        let prepared = await image.byPreparingForDisplay()
        return prepared ?? image
    }
}
