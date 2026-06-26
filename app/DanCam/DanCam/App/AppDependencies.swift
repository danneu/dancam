import Foundation

struct AppDependencies {
    var health: HealthClient
    var preview: PreviewClient
    var recording: RecordingClient

    init(
        health: HealthClient,
        preview: PreviewClient = .noop,
        recording: RecordingClient = .noop
    ) {
        self.health = health
        self.preview = preview
        self.recording = recording
    }

    init(configuration: AppConfiguration = .live()) {
        health = .live(
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
    }

    static let live = AppDependencies(configuration: .live())
}
