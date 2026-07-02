import Foundation

/// On-disk cache of generated clip thumbnails, keyed `thumb-<id>-<token>.jpg` under its
/// own root. It mirrors `ClipCache`'s version-sentinel + mtime-LRU shape but must not
/// share `ClipCache`'s root: `ClipCache` wipes its whole root on a version bump and its
/// eviction/sweep hardcode the `clip-`/`.mp4` namespace. Thumbnails are tiny, so a small
/// budget holds hundreds of clips.
///
/// Unlike `ClipCache` (which moves an already-on-disk pulled file), a thumbnail is
/// generated in memory, so `insert` takes the encoded JPEG bytes directly.
nonisolated struct ThumbnailCache: Sendable {
    var lookup: @Sendable (_ clipID: Int, _ etag: String) -> URL?
    var insert: @Sendable (_ clipID: Int, _ etag: String, _ data: Data) throws -> URL

    static func live(
        rootDirectory: URL,
        now: @escaping @Sendable () -> Date,
        maxBytes: Int = 64 * 1024 * 1024
    ) -> ThumbnailCache {
        ThumbnailCache(
            lookup: { clipID, etag in
                do {
                    let fileManager = FileManager.default
                    try ensureCurrentVersion(rootDirectory: rootDirectory, fileManager: fileManager)
                    let url = cacheURL(rootDirectory: rootDirectory, clipID: clipID, etag: etag)
                    guard fileManager.fileExists(atPath: url.path) else { return nil }
                    try stamp(url, date: now(), fileManager: fileManager)
                    return url
                } catch {
                    return nil
                }
            },
            insert: { clipID, etag, data in
                let fileManager = FileManager.default
                try ensureCurrentVersion(rootDirectory: rootDirectory, fileManager: fileManager)
                let destination = cacheURL(rootDirectory: rootDirectory, clipID: clipID, etag: etag)

                try sweepClipVersions(
                    rootDirectory: rootDirectory,
                    clipID: clipID,
                    preserving: destination,
                    fileManager: fileManager
                )
                try data.write(to: destination, options: .atomic)

                try stamp(destination, date: now(), fileManager: fileManager)
                try evictIfNeeded(
                    rootDirectory: rootDirectory,
                    maxBytes: max(0, maxBytes),
                    preserving: destination,
                    fileManager: fileManager
                )
                return destination
            }
        )
    }

    static let noop = ThumbnailCache(
        lookup: { _, _ in nil },
        insert: { clipID, etag, _ in
            FileManager.default.temporaryDirectory
                .appending(path: "thumb-\(clipID)-\(CacheKey.etagToken(etag)).jpg")
        }
    )

    private static let version = 1

    private static func cacheURL(rootDirectory: URL, clipID: Int, etag: String) -> URL {
        rootDirectory.appending(path: "thumb-\(clipID)-\(CacheKey.etagToken(etag)).jpg")
    }

    private static func ensureCurrentVersion(
        rootDirectory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let sentinel = rootDirectory.appending(path: ".v\(version)")
        guard fileManager.fileExists(atPath: sentinel.path) == false else { return }

        for url in try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: url)
        }
        try Data().write(to: sentinel, options: .atomic)
    }

    private static func sweepClipVersions(
        rootDirectory: URL,
        clipID: Int,
        preserving destination: URL,
        fileManager: FileManager
    ) throws {
        let prefix = "thumb-\(clipID)-"
        for url in try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(prefix)
                && url.pathExtension == "jpg"
                && url != destination {
            try fileManager.removeItem(at: url)
        }
    }

    private static func evictIfNeeded(
        rootDirectory: URL,
        maxBytes: Int,
        preserving inserted: URL,
        fileManager: FileManager
    ) throws {
        var entries = try cacheEntries(rootDirectory: rootDirectory, fileManager: fileManager)
        var totalBytes = entries.reduce(UInt64(0)) { $0 + $1.bytes }
        let budget = UInt64(maxBytes)

        entries.sort {
            if $0.modified == $1.modified {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.modified < $1.modified
        }

        for entry in entries where totalBytes > budget && entry.url != inserted {
            try fileManager.removeItem(at: entry.url)
            totalBytes -= min(totalBytes, entry.bytes)
        }
    }

    private static func cacheEntries(
        rootDirectory: URL,
        fileManager: FileManager
    ) throws -> [CacheEntry] {
        try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("thumb-") && $0.pathExtension == "jpg" }
            .map { url in
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
                return CacheEntry(url: url, bytes: bytes, modified: modified)
            }
    }

    private static func stamp(
        _ url: URL,
        date: Date,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private struct CacheEntry {
        var url: URL
        var bytes: UInt64
        var modified: Date
    }
}
