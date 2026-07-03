import Foundation

nonisolated struct ClipCache: Sendable {
    var lookup: @Sendable (_ clipID: Int, _ etag: String) async -> URL?
    var insert: @Sendable (_ clipID: Int, _ etag: String, _ source: URL) async throws -> URL
    var remove: @Sendable (_ clipID: Int) async -> Void

    init(
        lookup: @escaping @Sendable (_ clipID: Int, _ etag: String) async -> URL?,
        insert: @escaping @Sendable (_ clipID: Int, _ etag: String, _ source: URL) async throws -> URL,
        remove: @escaping @Sendable (_ clipID: Int) async -> Void = { _ in }
    ) {
        self.lookup = lookup
        self.insert = insert
        self.remove = remove
    }

    static func live(
        rootDirectory: URL,
        now: @escaping @Sendable () -> Date,
        maxBytes: Int = 500 * 1024 * 1024
    ) -> ClipCache {
        let store = Store(rootDirectory: rootDirectory, now: now, maxBytes: maxBytes)
        return ClipCache(
            lookup: { clipID, etag in
                await store.lookup(clipID, etag)
            },
            insert: { clipID, etag, source in
                try await store.insert(clipID, etag, source)
            },
            remove: { clipID in
                await store.remove(clipID)
            }
        )
    }

    static let noop = ClipCache(
        lookup: { _, _ in nil },
        insert: { _, _, source in source },
        remove: { _ in }
    )

    private static let version = 1

    private actor Store {
        private let rootDirectory: URL
        private let now: @Sendable () -> Date
        private let maxBytes: Int

        init(rootDirectory: URL, now: @escaping @Sendable () -> Date, maxBytes: Int) {
            self.rootDirectory = rootDirectory
            self.now = now
            self.maxBytes = maxBytes
        }

        func lookup(_ clipID: Int, _ etag: String) -> URL? {
            do {
                let fileManager = FileManager.default
                try ClipCache.ensureCurrentVersion(rootDirectory: rootDirectory, fileManager: fileManager)
                let url = ClipCache.cacheURL(rootDirectory: rootDirectory, clipID: clipID, etag: etag)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                try ClipCache.stamp(url, date: now(), fileManager: fileManager)
                return url
            } catch {
                return nil
            }
        }

        func insert(_ clipID: Int, _ etag: String, _ source: URL) throws -> URL {
            let fileManager = FileManager.default
            try ClipCache.ensureCurrentVersion(rootDirectory: rootDirectory, fileManager: fileManager)
            let destination = ClipCache.cacheURL(rootDirectory: rootDirectory, clipID: clipID, etag: etag)

            if source != destination {
                try ClipCache.sweepClipVersions(
                    rootDirectory: rootDirectory,
                    clipID: clipID,
                    preserving: source,
                    fileManager: fileManager
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: source, to: destination)
            }

            try ClipCache.stamp(destination, date: now(), fileManager: fileManager)
            try ClipCache.evictIfNeeded(
                rootDirectory: rootDirectory,
                maxBytes: max(0, maxBytes),
                preserving: destination,
                fileManager: fileManager
            )
            return destination
        }

        func remove(_ clipID: Int) {
            do {
                let fileManager = FileManager.default
                try ClipCache.ensureCurrentVersion(rootDirectory: rootDirectory, fileManager: fileManager)
                try ClipCache.sweepClipVersions(
                    rootDirectory: rootDirectory,
                    clipID: clipID,
                    preserving: nil,
                    fileManager: fileManager
                )
            } catch {}
        }
    }

    private static func cacheURL(rootDirectory: URL, clipID: Int, etag: String) -> URL {
        rootDirectory.appending(path: "clip-\(clipID)-\(CacheKey.etagToken(etag)).mp4")
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
        preserving source: URL?,
        fileManager: FileManager
    ) throws {
        let prefix = "clip-\(clipID)-"
        for url in try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(prefix)
                && url.pathExtension == "mp4"
                && url != source {
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
            .filter { $0.lastPathComponent.hasPrefix("clip-") && $0.pathExtension == "mp4" }
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
