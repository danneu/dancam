import Foundation

struct AppDependencies {
    var health: HealthClient

    static let live = AppDependencies(
        health: .live(baseURL: URL(string: "http://macbook.local:9000")!)
    )
}
