import Foundation

typealias TelemetryRow = (label: String, value: String)

nonisolated enum HealthTelemetry {
    static func rows(for status: StatusResponse?) -> [TelemetryRow] {
        guard let response = status else {
            return placeholderRows()
        }

        let storageDisplay = response.storage.map(Formatters.storageDisplay)

        return [
            ("SoC temp", response.tempC.soc.map { Formatters.temperature($0, precise: true) } ?? "--"),
            ("Camera temp", response.tempC.sensor.map { Formatters.temperature($0, precise: true) } ?? "--"),
            ("Storage used", response.storage.map { Formatters.byteSize($0.used) } ?? "--"),
            ("Storage total", response.storage.map { Formatters.byteSize($0.total) } ?? "--"),
            ("Storage free", storageDisplay?.freeText ?? "--"),
            ("Memory total", response.mem.map { Formatters.byteSize($0.total) } ?? "--"),
            ("Memory available", response.mem.map { Formatters.byteSize($0.available) } ?? "--"),
            ("Swap total", response.mem.map { Formatters.byteSize($0.swapTotal) } ?? "--"),
            ("Swap used", response.mem.map { Formatters.byteSize($0.swapUsed) } ?? "--"),
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
