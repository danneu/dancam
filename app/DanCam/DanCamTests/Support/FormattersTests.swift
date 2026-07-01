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

    @Test func clipDurationFormatsMillisecondsAsMinutesAndSeconds() {
        let cases: [(durMs: UInt64?, text: String?)] = [
            (nil, nil),
            (0, "0:00"),
            (5_000, "0:05"),
            (34_000, "0:34"),
            (34_700, "0:35"),
            (34_400, "0:34"),
            (94_000, "1:34"),
            (600_000, "10:00"),
            (6_000_000, "100:00"),
            (128_849_018_880_000, "2147483648:00"),
            (.max, "307445734561825:52"),
        ]

        for testCase in cases {
            #expect(Formatters.clipDuration(testCase.durMs) == testCase.text)
        }
    }

    @Test func clipMetadataCombinesDurationAndByteSize() {
        #expect(Formatters.clipMetadata(durMs: 34_000, bytes: 1_000) == "0:34 · 1 KB")
        #expect(Formatters.clipMetadata(durMs: nil, bytes: 1_000) == "1 KB")
    }

    @Test func countUpDurationFloorsSeconds() {
        let cases: [(durMs: UInt64, text: String)] = [
            (0, "0:00"),
            (999, "0:00"),
            (1_000, "0:01"),
            (59_999, "0:59"),
            (60_000, "1:00"),
            (600_000, "10:00"),
        ]

        for testCase in cases {
            #expect(Formatters.countUpDuration(testCase.durMs) == testCase.text)
        }
    }
}
