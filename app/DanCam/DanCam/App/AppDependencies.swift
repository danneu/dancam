import Foundation

struct AppDependencies {
    var health: HealthClient
    var preview: PreviewClient

    init(health: HealthClient, preview: PreviewClient = .noop) {
        self.health = health
        self.preview = preview
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
    }

    static let live = AppDependencies(configuration: .live())
}
