import Foundation
import Testing
@testable import DanCam

struct ClipCacheTests {
    @Test
    func insertThenLookupStoresFileDirectlyUnderRoot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try temporaryFile(contents: Data([0x01, 0x02, 0x03]))
        defer { try? FileManager.default.removeItem(at: source) }

        let cache = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        let cached = try await cache.insert(7, "0-12345", source)
        let hit = await cache.lookup(7, "0-12345")

        #expect(cached.deletingLastPathComponent() == root)
        #expect(cached.lastPathComponent.hasPrefix("clip-7-"))
        #expect(cached.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(hit == cached)
    }

    @Test
    func quotedAndUnquotedSpellingsOfOneValidatorHit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try temporaryFile(contents: Data([0x01]))
        defer { try? FileManager.default.removeItem(at: source) }

        let cache = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        let cached = try await cache.insert(1, "\"0-12345\"", source)

        #expect(await cache.lookup(1, "0-12345") == cached)
    }

    @Test
    func differentValidatorMisses() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try temporaryFile(contents: Data([0x01]))
        defer { try? FileManager.default.removeItem(at: source) }

        let cache = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        _ = try await cache.insert(1, "\"0-99999\"", source)

        #expect(await cache.lookup(1, "0-12345") == nil)
    }

    @Test
    func insertConsumesSourceByMovingIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try temporaryFile(contents: Data([0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: source) }

        let cache = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
        let cached = try await cache.insert(1, "etag", source)

        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(try Data(contentsOf: cached) == Data([0x01, 0x02]))
    }

    @Test
    func evictionDeletesOldestButPreservesJustInsertedAndOversizedClip() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache1 = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) }, maxBytes: 10)
        let first = try await cache1.insert(1, "a", try temporaryFile(contents: Data(repeating: 0x01, count: 6)))
        let cache2 = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 2) }, maxBytes: 10)
        let second = try await cache2.insert(2, "b", try temporaryFile(contents: Data(repeating: 0x02, count: 6)))

        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path))

        let oversizedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        let oversizedCache = ClipCache.live(
            rootDirectory: oversizedRoot,
            now: { Date(timeIntervalSince1970: 1) },
            maxBytes: 5
        )
        let oversized = try await oversizedCache.insert(
            3,
            "large",
            try temporaryFile(contents: Data(repeating: 0x03, count: 12))
        )

        #expect(FileManager.default.fileExists(atPath: oversized.path))
    }

    @Test
    func lookupTouchesModificationDateAndProtectsReplayedClip() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache1 = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) }, maxBytes: 10)
        let first = try await cache1.insert(1, "a", try temporaryFile(contents: Data(repeating: 0x01, count: 5)))
        let cache2 = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 2) }, maxBytes: 10)
        let second = try await cache2.insert(2, "b", try temporaryFile(contents: Data(repeating: 0x02, count: 5)))

        let cache3 = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 3) }, maxBytes: 10)
        #expect(await cache3.lookup(1, "a") == first)

        let cache4 = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 4) }, maxBytes: 10)
        let third = try await cache4.insert(3, "c", try temporaryFile(contents: Data(repeating: 0x03, count: 5)))

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path) == false)
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    @Test
    func directoryIsIndexForStrayFilesMissingFilesAndVersionWipes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: ".v1"))

        let stray = root.appending(path: "clip-99-manual.mp4")
        try Data(repeating: 0x09, count: 6).write(to: stray)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: stray.path
        )

        let cache = ClipCache.live(rootDirectory: root, now: { Date(timeIntervalSince1970: 2) }, maxBytes: 10)
        let inserted = try await cache.insert(1, "fresh", try temporaryFile(contents: Data(repeating: 0x01, count: 6)))

        #expect(FileManager.default.fileExists(atPath: stray.path) == false)
        #expect(FileManager.default.fileExists(atPath: inserted.path))
        #expect(await cache.lookup(123, "missing") == nil)

        let staleRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        try FileManager.default.createDirectory(at: staleRoot, withIntermediateDirectories: true)
        try Data().write(to: staleRoot.appending(path: ".v0"))
        let stale = staleRoot.appending(path: "clip-1-stale.mp4")
        try Data([0x01]).write(to: stale)

        let wipingCache = ClipCache.live(rootDirectory: staleRoot, now: { Date(timeIntervalSince1970: 1) })
        #expect(await wipingCache.lookup(1, "stale") == nil)
        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
        #expect(FileManager.default.fileExists(atPath: staleRoot.appending(path: ".v1").path))
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func liveCacheRunsFileWorkOffMainThreadWhenCalledFromMainActor() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try temporaryFile(contents: Data([0x01]))
        defer { try? FileManager.default.removeItem(at: source) }
        let probe = MainThreadProbe()

        let cache = ClipCache.live(
            rootDirectory: root,
            now: {
                probe.record(Thread.isMainThread)
                return Date(timeIntervalSince1970: 1)
            }
        )

        _ = try await cache.insert(1, "main-thread-probe", source)

        let wasMainThread = try #require(probe.lastValue())
        #expect(wasMainThread == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func liveCacheSerializesConcurrentInserts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = OverlapProbe(delay: 0.01)
        let cache = ClipCache.live(rootDirectory: root, now: probe.now, maxBytes: 18)
        var sourceURLs: [URL] = []
        defer {
            for url in sourceURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let insertCount = 12
        try await withThrowingTaskGroup(of: URL.self) { group in
            for clipID in 0..<insertCount {
                let source = try temporaryFile(contents: Data(repeating: UInt8(clipID), count: 6))
                sourceURLs.append(source)
                group.addTask {
                    try await cache.insert(clipID, "\(clipID)", source)
                }
            }

            var cachedURLs: [URL] = []
            for try await cachedURL in group {
                cachedURLs.append(cachedURL)
            }
            #expect(cachedURLs.count == insertCount)
        }

        #expect(probe.peakValue() == 1)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".v1").path))

        let cachedFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clip-") && $0.pathExtension == "mp4" }
        var totalBytes = UInt64(0)
        for url in cachedFiles {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            totalBytes += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
        #expect(totalBytes <= 18)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dancam-clip-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dancam-clip-cache-source-\(UUID().uuidString).mp4")
        try contents.write(to: url)
        return url
    }
}

private final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func record(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func lastValue() -> Bool? {
        lock.lock()
        let value = storedValue
        lock.unlock()
        return value
    }
}

private final class OverlapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var active = 0
    private var peak = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func now() -> Date {
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()

        Thread.sleep(forTimeInterval: delay)

        lock.lock()
        active -= 1
        lock.unlock()
        return Date(timeIntervalSince1970: 1)
    }

    func peakValue() -> Int {
        lock.lock()
        let value = peak
        lock.unlock()
        return value
    }
}
