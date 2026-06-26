import Foundation

struct AppDependencies {
    var health: HealthClient
    var status: StatusClient
    var clips: ClipsClient
    var preview: PreviewClient
    var recording: RecordingClient
    var sleep: @Sendable (Duration) async -> Void

    init(
        health: HealthClient,
        status: StatusClient = .noop,
        clips: ClipsClient = .noop,
        preview: PreviewClient = .noop,
        recording: RecordingClient = .noop,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.health = health
        self.status = status
        self.clips = clips
        self.preview = preview
        self.recording = recording
        self.sleep = sleep
    }

    init(configuration: AppConfiguration = .live()) {
        health = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning
        )
        status = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning
        )
        clips = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning
        )
        preview = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning
        )
        recording = .live(
            baseURL: configuration.cameraAPIBaseURL,
            pinning: configuration.cameraAPIInterfacePinning
        )
        sleep = { duration in
            try? await Task.sleep(for: duration)
        }
    }

    static let live = AppDependencies(configuration: .live())
}
