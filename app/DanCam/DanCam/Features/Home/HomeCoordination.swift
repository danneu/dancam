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

nonisolated struct RefreshGate {
    private var awaiting = false

    mutating func begin() {
        awaiting = true
    }

    mutating func handle(_ state: ClipsFeature.State) -> Bool {
        guard awaiting else { return false }

        switch state {
        case .loaded, .failed:
            awaiting = false
            return true
        case .idle, .loading:
            return false
        }
    }
}
