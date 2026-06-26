import Foundation
import Testing
@testable import DanCam

struct FormattersTests {
    @Test func storageDisplayFormatsFreeSpaceAndUsedFraction() {
        let display = Formatters.storageDisplay(Storage(used: 4_000, total: 10_000))

        #expect(display.freeText == "6 KB")
        #expect(abs(display.usedFraction - 0.4) < 0.0001)
    }

    @Test func storageDisplayGuardsZeroTotal() {
        let display = Formatters.storageDisplay(Storage(used: 1_000, total: 0))

        #expect(display.freeText == "Zero KB")
        #expect(display.usedFraction == 0)
    }

    @Test func storageDisplayClampsUsedGreaterThanTotal() {
        let display = Formatters.storageDisplay(Storage(used: 2_000, total: 1_000))

        #expect(display.freeText == "Zero KB")
        #expect(display.usedFraction == 1)
    }

    @Test func sensorWarningUsesSensorThresholdsOnly() {
        let cases: [(sensor: Double?, warning: TempWarning?)] = [
            (nil, nil),
            (49.9, nil),
            (50, .warn),
            (54.9, .warn),
            (55, .critical),
        ]

        for testCase in cases {
            #expect(Formatters.sensorWarning(for: testCase.sensor) == testCase.warning)
        }
    }

    @Test func temperatureFormatsRoundedAndPreciseVariants() {
        #expect(Formatters.temperature(52.3) == "52 C")
        #expect(Formatters.temperature(52.6) == "53 C")
        #expect(Formatters.temperature(52.3, precise: true) == "52.3 C")
    }

    @Test func byteSizeFormatsKnownCounts() {
        #expect(Formatters.byteSize(0) == "Zero KB")
        #expect(Formatters.byteSize(1_000) == "1 KB")
        #expect(Formatters.byteSize(1_536) == "2 KB")
    }
}
