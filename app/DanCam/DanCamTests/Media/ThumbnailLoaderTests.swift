import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct ThumbnailLoaderTests {
    private let twoMB = 2 * 1024 * 1024
    private let fourMB = 4 * 1024 * 1024

    // MARK: Tier routing

    @Test(.timeLimit(.minutes(1)))
    func diskCacheHitSkipsClipCacheAndPrefix() async throws {
        let jpeg = try makeJPEGFile()
        defer { try? FileManager.default.removeItem(at: jpeg) }
        let fetches = FetchLog()
        let clipCacheLookups = Counter()

        let loader = makeLoader(
            diskLookup: { _, _ in jpeg },
            clipCacheLookup: { _, _ in _ = clipCacheLookups.increment(); return nil },
            fetchPrefix: { id, etag, limit in fetches.begin(id, etag, limit); fetches.end(); return Data([0x01]) }
        )

        let image = await loader.thumbnail(clip(id: 1, etag: "1-1"))

        #expect(image != nil)
        #expect(fetches.count() == 0)
        #expect(clipCacheLookups.value() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func freeTierUsesCachedMP4AndSkipsPrefix() async throws {
        let mp4 = URL(filePath: "/tmp/dancam-free-tier-\(UUID().uuidString).mp4")
        let fetches = FetchLog()
        let decodeMP4Calls = Counter()
        let decodeTSCalls = Counter()

        let loader = makeLoader(
            clipCacheLookup: { _, _ in mp4 },
            fetchPrefix: { id, etag, limit in fetches.begin(id, etag, limit); fetches.end(); return Data([0x01]) },
            decodeTSPrefix: { _, _, _ in _ = decodeTSCalls.increment(); return UIImage() },
            decodeMP4: { _, _ in _ = decodeMP4Calls.increment(); return UIImage() }
        )

        let image = await loader.thumbnail(clip(id: 2, etag: "2-2"))

        #expect(image != nil)
        #expect(fetches.count() == 0)
        #expect(decodeMP4Calls.value() == 1)
        #expect(decodeTSCalls.value() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func missInvokesPrefixWithTheClipETag() async throws {
        let fetches = FetchLog()
        let loader = makeLoader(
            fetchPrefix: { id, etag, limit in fetches.begin(id, etag, limit); fetches.end(); return Data([0x01]) }
        )

        let image = await loader.thumbnail(clip(id: 3, etag: "3-30"))

        #expect(image != nil)
        #expect(fetches.count(3) == 1)
        #expect(fetches.etags(3) == ["3-30"])
    }

    @Test(.timeLimit(.minutes(1)))
    func prefixValidatorFailureYieldsNilAndCachesNothing() async throws {
        let inserts = Counter()
        let loader = makeLoader(
            thumbnailInsert: { id, etag, _ in _ = inserts.increment(); return URL(filePath: "/tmp/\(id)-\(etag).jpg") },
            fetchPrefix: { _, _, _ in throw ClipPrefixError.validatorMismatch }
        )

        let image = await loader.thumbnail(clip(id: 4, etag: "4-40"))

        #expect(image == nil)
        #expect(inserts.value() == 0)
    }

    // MARK: Single-flight

    @Test(.timeLimit(.minutes(1)))
    func concurrentRequestsForOneKeyShareASingleFetchThenHitMemory() async throws {
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = makeLoader(
            fetchPrefix: { id, etag, limit in
                fetches.begin(id, etag, limit)
                await release.wait()
                fetches.end()
                return Data([0x01])
            }
        )
        let target = clip(id: 5, etag: "5-50")

        let first = Task { await loader.thumbnail(target) }
        let second = Task { await loader.thumbnail(target) }
        try await waitUntil { fetches.count(5) == 1 && fetches.activeCount() == 1 }

        await release.signal()
        let firstImage = await first.value
        let secondImage = await second.value

        #expect(firstImage != nil)
        #expect(secondImage != nil)
        #expect(fetches.count(5) == 1)

        // A third request after completion is a memory hit -- no new fetch.
        let third = await loader.thumbnail(target)
        #expect(third != nil)
        #expect(fetches.count(5) == 1)
    }

    // MARK: Bounded concurrency

    @Test(.timeLimit(.minutes(1)))
    func distinctMissesNeverExceedMaxConcurrentAndAllComplete() async throws {
        let maxConcurrent = 2
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = makeLoader(
            maxConcurrent: maxConcurrent,
            fetchPrefix: { id, etag, limit in
                fetches.begin(id, etag, limit)
                await release.wait()
                fetches.end()
                return Data([0x01])
            }
        )
        let clips = (10..<15).map { clip(id: $0, etag: "\($0)-\($0)") }

        let tasks = clips.map { target in Task { await loader.thumbnail(target) } }
        try await waitUntil { fetches.activeCount() == maxConcurrent }
        // Steady state under saturation: never more than the cap in flight.
        try await settle()
        #expect(fetches.peakCount() == maxConcurrent)

        await release.signal()
        var images: [ThumbnailImage?] = []
        for task in tasks { images.append(await task.value) }

        #expect(images.allSatisfy { $0 != nil })
        #expect(fetches.peakCount() == maxConcurrent)
    }

    @Test(.timeLimit(.minutes(1)))
    func permitIsReleasedOnTheFailurePath() async throws {
        let fetches = FetchLog()
        let loader = makeLoader(
            maxConcurrent: 1,
            fetchPrefix: { id, etag, limit in fetches.begin(id, etag, limit); fetches.end(); return Data([0x01]) },
            decodeTSPrefix: { _, id, _ in
                if id == 20 { throw TestError.decodeFailed }
                return UIImage()
            }
        )

        let failed = await loader.thumbnail(clip(id: 20, etag: "20-20"))
        let succeeded = await loader.thumbnail(clip(id: 21, etag: "21-21"))

        #expect(failed == nil)  // both 2 MB and 4 MB decodes threw
        #expect(succeeded != nil)  // the single permit was released, not leaked
    }

    // MARK: Prefetch cancellation (handle-based)

    @Test(.timeLimit(.minutes(1)))
    func cancellingAQueuedPrefetchDropsItBeforeAnyFetch() async throws {
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = saturatingLoader(fetches: fetches, release: release)
        let held = Task { await loader.thumbnail(clip(id: 99, etag: "99-99")) }
        try await waitUntil { fetches.activeCount() == 1 }

        let handle = loader.prefetch(clip(id: 30, etag: "30-30"))
        try await settle()
        handle.cancel()
        try await settle()

        #expect(fetches.count(30) == 0)

        await release.signal()
        _ = await held.value
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAPrefetchBeforeItRegistersWarmsNothing() async throws {
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = saturatingLoader(fetches: fetches, release: release)
        let held = Task { await loader.thumbnail(clip(id: 99, etag: "99-99")) }
        try await waitUntil { fetches.activeCount() == 1 }

        // Cancel synchronously, before the registration Task has a chance to run.
        let handle = loader.prefetch(clip(id: 31, etag: "31-31"))
        handle.cancel()
        try await settle()

        #expect(fetches.count(31) == 0)

        await release.signal()
        _ = await held.value
    }

    @Test(.timeLimit(.minutes(1)))
    func aPrefetchHandleCancelDoesNotCancelAJoinedStrongRequest() async throws {
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = makeLoader(
            fetchPrefix: { id, etag, limit in
                fetches.begin(id, etag, limit)
                await release.wait()
                fetches.end()
                return Data([0x01])
            }
        )
        let target = clip(id: 32, etag: "32-32")

        let handle = loader.prefetch(target)
        try await settle()  // registers; its one shared fetch is in flight
        let strong = Task { await loader.thumbnail(target) }  // joins the same entry
        try await waitUntil { fetches.count(32) == 1 }

        handle.cancel()  // prefetch token withdrawn, but the strong token still pins the entry
        await release.signal()
        let image = await strong.value

        #expect(image != nil)
        #expect(fetches.count(32) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingOneOfTwoPrefetchHandlesKeepsTheEntryAlive() async throws {
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = saturatingLoader(fetches: fetches, release: release)
        let held = Task { await loader.thumbnail(clip(id: 99, etag: "99-99")) }
        try await waitUntil { fetches.activeCount() == 1 }

        let first = loader.prefetch(clip(id: 33, etag: "33-33"))
        try await settle()
        let second = loader.prefetch(clip(id: 33, etag: "33-33"))
        try await settle()
        first.cancel()  // the second handle's token still pins the entry
        try await settle()

        await release.signal()  // free the gate; the surviving prefetch runs
        _ = await held.value
        try await waitUntil { fetches.count(33) == 1 }
        second.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingBothPrefetchHandlesDropsTheEntry() async throws {
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = saturatingLoader(fetches: fetches, release: release)
        let held = Task { await loader.thumbnail(clip(id: 99, etag: "99-99")) }
        try await waitUntil { fetches.activeCount() == 1 }

        let first = loader.prefetch(clip(id: 34, etag: "34-34"))
        try await settle()
        let second = loader.prefetch(clip(id: 34, etag: "34-34"))
        try await settle()
        first.cancel()
        second.cancel()
        try await settle()

        await release.signal()
        _ = await held.value
        try await settle()
        #expect(fetches.count(34) == 0)
    }

    // MARK: Strong-waiter interest

    @Test(.timeLimit(.minutes(1)))
    func cancellingOneOfTwoStrongWaitersLeavesTheOtherToCompleteAndCache() async throws {
        let fetches = FetchLog()
        let inserts = Counter()
        let release = AsyncSignal()
        let loader = makeLoader(
            maxConcurrent: 1,
            thumbnailInsert: { id, etag, _ in _ = inserts.increment(); return URL(filePath: "/tmp/\(id)-\(etag).jpg") },
            fetchPrefix: { id, etag, limit in
                fetches.begin(id, etag, limit)
                if id == 99 { await release.wait() }
                fetches.end()
                return Data([0x01])
            }
        )
        // Saturate so the shared entry stays queued while we cancel one waiter.
        let held = Task { await loader.thumbnail(clip(id: 99, etag: "99-99")) }
        try await waitUntil { fetches.activeCount() == 1 }

        let target = clip(id: 40, etag: "40-40")
        let first = Task { await loader.thumbnail(target) }
        let second = Task { await loader.thumbnail(target) }
        try await settle()  // both join the one queued entry

        first.cancel()
        try await settle()

        await release.signal()  // free the gate; the queued entry runs
        _ = await held.value
        let secondImage = await second.value

        #expect(secondImage != nil)
        #expect(fetches.count(40) == 1)
        #expect(inserts.value() >= 1)  // the surviving waiter's result was cached
        _ = await first.value
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheOnlyStrongWaiterDropsAQueuedEntryAndALaterRequestRefetches() async throws {
        let fetches = FetchLog()
        let release = AsyncSignal()
        let loader = saturatingLoader(fetches: fetches, release: release)
        let held = Task { await loader.thumbnail(clip(id: 99, etag: "99-99")) }
        try await waitUntil { fetches.activeCount() == 1 }

        let target = clip(id: 41, etag: "41-41")
        let only = Task { await loader.thumbnail(target) }
        try await settle()  // queued behind the gate
        only.cancel()
        try await settle()
        #expect(fetches.count(41) == 0)  // no permit ever granted

        await release.signal()  // AsyncSignal is sticky: later fetches return at once
        _ = await held.value

        let image = await loader.thumbnail(target)
        #expect(image != nil)
        #expect(fetches.count(41) == 1)  // a fresh generation, not a rejoin
    }

    // MARK: Retry and poisoned-key freedom

    @Test(.timeLimit(.minutes(1)))
    func aFailedFirstPrefixDecodeRetriesAtDoubleThenCaches() async throws {
        let fetches = FetchLog()
        let inserts = Counter()
        let decodeCalls = Counter()
        let loader = makeLoader(
            thumbnailInsert: { id, etag, _ in _ = inserts.increment(); return URL(filePath: "/tmp/\(id)-\(etag).jpg") },
            fetchPrefix: { id, etag, limit in fetches.begin(id, etag, limit); fetches.end(); return Data([0x01]) },
            decodeTSPrefix: { _, _, _ in
                if decodeCalls.increment() == 1 { throw TestError.decodeFailed }
                return UIImage(data: sampleImageData) ?? UIImage()
            }
        )
        let target = clip(id: 50, etag: "50-50")

        let image = await loader.thumbnail(target)

        #expect(image != nil)
        #expect(fetches.byteLimits(50) == [twoMB, fourMB])  // one retry at double
        #expect(inserts.value() == 1)

        // Cached: a later request is a memory hit and does not climb past the one retry.
        let again = await loader.thumbnail(target)
        #expect(again != nil)
        #expect(fetches.count(50) == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTotallyFailedGenerationLeavesNoPoisonedKey() async throws {
        let fetches = FetchLog()
        let loader = makeLoader(
            fetchPrefix: { id, etag, limit in fetches.begin(id, etag, limit); fetches.end(); return Data([0x01]) },
            decodeTSPrefix: { _, _, _ in throw TestError.decodeFailed }
        )
        let target = clip(id: 51, etag: "51-51")

        let first = await loader.thumbnail(target)
        #expect(first == nil)
        #expect(fetches.count(51) == 2)  // 2 MB then 4 MB, both failed

        // No cached/parked nil task: the next request starts a fresh generation.
        let second = await loader.thumbnail(target)
        #expect(second == nil)
        #expect(fetches.count(51) == 4)
    }

    // MARK: - Helpers

    private func saturatingLoader(fetches: FetchLog, release: AsyncSignal) -> ThumbnailLoader {
        makeLoader(
            maxConcurrent: 1,
            fetchPrefix: { id, etag, limit in
                fetches.begin(id, etag, limit)
                if id == 99 { await release.wait() }
                fetches.end()
                return Data([0x01])
            }
        )
    }

    private func makeLoader(
        maxConcurrent: Int = 3,
        prefixByteLimit: Int? = nil,
        diskLookup: @escaping @Sendable (Int, String) -> URL? = { _, _ in nil },
        clipCacheLookup: @escaping @Sendable (Int, String) -> URL? = { _, _ in nil },
        thumbnailInsert: @escaping @Sendable (Int, String, Data) throws -> URL = { id, etag, _ in
            URL(filePath: "/tmp/thumb-\(id)-\(etag).jpg")
        },
        fetchPrefix: @escaping @Sendable (Int, String, Int) async throws -> Data,
        decodeTSPrefix: @escaping @Sendable (Data, Int, CGSize) async throws -> sending UIImage = { _, _, _ in UIImage(data: sampleImageData) ?? UIImage() },
        decodeMP4: @escaping @Sendable (URL, CGSize) async throws -> sending UIImage = { _, _ in UIImage(data: sampleImageData) ?? UIImage() }
    ) -> ThumbnailLoader {
        ThumbnailLoader(
            prefixClient: ClipPrefixClient(fetchPrefix: fetchPrefix),
            thumbnailCache: ThumbnailCache(lookup: diskLookup, insert: thumbnailInsert),
            clipCacheLookup: clipCacheLookup,
            decodeTSPrefix: decodeTSPrefix,
            decodeMP4: decodeMP4,
            maxConcurrent: maxConcurrent,
            prefixByteLimit: prefixByteLimit ?? twoMB
        )
    }

    private func makeJPEGFile() throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = try #require(image.jpegData(compressionQuality: 0.8))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dancam-thumb-loader-\(UUID().uuidString).jpg")
        try data.write(to: url)
        return url
    }

    private func clip(id: Int, etag: String) -> Clip {
        Clip(id: id, startMs: nil, durMs: 30_000, bytes: 1, locked: false, etag: etag, timeApproximate: false)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(40))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
    }
}

private enum TestError: Error {
    case decodeFailed
}

/// Real JPEG bytes for fake decoders: a plain `UIImage()` has no `CGImage`, so its
/// `jpegData(...)` is nil and the loader's disk insert is silently skipped -- which would
/// mask the "result is cached" assertions. Built via CoreGraphics so it is usable off the
/// main actor (the decode closures run on the concurrent pool).
private let sampleImageData: Data = {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: 8,
        height: 8,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return Data()
    }
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    guard let cgImage = context.makeImage() else { return Data() }
    return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8) ?? Data()
}()

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    func value() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(clipID: Int, etag: String, byteLimit: Int)] = []
    private var active = 0
    private var peak = 0

    func begin(_ clipID: Int, _ etag: String, _ byteLimit: Int) {
        lock.lock(); defer { lock.unlock() }
        calls.append((clipID, etag, byteLimit))
        active += 1
        peak = max(peak, active)
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }

    func count(_ clipID: Int? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let clipID else { return calls.count }
        return calls.filter { $0.clipID == clipID }.count
    }

    func etags(_ clipID: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.clipID == clipID }.map(\.etag)
    }

    func byteLimits(_ clipID: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.clipID == clipID }.map(\.byteLimit)
    }

    func activeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func peakCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}
