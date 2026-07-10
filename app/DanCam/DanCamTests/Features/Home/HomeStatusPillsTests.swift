import Testing
@testable import DanCam

struct HomeStatusPillsTests {
    @Test func normalRunningWorldHasNoPills() {
        let pills = HomeStatusPills.from(CameraSamples.world(
            cameraState: .running,
            tempC: TempC(
                soc: TempReading(current: 42),
                sensor: TempReading(current: 45)
            )
        ))

        #expect(pills == HomeStatusPills(tempWarning: nil, cameraOffline: false))
    }

    @Test func nonPillWorldChangesProduceEqualPills() {
        let first = HomeStatusPills.from(CameraSamples.world(
            phase: .idle,
            cameraState: .running,
            storage: Storage(used: 100, total: 1_000),
            tempC: TempC(
                soc: TempReading(current: 40),
                sensor: TempReading(current: 45)
            ),
            mem: Mem(total: 1_000, available: 900, swapTotal: 0, swapUsed: 0),
            uptimeS: 1
        ))
        let second = HomeStatusPills.from(CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 8, durMs: nil),
            cameraState: .starting,
            storage: Storage(used: 500, total: 2_000),
            tempC: TempC(
                soc: TempReading(current: 99),
                sensor: TempReading(current: 45)
            ),
            mem: Mem(total: 2_000, available: 1_800, swapTotal: 100, swapUsed: 1),
            uptimeS: 999
        ))

        #expect(first == second)
    }

    @Test func warningCaptionDeduplicatesAtDisplayGranularity() {
        let first = HomeStatusPills.from(CameraSamples.world(
            tempC: TempC(sensor: TempReading(current: 52.1))
        ))
        let second = HomeStatusPills.from(CameraSamples.world(
            tempC: TempC(sensor: TempReading(current: 52.4))
        ))

        #expect(first == second)
        #expect(first.tempWarning == HomeStatusPills.Warning(caption: "52 C camera", isCritical: false))
    }

    @Test func sensorThresholdsProduceWarnAndCriticalPills() throws {
        let warn = try #require(HomeStatusPills.from(CameraSamples.world(
            tempC: TempC(sensor: TempReading(current: Formatters.sensorWarnThreshold))
        )).tempWarning)
        let critical = try #require(HomeStatusPills.from(CameraSamples.world(
            tempC: TempC(sensor: TempReading(current: Formatters.sensorCriticalThreshold))
        )).tempWarning)

        #expect(warn.isCritical == false)
        #expect(critical.isCritical == true)
    }

    @Test func maxTemperatureNeverProducesAHomeWarning() {
        let noCurrent = HomeStatusPills.from(CameraSamples.world(
            tempC: TempC(sensor: TempReading(max: Formatters.sensorCriticalThreshold))
        ))
        let safeCurrent = HomeStatusPills.from(CameraSamples.world(
            tempC: TempC(sensor: TempReading(
                current: Formatters.sensorWarnThreshold - 0.1,
                max: Formatters.sensorCriticalThreshold
            ))
        ))

        #expect(noCurrent.tempWarning == nil)
        #expect(safeCurrent.tempWarning == nil)
    }

    @Test func offlineAndNilWorldProduceExpectedPills() {
        #expect(HomeStatusPills.from(CameraSamples.world(cameraState: .offline)).cameraOffline == true)
        #expect(HomeStatusPills.from(nil) == HomeStatusPills(tempWarning: nil, cameraOffline: false))
    }

    @Test func timeUnverifiedTracksConnectedWorldTimeState() {
        #expect(HomeStatusPills.from(nil).timeUnverified == false)
        #expect(HomeStatusPills.from(CameraSamples.world(time: nil)).timeUnverified == true)
        #expect(HomeStatusPills.from(CameraSamples.world(time: TimeStatus(synced: false))).timeUnverified == true)
        #expect(HomeStatusPills.from(CameraSamples.world(time: TimeStatus(synced: true))).timeUnverified == false)
    }
}
