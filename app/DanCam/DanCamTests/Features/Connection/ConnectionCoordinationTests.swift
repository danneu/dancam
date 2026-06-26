import Testing
@testable import DanCam

struct ConnectionCoordinationTests {
    @Test func didReconnectOnlyWhenEnteringConnected() {
        let cases: [(ConnectionFeature.Connectivity, ConnectionFeature.Connectivity, Bool)] = [
            (.connecting, .connected, true),
            (.disconnected, .connected, true),
            (.connected, .connected, false),
            (.connected, .disconnected, false),
            (.disconnected, .disconnected, false),
            (.connecting, .disconnected, false),
        ]

        for (previous, next, expected) in cases {
            #expect(ConnectionCoordination.didReconnect(from: previous, to: next) == expected)
        }
    }

    @Test func captionsMatchConnectivityStates() {
        #expect(ConnectionCoordination.caption(for: .connecting) == "Connecting")
        #expect(ConnectionCoordination.caption(for: .connected) == "Connected")
        #expect(ConnectionCoordination.caption(for: .disconnected) == "Not connected")
    }
}
