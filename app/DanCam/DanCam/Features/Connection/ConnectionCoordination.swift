nonisolated enum ConnectionCoordination {
    enum Tone: Equatable {
        case neutral
        case positive
        case negative
    }

    struct StripPresentation: Equatable {
        let caption: String
        let tone: Tone
    }

    static func presentation(for connectivity: ConnectionFeature.Connectivity) -> StripPresentation {
        switch connectivity {
        case .connecting:
            StripPresentation(caption: "Connecting", tone: .neutral)
        case .connected:
            StripPresentation(caption: "Connected", tone: .positive)
        case .disconnected:
            StripPresentation(caption: "Not connected", tone: .negative)
        }
    }

    static func shouldResumeLiveWork(
        from previous: ConnectionFeature.Connectivity,
        to next: ConnectionFeature.Connectivity
    ) -> Bool {
        previous == .disconnected && next == .connected
    }
}
