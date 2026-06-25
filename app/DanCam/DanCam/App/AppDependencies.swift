import Foundation

struct AppDependencies {
    var health: HealthClient

    init(health: HealthClient) {
        self.health = health
    }

    init(configuration: AppConfiguration = .live()) {
        health = .live(baseURL: configuration.cameraAPIBaseURL)
    }

    static let live = AppDependencies(configuration: .live())
}
