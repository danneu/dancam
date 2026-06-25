import Foundation

struct AppDependencies {
    var health: HealthClient

    static let live = AppDependencies(
        health: .live(baseURL: URL(string: "http://10.42.0.1:8080")!)
    )
}
