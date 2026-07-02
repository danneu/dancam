import Foundation

nonisolated struct TelemetryRow: Equatable {
    var label: String
    var value: String
}

nonisolated enum HealthTelemetry {
    static func rows(for world: World?) -> [TelemetryRow] {
        guard let world else {
            return placeholderRows()
        }

        let storageDisplay = world.storage.map(Formatters.storageDisplay)

        return [
            TelemetryRow(label: "SoC temp", value: world.tempC.soc.map { Formatters.temperature($0, precise: true) } ?? "--"),
            TelemetryRow(label: "Camera temp", value: world.tempC.sensor.map { Formatters.temperature($0, precise: true) } ?? "--"),
            TelemetryRow(label: "Storage used", value: world.storage.map { Formatters.byteSize($0.used) } ?? "--"),
            TelemetryRow(label: "Storage total", value: world.storage.map { Formatters.byteSize($0.total) } ?? "--"),
            TelemetryRow(label: "Storage free", value: storageDisplay?.freeText ?? "--"),
            TelemetryRow(label: "Memory total", value: world.mem.map { Formatters.byteSize($0.total) } ?? "--"),
            TelemetryRow(label: "Memory available", value: world.mem.map { Formatters.byteSize($0.available) } ?? "--"),
            TelemetryRow(label: "Swap total", value: world.mem.map { Formatters.byteSize($0.swapTotal) } ?? "--"),
            TelemetryRow(label: "Swap used", value: world.mem.map { Formatters.byteSize($0.swapUsed) } ?? "--"),
        ]
    }

    private static func placeholderRows() -> [TelemetryRow] {
        [
            TelemetryRow(label: "SoC temp", value: "--"),
            TelemetryRow(label: "Camera temp", value: "--"),
            TelemetryRow(label: "Storage used", value: "--"),
            TelemetryRow(label: "Storage total", value: "--"),
            TelemetryRow(label: "Storage free", value: "--"),
            TelemetryRow(label: "Memory total", value: "--"),
            TelemetryRow(label: "Memory available", value: "--"),
            TelemetryRow(label: "Swap total", value: "--"),
            TelemetryRow(label: "Swap used", value: "--"),
        ]
    }
}
