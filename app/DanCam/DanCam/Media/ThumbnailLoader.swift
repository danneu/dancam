import UIKit

/// A ready-to-display thumbnail. UIImage is not `Sendable`, but a fully-decoded image is
/// immutable and safe to read from any thread, so this box carries one across the loader
/// actor -> MainActor cell boundary (and lets NSCache-shared images be handed back without
/// a per-caller re-decode).
nonisolated struct ThumbnailImage: @unchecked Sendable {
    let image: UIImage
}

/// Resolves a clip's first-frame thumbnail through a cache-first, three-tier pipeline
/// (memory -> disk -> free-MP4/prefix) and hands a ready image to a cell. Ephemeral media
/// stays out of the reducer; the loader is injected and driven straight from the view,
/// like `clipPull`/`clipCache` in the clip viewer.
///
/// The public facade is a struct of `@Sendable` closures backed by an internal actor that
/// owns the memory cache, a single-flight registry keyed by `(id, etag)`, and a bounded
/// concurrency gate folded into the same actor (so granting a permit and flipping an entry
/// `queued -> running` are one uninterruptible step).
nonisolated struct ThumbnailLoader: Sendable {
    var thumbnail: @Sendable (_ clip: Clip) async -> ThumbnailImage?
    var prefetch: @Sendable (_ clip: Clip) -> PrefetchHandle

    /// A started prefetch's cancel action. Value type, no `deinit`: the owner must call
    /// `cancel()` (e.g. cancel-before-replace, clear-on-reload) or the prefetch token
    /// leaks and keeps pinning its loader entry.
    nonisolated struct PrefetchHandle: Sendable {
        private let cancelAction: @Sendable () -> Void

        init(cancel: @escaping @Sendable () -> Void) {
            cancelAction = cancel
        }

        func cancel() {
            cancelAction()
        }

        static let inert = PrefetchHandle(cancel: {})
    }

    /// Direct-closure init (used by `.noop` and tests that fake the whole facade).
    init(
        thumbnail: @escaping @Sendable (_ clip: Clip) async -> ThumbnailImage?,
        prefetch: @escaping @Sendable (_ clip: Clip) -> PrefetchHandle
    ) {
        self.thumbnail = thumbnail
        self.prefetch = prefetch
    }

    /// Designated init over injected collaborators, so tests can fake the prefix client,
    /// thumb cache, clip-cache lookup, and the two decode closures.
    init(
        prefixClient: ClipPrefixClient,
        thumbnailCache: ThumbnailCache,
        clipCacheLookup: @escaping @Sendable (_ clipID: Int, _ etag: String) async -> URL?,
        decodeTSPrefix: @escaping @Sendable (_ data: Data, _ clipID: Int, _ maxPixelSize: CGSize) async throws -> sending UIImage,
        decodeMP4: @escaping @Sendable (_ url: URL, _ maxPixelSize: CGSize) async throws -> sending UIImage,
        maxConcurrent: Int,
        prefixByteLimit: Int,
        maxPixelSize: CGSize = ThumbnailLoader.thumbnailPixelSize
    ) {
        let loader = Loader(
            prefixClient: prefixClient,
            thumbnailCache: thumbnailCache,
            clipCacheLookup: clipCacheLookup,
            decodeTSPrefix: decodeTSPrefix,
            decodeMP4: decodeMP4,
            maxConcurrent: maxConcurrent,
            prefixByteLimit: prefixByteLimit,
            maxPixelSize: maxPixelSize
        )

        thumbnail = { clip in
            await loader.thumbnail(clip)
        }
        prefetch = { clip in
            let token = UUID()
            let registration = Task {
                await loader.registerPrefetch(clip, token: token)
            }
            return PrefetchHandle {
                registration.cancel()
                Task { await loader.withdrawPrefetch(clip, token: token) }
            }
        }
    }

    static func live(
        baseURL: URL,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration,
        clipCache: ClipCache,
        thumbnailsRootDirectory: URL,
        now: @escaping @Sendable () -> Date,
        maxConcurrent: Int = 3,
        prefixByteLimit: Int = 2 * 1024 * 1024
    ) -> ThumbnailLoader {
        ThumbnailLoader(
            prefixClient: .live(
                baseURL: baseURL,
                pinning: pinning,
                connectTimeout: connectTimeout,
                receiveIdleTimeout: receiveIdleTimeout
            ),
            thumbnailCache: .live(rootDirectory: thumbnailsRootDirectory, now: now),
            clipCacheLookup: clipCache.lookup,
            decodeTSPrefix: { data, clipID, size in
                try await ThumbnailDecoder.firstFrameImage(fromTSPrefix: data, clipID: clipID, maxPixelSize: size)
            },
            decodeMP4: { url, size in
                try await ThumbnailDecoder.firstFrameImage(fromMP4: url, maxPixelSize: size)
            },
            maxConcurrent: maxConcurrent,
            prefixByteLimit: prefixByteLimit
        )
    }

    static let noop = ThumbnailLoader(
        thumbnail: { _ in nil },
        prefetch: { _ in .inert }
    )

    /// 80x45 pt cell image at 3x Retina -- crisp on every current iPhone.
    static let thumbnailPixelSize = CGSize(width: 240, height: 135)
}

// MARK: - Backing actor

private nonisolated enum GenerationState {
    case queued
    case running
}

/// One key's in-flight generation. Class (reference) so the gate and interest paths mutate
/// a single shared record; only ever touched on the loader actor, so it needs no Sendable.
private nonisolated final class ThumbnailEntry {
    var task: Task<ThumbnailImage?, Never>!
    var state: GenerationState = .queued
    var strongTokens: Set<UUID> = []
    var prefetchTokens: Set<UUID> = []
}

private nonisolated struct ThumbnailKey: Hashable, Sendable {
    let id: Int
    let token: String

    init(_ clip: Clip) {
        id = clip.id
        token = CacheKey.etagToken(clip.etag)
    }

    var nsString: NSString {
        "\(id)-\(token)" as NSString
    }
}

private actor Loader {
    private let prefixClient: ClipPrefixClient
    private let thumbnailCache: ThumbnailCache
    private let clipCacheLookup: @Sendable (Int, String) async -> URL?
    private let decodeTSPrefix: @Sendable (Data, Int, CGSize) async throws -> sending UIImage
    private let decodeMP4: @Sendable (URL, CGSize) async throws -> sending UIImage
    private let maxConcurrent: Int
    private let prefixByteLimit: Int
    private let maxPixelSize: CGSize

    private let memoryCache = NSCache<NSString, UIImage>()
    private var entries: [ThumbnailKey: ThumbnailEntry] = [:]

    // Concurrency gate (tiers 3/4 only), folded into the actor.
    private var availablePermits: Int
    private var waitQueue: [ThumbnailKey] = []
    private var waiters: [ThumbnailKey: CheckedContinuation<Void, Error>] = [:]

    init(
        prefixClient: ClipPrefixClient,
        thumbnailCache: ThumbnailCache,
        clipCacheLookup: @escaping @Sendable (Int, String) async -> URL?,
        decodeTSPrefix: @escaping @Sendable (Data, Int, CGSize) async throws -> sending UIImage,
        decodeMP4: @escaping @Sendable (URL, CGSize) async throws -> sending UIImage,
        maxConcurrent: Int,
        prefixByteLimit: Int,
        maxPixelSize: CGSize
    ) {
        self.prefixClient = prefixClient
        self.thumbnailCache = thumbnailCache
        self.clipCacheLookup = clipCacheLookup
        self.decodeTSPrefix = decodeTSPrefix
        self.decodeMP4 = decodeMP4
        self.maxConcurrent = max(1, maxConcurrent)
        self.prefixByteLimit = prefixByteLimit
        self.maxPixelSize = maxPixelSize
        availablePermits = max(1, maxConcurrent)
    }

    // MARK: Public entry points

    func thumbnail(_ clip: Clip) async -> ThumbnailImage? {
        let key = ThumbnailKey(clip)
        if let cached = memoryCache.object(forKey: key.nsString) {
            return ThumbnailImage(image: cached)
        }

        let token = UUID()
        let task = entryTask(for: key, clip: clip, strong: token, prefetch: nil)

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.withdrawStrong(key: key, token: token) }
        }
        withdrawStrong(key: key, token: token)
        return image
    }

    func registerPrefetch(_ clip: Clip, token: UUID) {
        // A cancel that lands before registration runs must warm nothing.
        guard Task.isCancelled == false else { return }
        _ = entryTask(for: ThumbnailKey(clip), clip: clip, strong: nil, prefetch: token)
    }

    func withdrawPrefetch(_ clip: Clip, token: UUID) {
        let key = ThumbnailKey(clip)
        guard let entry = entries[key] else { return }
        entry.prefetchTokens.remove(token)
        cancelIfNoInterest(key: key, entry: entry)
    }

    // MARK: Single-flight registry

    private func entryTask(
        for key: ThumbnailKey,
        clip: Clip,
        strong: UUID?,
        prefetch: UUID?
    ) -> Task<ThumbnailImage?, Never> {
        let entry: ThumbnailEntry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = ThumbnailEntry()
            entries[key] = entry
            entry.task = Task { [weak self] in
                await self?.runEntry(key: key, clip: clip) ?? nil
            }
        }
        if let strong { entry.strongTokens.insert(strong) }
        if let prefetch { entry.prefetchTokens.insert(prefetch) }
        return entry.task
    }

    private func withdrawStrong(key: ThumbnailKey, token: UUID) {
        guard let entry = entries[key] else { return }
        entry.strongTokens.remove(token)
        cancelIfNoInterest(key: key, entry: entry)
    }

    /// The one uniform interest-withdrawal rule: when both token sets are empty and the
    /// entry is still `queued` (never granted a permit), drop it before it costs any bytes.
    /// A `running` entry is past the cancel point and finishes, populating the cache.
    private func cancelIfNoInterest(key: ThumbnailKey, entry: ThumbnailEntry) {
        guard entry.strongTokens.isEmpty, entry.prefetchTokens.isEmpty else { return }
        guard entry.state == .queued else { return }
        entry.task?.cancel()
    }

    private func finishEntry(key: ThumbnailKey) {
        entries[key] = nil
    }

    // MARK: Generation

    private func runEntry(key: ThumbnailKey, clip: Clip) async -> ThumbnailImage? {
        defer { finishEntry(key: key) }

        // Tier 2: disk thumb cache (ungated -- a cheap decode of a tiny JPEG).
        if let diskURL = thumbnailCache.lookup(clip.id, clip.etag),
           let image = await Self.decodeJPEGFile(diskURL) {
            memoryCache.setObject(image.image, forKey: key.nsString)
            return image
        }

        // Tiers 3/4: gated network + decode.
        do {
            try await acquirePermit(key: key)
        } catch {
            return nil // cancelled while queued -- no permit ever granted
        }
        defer { releasePermit() }

        guard let generated = await Self.generate(
            clip: clip,
            prefixClient: prefixClient,
            clipCacheLookup: clipCacheLookup,
            thumbnailCache: thumbnailCache,
            decodeTSPrefix: decodeTSPrefix,
            decodeMP4: decodeMP4,
            prefixByteLimit: prefixByteLimit,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }

        memoryCache.setObject(generated.image, forKey: key.nsString)
        return generated
    }

    /// Runs entirely off the actor (`@concurrent`): free tier (already-cached MP4) or the
    /// prefix tier (ranged GET -> remux -> decode, retrying once at a larger prefix), then
    /// persists the JPEG. Returns nil on any failure so the caller falls back to the
    /// placeholder and caches nothing.
    @concurrent
    private static func generate(
        clip: Clip,
        prefixClient: ClipPrefixClient,
        clipCacheLookup: @Sendable (Int, String) async -> URL?,
        thumbnailCache: ThumbnailCache,
        decodeTSPrefix: @Sendable (Data, Int, CGSize) async throws -> sending UIImage,
        decodeMP4: @Sendable (URL, CGSize) async throws -> sending UIImage,
        prefixByteLimit: Int,
        maxPixelSize: CGSize
    ) async -> ThumbnailImage? {
        do {
            let image: UIImage
            if let mp4URL = await clipCacheLookup(clip.id, clip.etag) {
                image = try await decodeMP4(mp4URL, maxPixelSize)
            } else {
                image = try await generateFromPrefix(
                    clip: clip,
                    prefixClient: prefixClient,
                    decodeTSPrefix: decodeTSPrefix,
                    prefixByteLimit: prefixByteLimit,
                    maxPixelSize: maxPixelSize
                )
            }

            if let jpeg = image.jpegData(compressionQuality: 0.8) {
                _ = try? thumbnailCache.insert(clip.id, clip.etag, jpeg)
            }
            return ThumbnailImage(image: image)
        } catch {
            return nil
        }
    }

    /// Fetch one GOP + margin and decode; on a *decode* failure (not a fetch failure)
    /// retry once at double the prefix, then give up.
    private static func generateFromPrefix(
        clip: Clip,
        prefixClient: ClipPrefixClient,
        decodeTSPrefix: @Sendable (Data, Int, CGSize) async throws -> sending UIImage,
        prefixByteLimit: Int,
        maxPixelSize: CGSize
    ) async throws -> sending UIImage {
        let prefix = try await prefixClient.fetchPrefix(clip.id, clip.etag, prefixByteLimit)
        do {
            return try await decodeTSPrefix(prefix, clip.id, maxPixelSize)
        } catch {
            let extended = try await prefixClient.fetchPrefix(clip.id, clip.etag, prefixByteLimit * 2)
            return try await decodeTSPrefix(extended, clip.id, maxPixelSize)
        }
    }

    @concurrent
    private static func decodeJPEGFile(_ url: URL) async -> ThumbnailImage? {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        let prepared = await image.byPreparingForDisplay()
        return ThumbnailImage(image: prepared ?? image)
    }

    // MARK: Concurrency gate (folded into the actor)

    private func acquirePermit(key: ThumbnailKey) async throws {
        if availablePermits > 0 {
            availablePermits -= 1
            entries[key]?.state = .running
            return
        }

        waitQueue.append(key)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[key] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key) }
        }
    }

    private func releasePermit() {
        availablePermits += 1
        grantNextIfPossible()
    }

    private func grantNextIfPossible() {
        guard availablePermits > 0, waitQueue.isEmpty == false else { return }
        let key = waitQueue.removeFirst()
        guard let continuation = waiters.removeValue(forKey: key) else {
            // Stale queue entry (already cancelled) -- skip and try the next.
            grantNextIfPossible()
            return
        }
        availablePermits -= 1
        entries[key]?.state = .running
        continuation.resume()
    }

    private func cancelWaiter(key: ThumbnailKey) {
        guard let index = waitQueue.firstIndex(of: key) else { return }
        waitQueue.remove(at: index)
        if let continuation = waiters.removeValue(forKey: key) {
            continuation.resume(throwing: CancellationError())
        }
    }
}
