import Foundation
@preconcurrency import UserNotifications

nonisolated struct IncidentNotifier: Sendable {
    var requestProvisionalAuth: @Sendable () async -> Void
    var scheduleNudge: @Sendable (UUID, Duration) async -> Void
    var cancelNudge: @Sendable (UUID) async -> Void

    static let noop = IncidentNotifier(
        requestProvisionalAuth: {},
        scheduleNudge: { _, _ in },
        cancelNudge: { _ in }
    )

    static let live: IncidentNotifier = {
        let center = UNUserNotificationCenter.current()
        return IncidentNotifier(
            requestProvisionalAuth: {
                _ = try? await center.requestAuthorization(options: [.provisional])
            },
            scheduleNudge: { incidentID, fireIn in
                let content = UNMutableNotificationContent()
                content.title = "Incident still saving"
                content.body = "Open DanCam to finish."
                let interval = max(1, fireIn.timeInterval)
                let request = UNNotificationRequest(
                    identifier: notificationID(incidentID),
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                )
                try? await center.add(request)
            },
            cancelNudge: { incidentID in
                center.removePendingNotificationRequests(withIdentifiers: [notificationID(incidentID)])
            }
        )
    }()

    private static func notificationID(_ incidentID: UUID) -> String {
        "incident-nudge-\(incidentID.uuidString)"
    }
}
