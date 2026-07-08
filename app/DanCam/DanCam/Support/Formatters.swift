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

    static func clipDuration(_ durMs: UInt64?) -> String? {
        guard let durMs else { return nil }

        let totalSeconds = durMs / 1_000 + (durMs % 1_000 >= 500 ? 1 : 0)
        return minutesSeconds(totalSeconds: totalSeconds)
    }

    static func countUpDuration(_ durMs: UInt64) -> String {
        minutesSeconds(totalSeconds: durMs / 1_000)
    }

    static func approximateDuration(_ durMs: UInt64) -> String {
        "~" + minutesSeconds(totalSeconds: durMs / 1_000)
    }

    static func clipExportFilename(_ clip: Clip, timeZone: TimeZone = .current) -> String {
        if let date = clip.resolvedStartDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            return "Dashcam \(formatter.string(from: date)).mp4"
        }

        return String(format: "Dashcam seg_%05d.mp4", clip.id)
    }

    static func clipCreatedTime(_ clip: Clip, timeZone: TimeZone = .current) -> String? {
        guard let date = clip.resolvedStartDate else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func clipTimeOfDay(_ clip: Clip, timeZone: TimeZone = .current) -> String? {
        guard let date = clip.resolvedStartDate else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func dayHeader(_ dayStart: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(dayStart, inSameDayAs: now) {
            return "Today"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(dayStart, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"

        if calendar.component(.year, from: dayStart) != calendar.component(.year, from: now) {
            formatter.dateFormat += ", yyyy"
        }

        return formatter.string(from: dayStart)
    }

    private static func minutesSeconds(totalSeconds: UInt64) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        return String(format: "%02llu:%02llu", minutes, seconds)
    }

    static func clipMetadata(durMs: UInt64?, bytes: UInt64) -> String {
        let byteText = byteSize(bytes)
        guard let durationText = clipDuration(durMs) else { return byteText }

        return "\(durationText) · \(byteText)"
    }

    /// Home list-row subtitle: recording time plus duration, without filesize.
    static func clipListLine(_ clip: Clip, timeZone: TimeZone = .current) -> String {
        let created = clipCreatedTime(clip, timeZone: timeZone)
        let duration = clipDuration(clip.durMs)
        return [created, duration].compactMap { $0 }.joined(separator: " · ")
    }

    static func clipDetailLine(_ clip: Clip, timeZone: TimeZone = .current) -> String {
        let metadata = clipMetadata(durMs: clip.durMs, bytes: clip.bytes)
        guard let created = clipCreatedTime(clip, timeZone: timeZone) else {
            return metadata
        }

        return "\(created) · \(metadata)"
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
