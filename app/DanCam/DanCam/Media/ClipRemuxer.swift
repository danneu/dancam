import Foundation

nonisolated struct ClipRemuxResult: Equatable, Sendable {
    var fileURL: URL
    var duration: Duration
    var bytes: UInt64
}

nonisolated struct ClipRemuxer: Sendable {
    var remux: @Sendable (_ sourceURL: URL, _ clipID: Int) async throws -> ClipRemuxResult

    static let live = ClipRemuxer { sourceURL, clipID in
        let outputURL = try prepareOutputURL(clipID: clipID)
        do {
            return try await ClipRemuxerEngine.remux(
                sourceURL: sourceURL,
                outputURL: outputURL
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static let noop = ClipRemuxer { sourceURL, _ in
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let bytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        return ClipRemuxResult(fileURL: sourceURL, duration: .zero, bytes: bytes)
    }

    private static func prepareOutputURL(clipID: Int) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        let prefix = "clip-\(clipID)-"

        for url in (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "mp4" {
            try? fileManager.removeItem(at: url)
        }

        return directory.appending(path: "\(prefix)\(UUID().uuidString).mp4")
    }
}
