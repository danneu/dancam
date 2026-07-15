import Foundation

struct AppDependencies {
    var events: EventsClient
    var clips: ClipsClient
    var clipPull: ClipPullClient
    var clipRemuxer: ClipRemuxer
    var clipCache: ClipCache
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
        self.thumbnailLoader = thumbnailLoader
        self.preview = preview
        self.recording = recording
        self.time = time
        self.logExporter = logExporter
        self.shareArtifactPreparer = shareArtifactPreparer
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
        clipCache = .live(
            rootDirectory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "clips", directoryHint: .isDirectory),
            now: { Date() }
        )
        incidentStore = .live(
            rootDirectory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Incidents", directoryHint: .isDirectory)
        )
        incidentNotifier = .live
        incidentArtifactInstaller = .live(directoryURL: incidentStore.directoryURL)
        incidentBackgroundTask = .live
        thumbnailLoader = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout,
            clipCache: clipCache,
            thumbnailsRootDirectory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "thumbnails", directoryHint: .isDirectory),
            now: { Date() }
        )
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
