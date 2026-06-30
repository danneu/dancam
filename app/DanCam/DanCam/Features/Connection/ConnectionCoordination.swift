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

    static func presentation(for link: Link) -> StripPresentation {
        switch link {
        case .connecting:
            StripPresentation(caption: "Connecting", tone: .neutral)
        case .online:
            StripPresentation(caption: "Connected", tone: .positive)
        case .offline:
            StripPresentation(caption: "Not connected", tone: .negative)
        }
    }

    static func shouldResumeLiveWork(
        from previous: Link,
        to next: Link
    ) -> Bool {
        if case .offline = previous, case .online = next {
            return true
        }
        return false
    }
}
