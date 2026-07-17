import Foundation
import UIKit

nonisolated struct ClipMediaProgress: Equatable, Sendable {
    var bytesWritten: UInt64
    var expectedBytes: UInt64?
    var isPreparing: Bool
}

nonisolated enum ClipMediaKind: Sendable {
    case mp4
    case ts
}

/// A private hard link (or copy when linking is unavailable) that keeps an
/// artifact usable even if its cache entry is evicted or the Pi clip is deleted.
nonisolated final class ClipMediaLease: Sendable {
    let url: URL
    let kind: ClipMediaKind
    let thumbnailJPEG: Data?
    let isCacheHit: Bool
    private let releaseAction: @Sendable () -> Void

    init(
        url: URL,
        kind: ClipMediaKind,
        thumbnailJPEG: Data?,
        isCacheHit: Bool = false,
        release: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.kind = kind
        self.thumbnailJPEG = thumbnailJPEG
        self.isCacheHit = isCacheHit
        releaseAction = release
    }

    deinit {
        releaseAction()
    }
}

nonisolated struct ClipMediaClient: Sendable {
    typealias Progress = @Sendable (ClipMediaProgress) async -> Void

    var thumbnail: @Sendable (Clip) async -> ThumbnailImage?
    var playback: @Sendable (Clip, @escaping Progress) async throws -> ClipMediaLease
    var preserve: @Sendable (Clip, [UUID], [UUID]) async throws -> [UUID: UInt64]
    var remove: @Sendable (Clip) async -> Void

    init(
        thumbnail: @escaping @Sendable (Clip) async -> ThumbnailImage?,
        playback: @escaping @Sendable (Clip, @escaping Progress) async throws -> ClipMediaLease,
        preserve: @escaping @Sendable (Clip, [UUID], [UUID]) async throws -> [UUID: UInt64],
        remove: @escaping @Sendable (Clip) async -> Void
    ) {
        self.thumbnail = thumbnail
        self.playback = playback
        self.preserve = preserve
        self.remove = remove
    }

    init(
        clipPull: ClipPullClient,
        clipRemuxer: ClipRemuxer,
        clipCache: ClipCache,
        thumbnailCache: ThumbnailCache,
        thumbnailLoader: ThumbnailLoader,
        incidentArtifactInstaller: IncidentArtifactInstaller,
        decodeMP4: @escaping @Sendable (URL) async throws -> sending UIImage = { url in
            try await ThumbnailDecoder.firstFrameImage(
                fromMP4: url,
                maxPixelSize: ThumbnailLoader.thumbnailPixelSize
            )
        },
        decodeTS: @escaping @Sendable (URL, Int) async throws -> sending UIImage = { url, clipID in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            return try await ThumbnailDecoder.firstFrameImage(
                fromTSPrefix: prefix,
                clipID: clipID,
                maxPixelSize: ThumbnailLoader.thumbnailPixelSize
            )
        }
    ) {
        let coordinator = ClipMediaCoordinator(
            clipPull: clipPull,
            clipRemuxer: clipRemuxer,
            clipCache: clipCache,
            thumbnailCache: thumbnailCache,
            thumbnailLoader: thumbnailLoader,
            incidentArtifactInstaller: incidentArtifactInstaller,
            decodeMP4: decodeMP4,
            decodeTS: decodeTS
        )
        thumbnail = { clip in await coordinator.thumbnail(clip) }
        playback = { clip, progress in
            try await coordinator.playback(clip, progress: progress)
        }
        preserve = { clip, incidentIDs, markIncidentIDs in
            try await coordinator.preserve(
                clip,
                incidentIDs: incidentIDs,
                markIncidentIDs: markIncidentIDs
            )
        }
        remove = { clip in await coordinator.remove(clip) }
    }

    var thumbnailLoader: ThumbnailLoader {
        ThumbnailLoader(
            thumbnail: thumbnail,
            prefetch: { clip in
                let task = Task { _ = await thumbnail(clip) }
                return .init(cancel: { task.cancel() })
            }
        )
    }

    static let noop = ClipMediaClient(
        thumbnail: { _ in nil },
        playback: { _, _ in throw CancellationError() },
        preserve: { _, _, _ in [:] },
        remove: { _ in }
    )
}

private nonisolated struct ClipMediaKey: Hashable, Sendable {
    var storageGeneration: String
    var clipID: Int
    var etagToken: String

    init(_ clip: Clip) {
        storageGeneration = clip.storageGeneration
        clipID = clip.id
        etagToken = CacheKey.etagToken(clip.etag)
    }
}

private nonisolated struct ClipMediaArtifact: Sendable {
    var url: URL
    var kind: ClipMediaKind
    var thumbnailJPEG: Data?
    var isTemporary: Bool
    var isCacheHit: Bool
}

private nonisolated final class ClipMediaEntry: @unchecked Sendable {
    let lock = NSLock()
    var fullTask: Task<ClipMediaArtifact, Error>?
    var fullTaskID: UUID?
    var thumbnailTask: Task<ThumbnailImage?, Never>?
    var thumbnailTaskID: UUID?
    var fullTokens: Set<UUID> = []
    var thumbnailTokens: Set<UUID> = []
    var progress: [UUID: ClipMediaClient.Progress] = [:]
    var artifact: ClipMediaArtifact?
    var leaseCreations = 0
    var isRemoved = false

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor ClipMediaCoordinator {
    private let clipPull: ClipPullClient
    private let clipRemuxer: ClipRemuxer
    private let clipCache: ClipCache
    private let thumbnailCache: ThumbnailCache
    private let thumbnailLoader: ThumbnailLoader
    private let incidentArtifactInstaller: IncidentArtifactInstaller
    private let decodeMP4: @Sendable (URL) async throws -> sending UIImage
    private let decodeTS: @Sendable (URL, Int) async throws -> sending UIImage
    private var entries: [ClipMediaKey: ClipMediaEntry] = [:]

    init(
        clipPull: ClipPullClient,
        clipRemuxer: ClipRemuxer,
        clipCache: ClipCache,
        thumbnailCache: ThumbnailCache,
        thumbnailLoader: ThumbnailLoader,
        incidentArtifactInstaller: IncidentArtifactInstaller,
        decodeMP4: @escaping @Sendable (URL) async throws -> sending UIImage,
        decodeTS: @escaping @Sendable (URL, Int) async throws -> sending UIImage
    ) {
        self.clipPull = clipPull
        self.clipRemuxer = clipRemuxer
        self.clipCache = clipCache
        self.thumbnailCache = thumbnailCache
        self.thumbnailLoader = thumbnailLoader
        self.incidentArtifactInstaller = incidentArtifactInstaller
        self.decodeMP4 = decodeMP4
        self.decodeTS = decodeTS
    }

    func thumbnail(_ clip: Clip) async -> ThumbnailImage? {
        let key = ClipMediaKey(clip)
        let token = UUID()
        let entry = entry(for: key)
        _ = entry.withLock { entry.thumbnailTokens.insert(token) }
        defer { withdrawThumbnail(key: key, token: token) }

        while Task.isCancelled == false {
            if entry.withLock({ entry.isRemoved }) { return nil }
            if let artifact = entry.withLock({ entry.artifact }),
               let image = await image(from: artifact.thumbnailJPEG) {
                return image
            }

            if let (fullTask, fullTaskID) = entry.withLock({
                entry.fullTask.map { ($0, entry.fullTaskID) }
            }) {
                if let artifact = try? await fullTask.value {
                    guard await record(artifact, taskID: fullTaskID, for: key, entry: entry) else {
                        return nil
                    }
                    if let image = await image(from: artifact.thumbnailJPEG) {
                        return image
                    }
                } else {
                    clearFullTask(entry, taskID: fullTaskID)
                }
                continue
            }

            let (task, taskID): (Task<ThumbnailImage?, Never>, UUID) = entry.withLock {
                if let task = entry.thumbnailTask, let taskID = entry.thumbnailTaskID {
                    return (task, taskID)
                }
                let taskID = UUID()
                let task = Task { [thumbnailLoader] in
                    await thumbnailLoader.thumbnail(clip)
                }
                entry.thumbnailTask = task
                entry.thumbnailTaskID = taskID
                return (task, taskID)
            }
            let image = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { await self.withdrawThumbnail(key: key, token: token) }
            }
            entry.withLock {
                if entry.thumbnailTaskID == taskID {
                    entry.thumbnailTask = nil
                    entry.thumbnailTaskID = nil
                }
            }
            if Task.isCancelled { return nil }
            if let image { return image }
            if entry.withLock({ entry.fullTask != nil }) { continue }
            return nil
        }
        return nil
    }

    func playback(_ clip: Clip, progress: @escaping ClipMediaClient.Progress) async throws -> ClipMediaLease {
        let artifact = try await acquireFull(clip, progress: progress)
        guard artifact.kind == .mp4 else {
            throw ClipMediaError.remuxFailed
        }
        return artifact
    }

    func preserve(
        _ clip: Clip,
        incidentIDs: [UUID],
        markIncidentIDs: [UUID]
    ) async throws -> [UUID: UInt64] {
        let lease = try await acquireFull(clip, progress: { _ in })
        if let jpeg = lease.thumbnailJPEG, markIncidentIDs.isEmpty == false {
            await incidentArtifactInstaller.writeThumbnailData(jpeg, markIncidentIDs)
        }
        return try await incidentArtifactInstaller.install(
            lease.url,
            lease.kind == .mp4 ? .mp4 : .ts,
            clip.id,
            incidentIDs
        )
    }

    func remove(_ clip: Clip) async {
        let key = ClipMediaKey(clip)
        if let entry = entries[key] {
            let cleanup = entry.withLock { () -> (
                Task<ClipMediaArtifact, Error>?,
                Task<ThumbnailImage?, Never>?,
                ClipMediaArtifact?,
                Bool
            ) in
                entry.isRemoved = true
                return (
                    entry.fullTask,
                    entry.thumbnailTask,
                    entry.artifact,
                    entry.leaseCreations == 0
                )
            }
            cleanup.0?.cancel()
            cleanup.1?.cancel()
            if cleanup.3, let artifact = cleanup.2, artifact.isTemporary {
                try? FileManager.default.removeItem(at: artifact.url)
            }
            if cleanup.3 { await clipCache.remove(clip.id) }
            discardIfIdle(key: key, entry: entry)
            return
        }
        await clipCache.remove(clip.id)
    }

    private func acquireFull(
        _ clip: Clip,
        progress: @escaping ClipMediaClient.Progress
    ) async throws -> ClipMediaLease {
        let key = ClipMediaKey(clip)
        let token = UUID()
        let entry = entry(for: key)
        guard entry.withLock({ entry.isRemoved == false }) else {
            throw CancellationError()
        }
        let (task, taskID): (Task<ClipMediaArtifact, Error>, UUID?) = entry.withLock {
            entry.fullTokens.insert(token)
            entry.progress[token] = progress
            entry.thumbnailTask?.cancel()
            entry.thumbnailTask = nil
            if let artifact = entry.artifact,
               FileManager.default.fileExists(atPath: artifact.url.path) {
                return (Task { artifact }, nil)
            }
            if let task = entry.fullTask { return (task, entry.fullTaskID) }
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await Self.produce(
                    clip: clip,
                    clipPull: self.clipPull,
                    clipRemuxer: self.clipRemuxer,
                    clipCache: self.clipCache,
                    thumbnailCache: self.thumbnailCache,
                    decodeMP4: self.decodeMP4,
                    decodeTS: self.decodeTS,
                    progress: { [weak self] progress in
                        await self?.publish(progress, key: key)
                    }
                )
            }
            entry.fullTask = task
            entry.fullTaskID = taskID
            return (task, taskID)
        }

        var isCreatingLease = false
        do {
            let artifact = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.withdrawFull(key: key, token: token) }
            }
            guard await record(artifact, taskID: taskID, for: key, entry: entry) else {
                throw CancellationError()
            }
            entry.withLock { entry.leaseCreations += 1 }
            isCreatingLease = true
            try Task.checkCancellation()
            let leasedURL = try await Self.makeLease(of: artifact.url, kind: artifact.kind)
            isCreatingLease = false
            await finishLeaseCreation(key: key, entry: entry)
            guard entry.withLock({ entry.isRemoved == false }) else {
                try? FileManager.default.removeItem(at: leasedURL)
                throw CancellationError()
            }
            return ClipMediaLease(
                url: leasedURL,
                kind: artifact.kind,
                thumbnailJPEG: artifact.thumbnailJPEG,
                isCacheHit: artifact.isCacheHit,
                release: { [weak self] in
                    try? FileManager.default.removeItem(at: leasedURL)
                    Task { await self?.withdrawFull(key: key, token: token) }
                }
            )
        } catch {
            if isCreatingLease {
                await finishLeaseCreation(key: key, entry: entry)
            }
            clearFullTask(entry, taskID: taskID)
            withdrawFull(key: key, token: token)
            throw error
        }
    }

    private func entry(for key: ClipMediaKey) -> ClipMediaEntry {
        if let entry = entries[key] { return entry }
        let entry = ClipMediaEntry()
        entries[key] = entry
        return entry
    }

    private func record(
        _ artifact: ClipMediaArtifact,
        taskID: UUID?,
        for key: ClipMediaKey,
        entry: ClipMediaEntry
    ) async -> Bool {
        guard entries[key] === entry, entry.withLock({ entry.isRemoved == false }) else {
            clearFullTask(entry, taskID: taskID)
            if artifact.isTemporary { try? FileManager.default.removeItem(at: artifact.url) }
            await clipCache.remove(key.clipID)
            return false
        }
        entry.withLock {
            entry.artifact = artifact
            if taskID == nil || entry.fullTaskID == taskID {
                entry.fullTask = nil
                entry.fullTaskID = nil
            }
        }
        return true
    }

    private func finishLeaseCreation(key: ClipMediaKey, entry: ClipMediaEntry) async {
        let cleanup = entry.withLock { () -> (shouldRemove: Bool, artifact: ClipMediaArtifact?) in
            entry.leaseCreations -= 1
            guard entry.isRemoved, entry.leaseCreations == 0 else { return (false, nil) }
            return (true, entry.artifact)
        }
        guard cleanup.shouldRemove else { return }
        if let artifact = cleanup.artifact, artifact.isTemporary {
            try? FileManager.default.removeItem(at: artifact.url)
        }
        await clipCache.remove(key.clipID)
    }

    private func clearFullTask(_ entry: ClipMediaEntry, taskID: UUID?) {
        entry.withLock {
            guard taskID == nil || entry.fullTaskID == taskID else { return }
            entry.fullTask = nil
            entry.fullTaskID = nil
        }
    }

    private func withdrawFull(key: ClipMediaKey, token: UUID) {
        guard let entry = entries[key] else { return }
        let shouldCancel = entry.withLock { () -> Bool in
            entry.fullTokens.remove(token)
            entry.progress[token] = nil
            return entry.fullTokens.isEmpty
        }
        guard shouldCancel else { return }
        entry.withLock { entry.fullTask?.cancel() }
        discardIfIdle(key: key, entry: entry)
    }

    private func withdrawThumbnail(key: ClipMediaKey, token: UUID) {
        guard let entry = entries[key] else { return }
        let shouldCancel = entry.withLock { () -> Bool in
            entry.thumbnailTokens.remove(token)
            return entry.thumbnailTokens.isEmpty
        }
        if shouldCancel { entry.withLock { entry.thumbnailTask?.cancel() } }
        discardIfIdle(key: key, entry: entry)
    }

    private func discardIfIdle(key: ClipMediaKey, entry: ClipMediaEntry) {
        let idleState = entry.withLock { () -> (isIdle: Bool, cleanup: ClipMediaArtifact?) in
            guard entry.fullTokens.isEmpty,
                  entry.thumbnailTokens.isEmpty,
                  entry.fullTask == nil,
                  entry.thumbnailTask == nil else { return (false, nil) }
            let cleanup = entry.artifact?.isTemporary == true ? entry.artifact : nil
            return (true, cleanup)
        }
        guard idleState.isIdle else { return }
        if let cleanup = idleState.cleanup {
            try? FileManager.default.removeItem(at: cleanup.url)
        }
        entries[key] = nil
    }

    private func publish(_ progress: ClipMediaProgress, key: ClipMediaKey) async {
        guard let entry = entries[key] else { return }
        let handlers = entry.withLock { Array(entry.progress.values) }
        for handler in handlers { await handler(progress) }
    }

    private func image(from jpeg: Data?) async -> ThumbnailImage? {
        guard let jpeg, let image = UIImage(data: jpeg) else { return nil }
        let prepared = await image.byPreparingForDisplay()
        return ThumbnailImage(image: prepared ?? image)
    }

    @concurrent
    private static func produce(
        clip: Clip,
        clipPull: ClipPullClient,
        clipRemuxer: ClipRemuxer,
        clipCache: ClipCache,
        thumbnailCache: ThumbnailCache,
        decodeMP4: @Sendable (URL) async throws -> sending UIImage,
        decodeTS: @Sendable (URL, Int) async throws -> sending UIImage,
        progress: @escaping @Sendable (ClipMediaProgress) async -> Void
    ) async throws -> ClipMediaArtifact {
        if let cached = await clipCache.lookup(clip.id, clip.etag) {
            let thumbnail = await thumbnailJPEG(
                clip: clip,
                source: cached,
                kind: .mp4,
                thumbnailCache: thumbnailCache,
                decodeMP4: decodeMP4,
                decodeTS: decodeTS
            )
            return ClipMediaArtifact(
                url: cached,
                kind: .mp4,
                thumbnailJPEG: thumbnail,
                isTemporary: false,
                isCacheHit: true
            )
        }

        var pullResult: ClipPullResult?
        for try await event in clipPull.pull(clip.id, clip.etag) {
            try Task.checkCancellation()
            switch event {
            case .opened, .restarted:
                break
            case .progress(let bytesWritten, let expected):
                await progress(ClipMediaProgress(
                    bytesWritten: bytesWritten,
                    expectedBytes: expected,
                    isPreparing: false
                ))
            case .completed(let completed):
                guard completed.resolvedETag == httpEntityTag(clip.etag) else {
                    try? FileManager.default.removeItem(at: completed.fileURL)
                    throw ClipPullError.staleRepresentation
                }
                pullResult = completed
            }
        }
        try Task.checkCancellation()
        guard let pullResult else { throw ClipMediaError.incompletePull }
        await progress(ClipMediaProgress(
            bytesWritten: pullResult.bytes,
            expectedBytes: pullResult.bytes,
            isPreparing: true
        ))

        do {
            let remuxed = try await clipRemuxer.remux(pullResult.fileURL, clip.id)
            let thumbnail = await thumbnailJPEG(
                clip: clip,
                source: remuxed.fileURL,
                kind: .mp4,
                thumbnailCache: thumbnailCache,
                decodeMP4: decodeMP4,
                decodeTS: decodeTS
            )
            let artifact: ClipMediaArtifact
            do {
                let cached = try await clipCache.insert(clip.id, clip.etag, remuxed.fileURL)
                artifact = ClipMediaArtifact(
                    url: cached,
                    kind: .mp4,
                    thumbnailJPEG: thumbnail,
                    isTemporary: false,
                    isCacheHit: false
                )
            } catch {
                artifact = ClipMediaArtifact(
                    url: remuxed.fileURL,
                    kind: .mp4,
                    thumbnailJPEG: thumbnail,
                    isTemporary: true,
                    isCacheHit: false
                )
            }
            if pullResult.fileURL != artifact.url {
                try? FileManager.default.removeItem(at: pullResult.fileURL)
            }
            return artifact
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: pullResult.fileURL)
            throw CancellationError()
        } catch {
            let thumbnail = await thumbnailJPEG(
                clip: clip,
                source: pullResult.fileURL,
                kind: .ts,
                thumbnailCache: thumbnailCache,
                decodeMP4: decodeMP4,
                decodeTS: decodeTS
            )
            return ClipMediaArtifact(
                url: pullResult.fileURL,
                kind: .ts,
                thumbnailJPEG: thumbnail,
                isTemporary: true,
                isCacheHit: false
            )
        }
    }

    @concurrent
    private static func thumbnailJPEG(
        clip: Clip,
        source: URL,
        kind: ClipMediaKind,
        thumbnailCache: ThumbnailCache,
        decodeMP4: @Sendable (URL) async throws -> sending UIImage,
        decodeTS: @Sendable (URL, Int) async throws -> sending UIImage
    ) async -> Data? {
        if let cached = thumbnailCache.lookup(clip.id, clip.etag),
           let data = try? Data(contentsOf: cached) {
            return data
        }
        do {
            let image = switch kind {
            case .mp4: try await decodeMP4(source)
            case .ts: try await decodeTS(source, clip.id)
            }
            guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
            _ = try? thumbnailCache.insert(clip.id, clip.etag, jpeg)
            return jpeg
        } catch {
            return nil
        }
    }

    @concurrent
    private static func makeLease(of source: URL, kind: ClipMediaKind) async throws -> URL {
        let ext = kind == .mp4 ? "mp4" : "ts"
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "media-lease-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.linkItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }
}

private nonisolated enum ClipMediaError: Error {
    case incompletePull
    case remuxFailed
}
