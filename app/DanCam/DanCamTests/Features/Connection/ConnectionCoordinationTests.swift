import Testing
@testable import DanCam

struct ConnectionCoordinationTests {
    @Test func presentationMapsCaptionAndTone() {
        let cases: [(ConnectionFeature.Connectivity, ConnectionCoordination.StripPresentation)] = [
            (.connecting, .init(caption: "Connecting", tone: .neutral)),
            (.connected, .init(caption: "Connected", tone: .positive)),
            (.disconnected, .init(caption: "Not connected", tone: .negative)),
        ]

        for (connectivity, expected) in cases {
            #expect(ConnectionCoordination.presentation(for: connectivity) == expected)
        }
    }

    @Test func resumesLiveWorkOnlyFromDisconnected() {
        let cases: [(ConnectionFeature.Connectivity, ConnectionFeature.Connectivity, Bool)] = [
            (.disconnected, .connected, true),
            (.connecting, .connected, false),
            (.connected, .connected, false),
            (.connected, .disconnected, false),
            (.disconnected, .disconnected, false),
            (.connecting, .disconnected, false),
        ]

        for (previous, next, expected) in cases {
            #expect(ConnectionCoordination.shouldResumeLiveWork(from: previous, to: next) == expected)
        }
    }
}
