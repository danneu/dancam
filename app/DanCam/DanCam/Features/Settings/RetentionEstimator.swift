import Foundation

nonisolated struct RetentionEstimator: Equatable, Sendable {
    private(set) var maxBytesPerSecond: Double?

    mutating func observe(_ clip: Clip) {
        guard clip.bytes > 0,
              let duration = clip.durMs,
              (25_000...35_000).contains(duration)
        else { return }

        let rate = Double(clip.bytes) * 1_000 / Double(duration)
        guard rate.isFinite, rate > 0 else { return }
        maxBytesPerSecond = max(maxBytesPerSecond ?? 0, rate)
    }

    mutating func reset() {
        maxBytesPerSecond = nil
    }

    func estimatedDurationMs(capacityBytes: UInt64) -> UInt64? {
        guard let maxBytesPerSecond, maxBytesPerSecond > 0 else { return nil }
        let milliseconds = Double(capacityBytes) * 1_000 / maxBytesPerSecond
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
        if milliseconds >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(milliseconds.rounded(.down))
    }
}
