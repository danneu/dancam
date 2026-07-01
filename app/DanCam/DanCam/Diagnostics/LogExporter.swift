import Foundation
import OSLog

nonisolated struct LogExporter: Sendable {
    var export: @Sendable (_ since: Duration) async throws -> String

    static let live = LogExporter { since in
        let task = Task.detached(priority: .userInitiated) {
            try LiveLogExporter.export(since: since)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static let noop = LogExporter { _ in "" }
}

nonisolated struct LogLine: Equatable, Sendable {
    var date: Date
    var category: String
    var level: LogLineLevel
    var composedMessage: String
}

nonisolated enum LogLineLevel: String, Sendable {
    case undefined
    case debug
    case info
    case notice
    case error
    case fault
}

nonisolated func formatLogLines(_ lines: [LogLine]) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)

    return lines.map { line in
        [
            "[\(formatter.string(from: line.date))]",
            "[\(line.category)]",
            "[\(line.level.rawValue)]",
            line.composedMessage,
        ].joined(separator: " ")
    }
    .joined(separator: "\n")
}

extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let components = components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}

nonisolated private enum LiveLogExporter {
    static func export(since: Duration) throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date(timeIntervalSinceNow: -since.timeInterval))
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        let entries = try store.getEntries(at: position, matching: predicate)

        let lines = entries.compactMap { entry -> LogLine? in
            guard
                let log = entry as? OSLogEntryLog
            else {
                return nil
            }
            let payload = log as OSLogEntryWithPayload

            return LogLine(
                date: log.date,
                category: payload.category,
                level: log.level.logLineLevel,
                composedMessage: log.composedMessage
            )
        }

        return formatLogLines(lines)
    }
}

private extension OSLogEntryLog.Level {
    nonisolated var logLineLevel: LogLineLevel {
        switch self {
        case .undefined:
            .undefined
        case .debug:
            .debug
        case .info:
            .info
        case .notice:
            .notice
        case .error:
            .error
        case .fault:
            .fault
        @unknown default:
            .undefined
        }
    }
}
