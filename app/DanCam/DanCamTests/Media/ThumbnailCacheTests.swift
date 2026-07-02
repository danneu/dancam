import Foundation
import Testing
@testable import DanCam

struct ThumbnailCacheTests {
    @Test
    func insertThenLookupStoresJPEGDirectlyUnderRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        let cached = try cache.insert(7, "0-12345", Data([0x01, 0x02, 0x03]))
        let hit = cache.lookup(7, "0-12345")

        #expect(cached.deletingLastPathComponent() == root)
        #expect(cached.lastPathComponent.hasPrefix("thumb-7-"))
        #expect(cached.pathExtension == "jpg")
        #expect(try Data(contentsOf: cached) == Data([0x01, 0x02, 0x03]))
        #expect(hit == cached)
    }

    @Test
    func quotedAndUnquotedSpellingsOfOneValidatorHit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        let cached = try cache.insert(1, "\"0-12345\"", Data([0x01]))

        #expect(cache.lookup(1, "0-12345") == cached)
    }

    @Test
    func differentValidatorMisses() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        _ = try cache.insert(1, "\"0-99999\"", Data([0x01]))

        #expect(cache.lookup(1, "0-12345") == nil)
    }

    @Test
    func newVersionOfOneClipReplacesTheOldThumbnail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        let old = try cache.insert(5, "1-100", Data([0x01]))
        let new = try cache.insert(5, "2-200", Data([0x02]))

        // A clip has exactly one live thumbnail: inserting a new etag sweeps the old.
        #expect(FileManager.default.fileExists(atPath: old.path) == false)
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(cache.lookup(5, "1-100") == nil)
        #expect(cache.lookup(5, "2-200") == new)
    }

    @Test
    func evictionDeletesOldestButPreservesJustInsertedAndOversizedThumbnail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache1 = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) }, maxBytes: 10)
        let first = try cache1.insert(1, "a", Data(repeating: 0x01, count: 6))
        let cache2 = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 2) }, maxBytes: 10)
        let second = try cache2.insert(2, "b", Data(repeating: 0x02, count: 6))

        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path))

        let oversizedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        let oversizedCache = ThumbnailCache.live(
            rootDirectory: oversizedRoot,
            now: { Date(timeIntervalSince1970: 1) },
            maxBytes: 5
        )
        let oversized = try oversizedCache.insert(3, "large", Data(repeating: 0x03, count: 12))

        #expect(FileManager.default.fileExists(atPath: oversized.path))
    }

    @Test
    func lookupTouchesModificationDateAndProtectsReplayedThumbnail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache1 = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) }, maxBytes: 10)
        let first = try cache1.insert(1, "a", Data(repeating: 0x01, count: 5))
        let cache2 = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 2) }, maxBytes: 10)
        let second = try cache2.insert(2, "b", Data(repeating: 0x02, count: 5))

        let cache3 = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 3) }, maxBytes: 10)
        #expect(cache3.lookup(1, "a") == first)

        let cache4 = ThumbnailCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 4) }, maxBytes: 10)
        let third = try cache4.insert(3, "c", Data(repeating: 0x03, count: 5))

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path) == false)
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    @Test
    func versionSentinelWipesStaleThumbnailsOnBump() throws {
        let staleRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        try FileManager.default.createDirectory(at: staleRoot, withIntermediateDirectories: true)
        try Data().write(to: staleRoot.appending(path: ".v0"))
        let stale = staleRoot.appending(path: "thumb-1-stale.jpg")
        try Data([0x01]).write(to: stale)

        let wipingCache = ThumbnailCache.live(rootDirectory: staleRoot, now: { Date(timeIntervalSince1970: 1) })
        #expect(wipingCache.lookup(1, "stale") == nil)
        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
        #expect(FileManager.default.fileExists(atPath: staleRoot.appending(path: ".v1").path))
    }

    @Test
    func usesItsOwnRootAndLeavesTheClipCacheUntouched() throws {
        let clipRoot = try temporaryDirectory()
        let thumbRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: clipRoot)
            try? FileManager.default.removeItem(at: thumbRoot)
        }

        let clipCache = ClipCache.live(rootDirectory: clipRoot, now: { Date(timeIntervalSince1970: 1) })
        let clipSource = FileManager.default.temporaryDirectory
            .appending(path: "dancam-thumb-cache-clip-\(UUID().uuidString).mp4")
        try Data([0xAA]).write(to: clipSource)
        let cachedClip = try clipCache.insert(9, "9-9", clipSource)

        let thumbnailCache = ThumbnailCache.live(rootDirectory: thumbRoot, now: { Date(timeIntervalSince1970: 2) })
        let cachedThumb = try thumbnailCache.insert(9, "9-9", Data([0xBB]))

        #expect(cachedThumb.deletingLastPathComponent() == thumbRoot)
        #expect(FileManager.default.fileExists(atPath: cachedClip.path))
        #expect(clipCache.lookup(9, "9-9") == cachedClip)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dancam-thumbnail-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
