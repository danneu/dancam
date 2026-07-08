nonisolated enum Link: Equatable {
    case connecting
    case online(World)
    case offline(last: World?)

    var recorderTruth: RecorderTruth {
        switch self {
        case .online(let world):
            .live(world.recorder)
        case .offline(last: let world?):
            .lastKnown(world.recorder)
        case .offline(last: nil), .connecting:
            .unknown
        }
    }

    var world: World? {
        switch self {
        case .connecting:
            nil
        case .online(let world):
            world
        case .offline(let last):
            last
        }
    }

    var onlineWorld: World? {
        if case .online(let world) = self {
            return world
        }
        return nil
    }

    mutating func fold(_ event: CameraEvent) {
        switch event {
        case .snapshot(let world):
            self = .online(world)
        default:
            guard case .online(let world) = self else { return }
            self = .online(World.folding(world, event))
        }
    }

    mutating func wentOffline() {
        self = .offline(last: world)
    }
}

nonisolated enum RecorderTruth: Equatable, Sendable {
    case live(RecorderSnapshot)
    case lastKnown(RecorderSnapshot)
    case unknown
}
