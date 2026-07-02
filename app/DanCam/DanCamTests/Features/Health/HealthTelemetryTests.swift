import Testing
@testable import DanCam

struct HealthTelemetryTests {
    @Test func loadedStateRendersAllTelemetryRows() {
        let rows = HealthTelemetry.rows(for: CameraSamples.world(
            phase: .recording,
            storage: Storage(used: 1_000, total: 4_000),
            tempC: TempC(soc: 51.2, sensor: 52.3),
            mem: Mem(total: 1_000_000, available: 500_000, swapTotal: 0, swapUsed: 1_000),
            uptimeS: 42
        ))

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
        let rows = HealthTelemetry.rows(for: CameraSamples.world(
            storage: nil,
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil,
            uptimeS: 42
        ))

        #expect(rows.map { $0.value } == Array(repeating: "--", count: 9))
    }

    @Test func nilWorldRendersPlaceholders() {
        let rows = HealthTelemetry.rows(for: nil)

        #expect(rows.map { $0.value } == Array(repeating: "--", count: 9))
    }

    @Test func nonRenderedWorldChangesProduceEqualRows() {
        let first = CameraSamples.world(
            phase: .idle,
            cameraState: .running,
            storage: Storage(used: 1_000, total: 4_000),
            tempC: TempC(soc: 51.2, sensor: 52.3),
            mem: Mem(total: 1_000_000, available: 500_000, swapTotal: 0, swapUsed: 1_000),
            uptimeS: 42
        )
        var second = first
        second.recorder.phase = .recording
        second.recorder.currentSegment = RecorderSegment(id: 8, durMs: 1_000)
        second.cameraState = .offline
        second.bootId = "boot-456"
        second.uptimeS = 9_999

        #expect(HealthTelemetry.rows(for: first) == HealthTelemetry.rows(for: second))
    }

    @Test func rawTelemetryDriftThatFormatsTheSameProducesEqualRows() {
        let first = CameraSamples.world(
            storage: Storage(used: 1_000, total: 4_000),
            tempC: TempC(soc: 51.21, sensor: 52.31),
            mem: Mem(total: 1_000_000, available: 500_000, swapTotal: 0, swapUsed: 1_000)
        )
        let second = CameraSamples.world(
            storage: Storage(used: 1_001, total: 4_001),
            tempC: TempC(soc: 51.24, sensor: 52.34),
            mem: Mem(total: 1_000_001, available: 500_001, swapTotal: 0, swapUsed: 1_001)
        )

        #expect(HealthTelemetry.rows(for: first) == HealthTelemetry.rows(for: second))
    }

    @Test func renderedTelemetryStringChangeProducesDifferentRows() {
        let first = CameraSamples.world(
            mem: Mem(total: 1_000_000, available: 500_000, swapTotal: 0, swapUsed: 1_000)
        )
        let second = CameraSamples.world(
            mem: Mem(total: 1_000_000, available: 1_500_000, swapTotal: 0, swapUsed: 1_000)
        )

        #expect(HealthTelemetry.rows(for: first) != HealthTelemetry.rows(for: second))
    }
}
