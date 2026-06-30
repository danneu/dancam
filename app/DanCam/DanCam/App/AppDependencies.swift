import Foundation

struct AppDependencies {
    var health: HealthClient
    var status: StatusClient
    var events: EventsClient
    var clips: ClipsClient
    var clipPull: ClipPullClient
    var clipRemuxer: ClipRemuxer
    var progressiveSegmenter: ProgressiveSegmenter
    var preview: PreviewClient
    var recording: RecordingClient
    var sleep: @Sendable (Duration) async -> Void
    var heartbeatTimeout: @Sendable () async throws -> Void

    init(
        health: HealthClient,
        status: StatusClient = .noop,
        events: EventsClient = .noop,
        clips: ClipsClient = .noop,
        clipPull: ClipPullClient = .noop,
        clipRemuxer: ClipRemuxer = .noop,
        progressiveSegmenter: ProgressiveSegmenter = .noop,
        preview: PreviewClient = .noop,
        recording: RecordingClient = .noop,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        heartbeatTimeout: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(3600))
        }
    ) {
        self.health = health
        self.status = status
        self.events = events
        self.clips = clips
        self.clipPull = clipPull
        self.clipRemuxer = clipRemuxer
        self.progressiveSegmenter = progressiveSegmenter
        self.preview = preview
        self.recording = recording
        self.sleep = sleep
        self.heartbeatTimeout = heartbeatTimeout
    }

    init(configuration: AppConfiguration = .live()) {
        health = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
        status = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning,
            connectTimeout: configuration.cameraAPIConnectTimeout,
            receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout
        )
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
        progressiveSegmenter = .live
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
        sleep = { duration in
            try? await Task.sleep(for: duration)
        }
        heartbeatTimeout = {
            try await Task.sleep(for: configuration.heartbeatTimeout)
        }
    }

    static let live = AppDependencies(configuration: .live())
}
