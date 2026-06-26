import Testing
@testable import DanCam

struct HealthTelemetryTests {
    @Test func loadedStateRendersAllTelemetryRows() {
        let rows = HealthTelemetry.rows(for: .loaded(StatusResponse(
            recording: true,
            cameraState: .running,
            bootId: "boot-123",
            uptimeS: 42,
            storage: Storage(used: 1_000, total: 4_000),
            tempC: TempC(soc: 51.2, sensor: 52.3),
            mem: Mem(total: 1_000_000, available: 500_000, swapTotal: 0, swapUsed: 1_000)
        )))

        #expect(rows.map { $0.label } == [
            "SoC temp",
            "Camera temp",
            "Storage used",
            "Storage total",
            "Storage free",
            "Memory total",
            "Memory available",
            "Swap total",
            "Swap used",
        ])
        #expect(rows.map { $0.value } == [
            "51.2 C",
            "52.3 C",
            "1 KB",
            "4 KB",
            "3 KB",
            "1 MB",
            "500 KB",
            "Zero KB",
            "1 KB",
        ])
    }

    @Test func loadedStateRendersPlaceholdersForMissingTelemetry() {
        let rows = HealthTelemetry.rows(for: .loaded(StatusResponse(
            recording: false,
            cameraState: .running,
            bootId: "boot-123",
            uptimeS: 42,
            storage: nil,
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil
        )))

        #expect(rows.map { $0.value } == Array(repeating: "--", count: 9))
    }

    @Test func nonLoadedStatesRenderPlaceholders() {
        let states: [StatusFeature.State] = [
            .idle,
            .loading,
            .failed("lost"),
        ]

        for state in states {
            let rows = HealthTelemetry.rows(for: state)

            #expect(rows.map { $0.value } == Array(repeating: "--", count: 9))
        }
    }
}
