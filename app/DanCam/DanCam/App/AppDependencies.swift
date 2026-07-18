import Foundation

struct AppDependencies {
    var events: EventsClient
    var clips: ClipsClient
    var clipPull: ClipPullClient
    var clipRemuxer: ClipRemuxer
    var clipCache: ClipCache
    var clipMedia: ClipMediaClient
    var incidentStore: IncidentStore
    var incidentNotifier: IncidentNotifier
    var incidentArtifactInstaller: IncidentArtifactInstaller
    var incidentBackgroundTask: IncidentBackgroundTaskClient
    var thumbnailLoader: ThumbnailLoader
    var preview: PreviewClient
    var recording: RecordingClient
    var time: TimeClient
    var logExporter: LogExporter
    var shareArtifactPreparer: ShareArtifactPreparer
    var onboarding: OnboardingClient
    var sleep: @Sendable (Duration) async -> Void
    var heartbeatTimeout: @Sendable () async throws -> Void
    var continuousNow: @Sendable () -> ContinuousClock.Instant
    var wallNow: @Sendable () -> Date
    var uuid: @Sendable () -> UUID

    init(
        events: EventsClient = .noop,
        clips: ClipsClient = .noop,
        clipPull: ClipPullClient = .noop,
        clipRemuxer: ClipRemuxer = .noop,
        clipCache: ClipCache = .noop,
        clipMedia: ClipMediaClient? = nil,
        incidentStore: IncidentStore = .noop,
        incidentNotifier: IncidentNotifier = .noop,
        incidentArtifactInstaller: IncidentArtifactInstaller = .noop,
        incidentBackgroundTask: IncidentBackgroundTaskClient = .noop,
        thumbnailLoader: ThumbnailLoader = .noop,
        preview: PreviewClient = .noop,
        recording: RecordingClient = .noop,
        time: TimeClient = .noop,
        logExporter: LogExporter = .noop,
        shareArtifactPreparer: ShareArtifactPreparer = .unavailable,
        onboarding: OnboardingClient = .noop,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        heartbeatTimeout: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(3600))
        },
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        wallNow: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.events = events
        self.clips = clips
        self.clipPull = clipPull
        self.clipRemuxer = clipRemuxer
        self.clipCache = clipCache
        self.incidentStore = incidentStore
        self.incidentNotifier = incidentNotifier
        self.incidentArtifactInstaller = incidentArtifactInstaller
        self.incidentBackgroundTask = incidentBackgroundTask
        let resolvedMedia = clipMedia ?? ClipMediaClient(
            clipPull: clipPull,
            clipRemuxer: clipRemuxer,
            clipCache: clipCache,
            thumbnailCache: .noop,
            thumbnailLoader: thumbnailLoader,
            incidentArtifactInstaller: incidentArtifactInstaller
        )
        self.clipMedia = resolvedMedia
        self.thumbnailLoader = clipMedia == nil ? thumbnailLoader : resolvedMedia.thumbnailLoader
        self.preview = preview
        self.recording = recording
        self.time = time
        self.logExporter = logExporter
        self.shareArtifactPreparer = shareArtifactPreparer
        self.onboarding = onboarding
        self.sleep = sleep
        self.heartbeatTimeout = heartbeatTimeout
        self.continuousNow = continuousNow
        self.wallNow = wallNow
        self.uuid = uuid
    }

    init(configuration: AppConfiguration) {
        events = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
        clips = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
        clipPull = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
        clipRemuxer = .live
        let liveClipCache = ClipCache.live(
            rootDirectory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "clips", directoryHint: .isDirectory),
            now: { Date() }
        )
        clipCache = liveClipCache
        incidentStore = .live(
            rootDirectory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Incidents", directoryHint: .isDirectory)
        )
        incidentNotifier = .live
        let liveArtifactInstaller = IncidentArtifactInstaller.live(directoryURL: incidentStore.directoryURL)
        incidentArtifactInstaller = liveArtifactInstaller
        incidentBackgroundTask = .live
        let liveThumbnailCache = ThumbnailCache.live(
            rootDirectory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "thumbnails", directoryHint: .isDirectory),
            now: { Date() }
        )
        let liveThumbnailLoader = ThumbnailLoader(
            prefixClient: .live(
                baseURL: configuration.cameraAPIBaseURL,
                pinning: configuration.cameraAPIInterfacePinning,
                connectTimeout: configuration.cameraAPIConnectTimeout,
                receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
            ),
            thumbnailCache: liveThumbnailCache,
            clipCacheLookup: liveClipCache.lookup,
            decodeTSPrefix: { data, clipID, size in
                try await ThumbnailDecoder.firstFrameImage(
                    fromTSPrefix: data,
                    clipID: clipID,
                    maxPixelSize: size
                )
            },
            decodeMP4: { url, size in
                try await ThumbnailDecoder.firstFrameImage(fromMP4: url, maxPixelSize: size)
            },
            maxConcurrent: 3,
            prefixByteLimit: 2 * 1024 * 1024
        )
        let liveClipMedia = ClipMediaClient(
            clipPull: clipPull,
            clipRemuxer: clipRemuxer,
            clipCache: liveClipCache,
            thumbnailCache: liveThumbnailCache,
            thumbnailLoader: liveThumbnailLoader,
            incidentArtifactInstaller: liveArtifactInstaller
        )
        clipMedia = liveClipMedia
        thumbnailLoader = liveClipMedia.thumbnailLoader
        preview = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
        recording = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
        time = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
        logExporter = .live
        shareArtifactPreparer = .live()
        onboarding = .live(
            recordsDirectory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Cameras", directoryHint: .isDirectory)
        )
        sleep = { duration in
            try? await Task.sleep(for: duration)
        }
        heartbeatTimeout = {
            try await Task.sleep(for: configuration.heartbeatTimeout)
        }
        continuousNow = { ContinuousClock().now }
        wallNow = Date.init
        uuid = UUID.init
    }

    static let live = AppDependencies(configuration: .live())
}
