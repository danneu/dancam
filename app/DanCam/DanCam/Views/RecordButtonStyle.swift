nonisolated enum RecordButtonTreatment: Equatable {
    case record
    case neutral
}

nonisolated enum RecordButtonStyle {
    static func from(
        _ state: RecordingFeature.State
    ) -> (
        title: String,
        systemImage: String?,
        isEnabled: Bool,
        treatment: RecordButtonTreatment,
        accessibilityLabel: String
    ) {
        switch state {
        case .unknown:
            return ("Record", "record.circle", false, .record, "Start recording")
        case .idle, .failed:
            return ("Record", "record.circle", true, .record, "Start recording")
        case .starting:
            return ("Starting", "record.circle", false, .record, "Starting recording")
        case .recording:
            return ("Stop", "stop.fill", true, .neutral, "Stop recording")
        case .stopping:
            return ("Stopping", "stop.fill", false, .neutral, "Stopping recording")
        }
    }
}
