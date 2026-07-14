import Foundation

struct AppDependencies {
    var events: EventsClient
    var clips: ClipsClient
    var clipPull: ClipPullClient
    var clipRemuxer: ClipRemuxer
    var clipCache: ClipCache
    var incidentStore: IncidentStore
    var thumbnailLoader: ThumbnailLoader
    var preview: PreviewClient
    var recording: RecordingClient
    var time: TimeClient
    var logExporter: LogExporter
    var sleep: @Sendable (Duration) async -> Void
    var heartbeatTimeout: @Sendable () async throws -> Void

    init(
        events: EventsClient = .noop,
        clips: ClipsClient = .noop,
        clipPull: ClipPullClient = .noop,
        clipRemuxer: ClipRemuxer = .noop,
        clipCache: ClipCache = .noop,
        incidentStore: IncidentStore = .noop,
        thumbnailLoader: ThumbnailLoader = .noop,
        preview: PreviewClient = .noop,
        recording: RecordingClient = .noop,
        time: TimeClient = .noop,
        logExporter: LogExporter = .noop,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        heartbeatTimeout: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(3600))
        }
    ) {
        self.events = events
        self.clips = clips
        self.clipPull = clipPull
        self.clipRemuxer = clipRemuxer
        self.clipCache = clipCache
        self.incidentStore = incidentStore
        self.thumbnailLoader = thumbnailLoader
        self.preview = preview
        self.recording = recording
        self.time = time
        self.logExporter = logExporter
        self.sleep = sleep
        self.heartbeatTimeout = heartbeatTimeout
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
        sleep = { duration in
            try? await Task.sleep(for: duration)
        }
        heartbeatTimeout = {
            try await Task.sleep(for: configuration.heartbeatTimeout)
        }
    }

    static let live = AppDependencies(configuration: .live())
}
