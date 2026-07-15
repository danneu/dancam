nonisolated enum Link: Equatable, Sendable {
    case suspended(last: World?)
    case connecting(last: World?)
    case online(World)
    case offline(last: World?)

    var recorderTruth: RecorderTruth {
        switch self {
        case .online(let world):
            .live(world.recorder)
        case .suspended(last: let world?),
             .connecting(last: let world?),
             .offline(last: let world?):
            .lastKnown(world.recorder)
        case .suspended(last: nil), .connecting(last: nil), .offline(last: nil):
            .unknown
        }
    }

    var world: World? {
        switch self {
        case .suspended(let last), .connecting(let last), .offline(let last):
            last
        case .online(let world):
            world
        }
    }

    var onlineWorld: World? {
        if case .online(let world) = self {
            return world
        }
        return nil
    }

    mutating func fold(_ event: CameraEvent) {
        if case .suspended = self { return }
        foldWhileActive(event)
    }

    private mutating func foldWhileActive(_ event: CameraEvent) {
        switch event {
        case .snapshot(let world):
            self = .online(world)
        default:
            guard case .online(let world) = self else { return }
            self = .online(World.folding(world, event))
        }
    }

    mutating func wentOffline() {
        if case .suspended = self { return }
        self = .offline(last: world)
    }

    mutating func suspend() {
        self = .suspended(last: world)
    }

    mutating func connect() {
        guard case .suspended(let last) = self else { return }
        self = .connecting(last: last)
    }
}

nonisolated enum RecorderTruth: Equatable, Sendable {
    case live(RecorderSnapshot)
    case lastKnown(RecorderSnapshot)
    case unknown
}
