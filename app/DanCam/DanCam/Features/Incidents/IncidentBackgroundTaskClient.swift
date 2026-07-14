@preconcurrency import UIKit

nonisolated struct IncidentBackgroundTaskClient: Sendable {
    var begin: @Sendable (_ expiration: @escaping @Sendable () -> Void) async -> Int
    var end: @Sendable (_ token: Int) async -> Void

    static let live = IncidentBackgroundTaskClient(
        begin: { expiration in
            await MainActor.run {
                UIApplication.shared.beginBackgroundTask(
                    withName: "Save incident footage",
                    expirationHandler: expiration
                ).rawValue
            }
        },
        end: { token in
            guard token != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
            await MainActor.run {
                UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
            }
        }
    )

    static let noop = IncidentBackgroundTaskClient(
        begin: { _ in UIBackgroundTaskIdentifier.invalid.rawValue },
        end: { _ in }
    )
}
