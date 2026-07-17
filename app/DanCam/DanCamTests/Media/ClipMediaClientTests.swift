import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct ClipMediaClientTests {
    @Test(.timeLimit(.minutes(1)))
    func concurrentViewerIncidentAndThumbnailShareOneFullPipeline() async throws {
        let files = MediaTestFiles()
        let source = try files.make(extension: "ts", data: Data([0x01]))
        let mp4 = try files.make(extension: "mp4", data: Data([0x02]))
        let thumbnail = try files.make(extension: "jpg", data: onePixelPNG)
        defer { files.cleanup() }

        let counts = MediaCounts()
        let pullStarted = AsyncSignal()
        let releasePull = AsyncSignal()
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let client = ClipMediaClient(
            clipPull: gatedPull(
                source: source,
                clip: clip,
                counts: counts,
                started: pullStarted,
                release: releasePull
            ),
            clipRemuxer: ClipRemuxer { _, _ in
                await counts.noteRemux()
                return ClipRemuxResult(fileURL: mp4, duration: .seconds(30), bytes: 1)
            },
            clipCache: .noop,
            thumbnailCache: ThumbnailCache(
                lookup: { _, _ in thumbnail },
                insert: { _, _, _ in thumbnail }
            ),
            thumbnailLoader: ThumbnailLoader(
                thumbnail: { _ in
                    await counts.notePrefix()
                    return nil
                },
                prefetch: { _ in .inert }
            ),
            incidentArtifactInstaller: IncidentArtifactInstaller(
                install: { _, kind, _, incidentIDs in
                    await counts.noteInstall(kind)
                    return Dictionary(uniqueKeysWithValues: incidentIDs.map { ($0, 1) })
                },
                writeThumbnail: { _, _, _, _ in },
                writeThumbnailData: { _, _ in await counts.noteThumbnailWrite() }
            ),
            decodeMP4: { _ in UIImage() },
            decodeTS: { _, _ in UIImage() }
        )

        let viewer = Task { try await client.playback(clip) { _ in } }
        await pullStarted.wait()
        let incidentID = UUID()
        let incident = Task {
            try await client.preserve(clip, [incidentID], [incidentID])
        }
        let thumbnailTask = Task { await client.thumbnail(clip) }

        await releasePull.signal()
        let viewerLease = try await viewer.value
        let installed = try await incident.value
        let image = await thumbnailTask.value

        #expect(viewerLease.kind == .mp4)
        #expect(installed == [incidentID: 1])
        #expect(image != nil)
        #expect(await counts.snapshot() == MediaCounts.Snapshot(
            pulls: 1,
            remuxes: 1,
            prefixes: 0,
            installs: [.mp4],
            thumbnailWrites: 1
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func equalClipFactsFromDifferentStorageGenerationsNeverJoin() async throws {
        let files = MediaTestFiles()
        defer { files.cleanup() }
        let counts = MediaCounts()
        let client = ClipMediaClient(
            clipPull: ClipPullClient { clipID, etag in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        await counts.notePull()
                        do {
                            let source = try files.make(
                                extension: "ts",
                                data: Data(etag.utf8)
                            )
                            continuation.yield(.completed(ClipPullResult(
                                fileURL: source,
                                bytes: UInt64(etag.utf8.count),
                                elapsed: .zero,
                                throughputMbps: 1,
                                resolvedETag: httpEntityTag(etag)
                            )))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                    _ = clipID
                }
            },
            clipRemuxer: ClipRemuxer { _, _ in
                await counts.noteRemux()
                return ClipRemuxResult(
                    fileURL: try files.make(extension: "mp4", data: Data([0x02])),
                    duration: .seconds(30),
                    bytes: 1
                )
            },
            clipCache: .noop,
            thumbnailCache: .noop,
            thumbnailLoader: .noop,
            incidentArtifactInstaller: .noop,
            decodeMP4: { _ in UIImage() },
            decodeTS: { _, _ in UIImage() }
        )
        let first = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let second = mediaClip(generation: "00000000-0000-4000-8000-000000000002")

        let firstLease = try await client.playback(first) { _ in }
        let secondLease = try await client.playback(second) { _ in }

        #expect(firstLease.url != secondLease.url)
        let snapshot = await counts.snapshot()
        #expect(snapshot.pulls == 2)
        #expect(snapshot.remuxes == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func standaloneThumbnailFailureMakesOneBoundedAttempt() async {
        let counts = MediaCounts()
        let client = ClipMediaClient(
            clipPull: .noop,
            clipRemuxer: .noop,
            clipCache: .noop,
            thumbnailCache: .noop,
            thumbnailLoader: ThumbnailLoader(
                thumbnail: { _ in
                    await counts.notePrefix()
                    return nil
                },
                prefetch: { _ in .inert }
            ),
            incidentArtifactInstaller: .noop,
            decodeMP4: { _ in UIImage() },
            decodeTS: { _, _ in UIImage() }
        )
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")

        #expect(await client.thumbnail(clip) == nil)
        #expect(await counts.snapshot().prefixes == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func remuxFailurePreservesRawIncidentEvidenceButRejectsPlayback() async throws {
        let files = MediaTestFiles()
        let source = try files.make(extension: "ts", data: Data([0x01]))
        defer { files.cleanup() }
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let installedKinds = MediaCounts()
        let client = ClipMediaClient(
            clipPull: completedPull(source: source, clip: clip),
            clipRemuxer: ClipRemuxer { _, _ in
                throw ClipRemuxError.invalidTransportStream("damaged")
            },
            clipCache: .noop,
            thumbnailCache: .noop,
            thumbnailLoader: .noop,
            incidentArtifactInstaller: IncidentArtifactInstaller(
                install: { _, kind, _, incidentIDs in
                    await installedKinds.noteInstall(kind)
                    return Dictionary(uniqueKeysWithValues: incidentIDs.map { ($0, 1) })
                },
                writeThumbnail: { _, _, _, _ in }
            ),
            decodeMP4: { _ in UIImage() },
            decodeTS: { _, _ in UIImage() }
        )
        let incidentID = UUID()

        let installed = try await client.preserve(clip, [incidentID], [])
        #expect(installed == [incidentID: 1])
        #expect(await installedKinds.snapshot().installs == [.ts])
        await #expect(throws: (any Error).self) {
            _ = try await client.playback(clip) { _ in }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingOneFullConsumerDoesNotCancelAnother() async throws {
        let files = MediaTestFiles()
        let source = try files.make(extension: "ts", data: Data([0x01]))
        let mp4 = try files.make(extension: "mp4", data: Data([0x02]))
        defer { files.cleanup() }
        let counts = MediaCounts()
        let pullStarted = AsyncSignal()
        let secondJoined = AsyncSignal()
        let releasePull = AsyncSignal()
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let client = ClipMediaClient(
            clipPull: ClipPullClient { _, _ in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        await counts.notePull()
                        await pullStarted.signal()
                        while await secondJoined.hasSignaled() == false {
                            continuation.yield(.progress(bytesWritten: 0, expected: 1))
                            await Task.yield()
                        }
                        await releasePull.wait()
                        continuation.yield(.completed(ClipPullResult(
                            fileURL: source,
                            bytes: clip.bytes,
                            elapsed: .zero,
                            throughputMbps: 1,
                            resolvedETag: httpEntityTag(clip.etag)
                        )))
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            clipRemuxer: ClipRemuxer { _, _ in
                await counts.noteRemux()
                return ClipRemuxResult(fileURL: mp4, duration: .seconds(30), bytes: 1)
            },
            clipCache: .noop,
            thumbnailCache: .noop,
            thumbnailLoader: .noop,
            incidentArtifactInstaller: .noop,
            decodeMP4: { _ in UIImage() },
            decodeTS: { _, _ in UIImage() }
        )

        let first = Task { try await client.playback(clip) { _ in } }
        await pullStarted.wait()
        let second = Task {
            try await client.playback(clip) { _ in await secondJoined.signal() }
        }
        await secondJoined.wait()
        first.cancel()
        await releasePull.signal()

        await #expect(throws: CancellationError.self) { try await first.value }
        let secondLease = try await second.value
        #expect(secondLease.kind == .mp4)
        let snapshot = await counts.snapshot()
        #expect(snapshot.pulls == 1)
        #expect(snapshot.remuxes == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func finalCancellationCleansTemporaryArtifactFromCancellationIgnoringProducer() async throws {
        let files = MediaTestFiles()
        let source = try files.make(extension: "ts", data: Data([0x01]))
        let remuxed = try files.make(extension: "mp4", data: Data([0x02]))
        defer { files.cleanup() }
        let remuxStarted = AsyncSignal()
        let releaseRemux = AsyncSignal()
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let client = ClipMediaClient(
            clipPull: completedPull(source: source, clip: clip),
            clipRemuxer: ClipRemuxer { _, _ in
                await remuxStarted.signal()
                await releaseRemux.wait()
                return ClipRemuxResult(fileURL: remuxed, duration: .seconds(30), bytes: 1)
            },
            clipCache: ClipCache(
                lookup: { _, _ in nil },
                insert: { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
            ),
            thumbnailCache: .noop,
            thumbnailLoader: .noop,
            incidentArtifactInstaller: .noop,
            decodeMP4: { _ in throw CocoaError(.fileReadCorruptFile) },
            decodeTS: { _, _ in throw CocoaError(.fileReadCorruptFile) }
        )

        let viewer = Task { try await client.playback(clip) { _ in } }
        await remuxStarted.wait()
        viewer.cancel()
        await releaseRemux.signal()

        await #expect(throws: CancellationError.self) { try await viewer.value }
        #expect(FileManager.default.fileExists(atPath: remuxed.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func finalFullWithdrawalResumesRemainingThumbnailThroughBoundedPath() async throws {
        let counts = MediaCounts()
        let firstPrefixStarted = AsyncSignal()
        let firstPrefixCancelled = AsyncSignal()
        let fullStarted = AsyncSignal()
        let fullCancelled = AsyncSignal()
        let prefix = PrefixHarness(
            counts: counts,
            firstStarted: firstPrefixStarted,
            firstCancelled: firstPrefixCancelled
        )
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let pull = ClipPullClient { _, _ in
            AsyncThrowingStream { continuation in
                Task { await counts.notePull(); await fullStarted.signal() }
                continuation.onTermination = { _ in
                    Task { await fullCancelled.signal() }
                }
            }
        }
        let client = ClipMediaClient(
            clipPull: pull,
            clipRemuxer: .noop,
            clipCache: .noop,
            thumbnailCache: .noop,
            thumbnailLoader: ThumbnailLoader(
                thumbnail: { _ in await prefix.thumbnail() },
                prefetch: { _ in .inert }
            ),
            incidentArtifactInstaller: .noop,
            decodeMP4: { _ in UIImage() },
            decodeTS: { _, _ in UIImage() }
        )

        let thumbnail = Task { await client.thumbnail(clip) }
        await firstPrefixStarted.wait()
        let viewer = Task { try await client.playback(clip) { _ in } }
        await fullStarted.wait()
        await firstPrefixCancelled.wait()

        viewer.cancel()
        await fullCancelled.wait()

        #expect(await thumbnail.value != nil)
        await #expect(throws: CancellationError.self) { try await viewer.value }
        let snapshot = await counts.snapshot()
        #expect(snapshot.pulls == 1)
        #expect(snapshot.prefixes == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: MediaCleanupReason.allCases)
    func activeLeaseSurvivesDestructiveCacheCleanupUntilRelease(
        _ cleanup: MediaCleanupReason
    ) async throws {
        let files = MediaTestFiles()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "clip-media-cache-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            files.cleanup()
            try? FileManager.default.removeItem(at: root)
        }
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let cache = ClipCache.live(rootDirectory: root, now: { .distantPast }, maxBytes: 0)
        let cachedSource = try files.make(extension: "mp4", data: Data([0x03]))
        let cached = try await cache.insert(clip.id, clip.etag, cachedSource)
        let client = ClipMediaClient(
            clipPull: .noop,
            clipRemuxer: .noop,
            clipCache: cache,
            thumbnailCache: .noop,
            thumbnailLoader: .noop,
            incidentArtifactInstaller: .noop,
            decodeMP4: { _ in UIImage() },
            decodeTS: { _, _ in UIImage() }
        )

        var lease: ClipMediaLease? = try await client.playback(clip) { _ in }
        let leasedURL = try #require(lease?.url)
        switch cleanup {
        case .eviction:
            let source = try files.make(extension: "mp4", data: Data([0x04]))
            _ = try await cache.insert(8, "other-generation-8-1", source)
        case .staleValidatorSweep:
            let source = try files.make(extension: "mp4", data: Data([0x05]))
            _ = try await cache.insert(clip.id, "replacement-generation-7-1", source)
        case .explicitRemoval:
            await client.remove(clip)
        }

        #expect(FileManager.default.fileExists(atPath: cached.path) == false)
        #expect(FileManager.default.fileExists(atPath: leasedURL.path))
        lease = nil
        #expect(FileManager.default.fileExists(atPath: leasedURL.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheAndThumbnailFailureDoNotBlockPermanentIncidentInstall() async throws {
        let files = MediaTestFiles()
        let source = try files.make(extension: "ts", data: Data([0x01]))
        let mp4 = try files.make(extension: "mp4", data: Data([0x02]))
        defer { files.cleanup() }
        let clip = mediaClip(generation: "00000000-0000-4000-8000-000000000001")
        let counts = MediaCounts()
        let client = ClipMediaClient(
            clipPull: completedPull(source: source, clip: clip),
            clipRemuxer: ClipRemuxer { _, _ in
                ClipRemuxResult(fileURL: mp4, duration: .seconds(30), bytes: 1)
            },
            clipCache: ClipCache(
                lookup: { _, _ in nil },
                insert: { _, _, _ in throw CocoaError(.fileWriteNoPermission) },
                remove: { _ in }
            ),
            thumbnailCache: .noop,
            thumbnailLoader: .noop,
            incidentArtifactInstaller: IncidentArtifactInstaller(
                install: { url, kind, _, incidentIDs in
                    #expect(FileManager.default.fileExists(atPath: url.path))
                    await counts.noteInstall(kind)
                    return Dictionary(uniqueKeysWithValues: incidentIDs.map { ($0, 1) })
                },
                writeThumbnail: { _, _, _, _ in }
            ),
            decodeMP4: { _ in throw CocoaError(.fileReadCorruptFile) },
            decodeTS: { _, _ in throw CocoaError(.fileReadCorruptFile) }
        )
        let incidentID = UUID()

        let installed = try await client.preserve(clip, [incidentID], [incidentID])

        #expect(installed == [incidentID: 1])
        #expect(await counts.snapshot().installs == [.mp4])
    }

    private func mediaClip(generation: String) -> Clip {
        Clip(
            id: 7,
            storageGeneration: generation,
            startMs: nil,
            durMs: 30_000,
            bytes: 1,
            locked: false,
            etag: "\(generation)-7-1",
            timeApproximate: true
        )
    }

    private func gatedPull(
        source: URL,
        clip: Clip,
        counts: MediaCounts,
        started: AsyncSignal,
        release: AsyncSignal
    ) -> ClipPullClient {
        ClipPullClient { _, _ in
            AsyncThrowingStream { continuation in
                let task = Task {
                    await counts.notePull()
                    await started.signal()
                    await release.wait()
                    continuation.yield(.completed(ClipPullResult(
                        fileURL: source,
                        bytes: clip.bytes,
                        elapsed: .zero,
                        throughputMbps: 1,
                        resolvedETag: httpEntityTag(clip.etag)
                    )))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func completedPull(source: URL, clip: Clip) -> ClipPullClient {
        ClipPullClient { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.completed(ClipPullResult(
                    fileURL: source,
                    bytes: clip.bytes,
                    elapsed: .zero,
                    throughputMbps: 1,
                    resolvedETag: httpEntityTag(clip.etag)
                )))
                continuation.finish()
            }
        }
    }

    private var onePixelPNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6sT8AAAAASUVORK5CYII=")!
    }
}

enum MediaCleanupReason: CaseIterable, Sendable {
    case eviction
    case staleValidatorSweep
    case explicitRemoval
}

private actor MediaCounts {
    struct Snapshot: Equatable {
        var pulls = 0
        var remuxes = 0
        var prefixes = 0
        var installs: [IncidentArtifactKind] = []
        var thumbnailWrites = 0
    }

    private var value = Snapshot()

    func notePull() { value.pulls += 1 }
    func noteRemux() { value.remuxes += 1 }
    func notePrefix() { value.prefixes += 1 }
    func noteInstall(_ kind: IncidentArtifactKind) { value.installs.append(kind) }
    func noteThumbnailWrite() { value.thumbnailWrites += 1 }
    func snapshot() -> Snapshot { value }
}

private actor PrefixHarness {
    let counts: MediaCounts
    let firstStarted: AsyncSignal
    let firstCancelled: AsyncSignal
    private var calls = 0

    init(counts: MediaCounts, firstStarted: AsyncSignal, firstCancelled: AsyncSignal) {
        self.counts = counts
        self.firstStarted = firstStarted
        self.firstCancelled = firstCancelled
    }

    func thumbnail() async -> ThumbnailImage? {
        calls += 1
        await counts.notePrefix()
        if calls == 1 {
            await firstStarted.signal()
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                await firstCancelled.signal()
                return nil
            }
        }
        return ThumbnailImage(image: UIImage())
    }
}

private final class MediaTestFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func make(extension ext: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "clip-media-test-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        lock.lock()
        urls.append(url)
        lock.unlock()
        return url
    }

    func cleanup() {
        lock.lock()
        let cleanup = urls
        urls.removeAll()
        lock.unlock()
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }
}
