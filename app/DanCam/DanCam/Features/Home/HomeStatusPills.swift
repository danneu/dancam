import Foundation

nonisolated struct HomeStatusPills: Equatable {
    var tempWarning: Warning?
    var cameraOffline: Bool
    var timeUnverified = false

    nonisolated struct Warning: Equatable {
        var caption: String
        var isCritical: Bool
    }

    static func from(_ world: World?) -> HomeStatusPills {
        guard let world else {
            return HomeStatusPills(tempWarning: nil, cameraOffline: false)
        }

        var warning: Warning?
        if let sensor = world.tempC.sensor.current,
           let level = Formatters.sensorWarning(for: sensor) {
            warning = Warning(
                caption: "\(Formatters.temperature(sensor)) camera",
                isCritical: level == .critical
            )
        }

        return HomeStatusPills(
            tempWarning: warning,
            cameraOffline: world.cameraState == .offline,
            timeUnverified: world.time?.synced != true
        )
    }
}
