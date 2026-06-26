nonisolated enum ConnectionCoordination {
    static func didReconnect(
        from previous: ConnectionFeature.Connectivity,
        to next: ConnectionFeature.Connectivity
    ) -> Bool {
        next == .connected && previous != .connected
    }

    static func caption(for connectivity: ConnectionFeature.Connectivity) -> String {
        switch connectivity {
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnected:
            "Not connected"
        }
    }
}
