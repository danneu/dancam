import Foundation

nonisolated enum TempWarning: Equatable {
    case warn
    case critical
}

nonisolated enum Formatters {
    static let sensorWarnThreshold = 50.0
    static let sensorCriticalThreshold = 55.0

    static func storageDisplay(_ storage: Storage) -> (freeText: String, usedFraction: Double) {
        let free = storage.total >= storage.used ? storage.total - storage.used : 0
        let fraction = storage.total == 0 ? 0 : Double(storage.used) / Double(storage.total)

        return (
            freeText: byteSize(free),
            usedFraction: min(max(fraction, 0), 1)
        )
    }

    static func byteSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true

        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func temperature(_ celsius: Double, precise: Bool = false) -> String {
        if precise {
            return String(format: "%.1f C", locale: Locale(identifier: "en_US_POSIX"), celsius)
        }

        return "\(Int(celsius.rounded())) C"
    }

    static func sensorWarning(for sensor: Double?) -> TempWarning? {
        guard let sensor else { return nil }

        if sensor >= sensorCriticalThreshold {
            return .critical
        }

        if sensor >= sensorWarnThreshold {
            return .warn
        }

        return nil
    }
}
