import Foundation

typealias TelemetryRow = (label: String, value: String)

nonisolated enum HealthTelemetry {
    static func rows(for world: World?) -> [TelemetryRow] {
        guard let world else {
            return placeholderRows()
        }

        let storageDisplay = world.storage.map(Formatters.storageDisplay)

        return [
            ("SoC temp", world.tempC.soc.map { Formatters.temperature($0, precise: true) } ?? "--"),
            ("Camera temp", world.tempC.sensor.map { Formatters.temperature($0, precise: true) } ?? "--"),
            ("Storage used", world.storage.map { Formatters.byteSize($0.used) } ?? "--"),
            ("Storage total", world.storage.map { Formatters.byteSize($0.total) } ?? "--"),
            ("Storage free", storageDisplay?.freeText ?? "--"),
            ("Memory total", world.mem.map { Formatters.byteSize($0.total) } ?? "--"),
            ("Memory available", world.mem.map { Formatters.byteSize($0.available) } ?? "--"),
            ("Swap total", world.mem.map { Formatters.byteSize($0.swapTotal) } ?? "--"),
            ("Swap used", world.mem.map { Formatters.byteSize($0.swapUsed) } ?? "--"),
        ]
    }

    private static func placeholderRows() -> [TelemetryRow] {
        [
            ("SoC temp", "--"),
            ("Camera temp", "--"),
            ("Storage used", "--"),
            ("Storage total", "--"),
            ("Storage free", "--"),
            ("Memory total", "--"),
            ("Memory available", "--"),
            ("Swap total", "--"),
            ("Swap used", "--"),
        ]
    }
}
