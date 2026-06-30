import Testing
@testable import DanCam

struct ConnectionCoordinationTests {
    @Test func presentationMapsCaptionAndTone() {
        let world = CameraSamples.world()
        let cases: [(Link, ConnectionCoordination.StripPresentation)] = [
            (.connecting, .init(caption: "Connecting", tone: .neutral)),
            (.online(world), .init(caption: "Connected", tone: .positive)),
            (.offline(last: world), .init(caption: "Not connected", tone: .negative)),
        ]

        for (link, expected) in cases {
            #expect(ConnectionCoordination.presentation(for: link) == expected)
        }
    }

    @Test func resumesLiveWorkOnlyFromOfflineToOnline() {
        let world = CameraSamples.world()
        let cases: [(Link, Link, Bool)] = [
            (.offline(last: world), .online(world), true),
            (.connecting, .online(world), false),
            (.online(world), .online(world), false),
            (.online(world), .offline(last: world), false),
            (.offline(last: world), .offline(last: world), false),
            (.connecting, .offline(last: nil), false),
        ]

        for (previous, next, expected) in cases {
            #expect(ConnectionCoordination.shouldResumeLiveWork(from: previous, to: next) == expected)
        }
    }
}
