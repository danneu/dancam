import Foundation

nonisolated enum HomeCoordination {
    static func shouldRefreshClips(
        from previous: RecordingFeature.State,
        to next: RecordingFeature.State
    ) -> Bool {
        guard case .idle = next else { return false }

        switch previous {
        case .recording, .stopping:
            return true
        case .unknown, .idle, .starting, .failed:
            return false
        }
    }
}
