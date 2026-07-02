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
            (0, "00:00"),
            (5_000, "00:05"),
            (34_000, "00:34"),
            (34_700, "00:35"),
            (34_400, "00:34"),
            (94_000, "01:34"),
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
        #expect(Formatters.clipMetadata(durMs: 34_000, bytes: 1_000) == "00:34 · 1 KB")
        #expect(Formatters.clipMetadata(durMs: nil, bytes: 1_000) == "1 KB")
    }

    @Test func clipExportFilenameUsesTrustedTimesOnly() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let cases: [(clip: Clip, filename: String)] = [
            (
                clip(id: 1, startMs: 0, timeApproximate: false),
                "Dashcam 1970-01-01 00-00-00.mp4"
            ),
            (
                clip(id: 7, startMs: 0, timeApproximate: true),
                "Dashcam seg_00007.mp4"
            ),
            (
                clip(id: 8, startMs: nil, timeApproximate: false),
                "Dashcam seg_00008.mp4"
            ),
            (
                clip(id: 123_456, startMs: nil, timeApproximate: false),
                "Dashcam seg_123456.mp4"
            ),
        ]

        for testCase in cases {
            #expect(Formatters.clipExportFilename(testCase.clip, timeZone: utc) == testCase.filename)
        }
    }

    @Test func clipCreatedTimeUsesTrustedTimesOnly() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let cases: [(clip: Clip, text: String?)] = [
            (
                clip(id: 1, startMs: 1_767_225_600_000, timeApproximate: false),
                "2026-01-01 00:00:00"
            ),
            (
                clip(id: 7, startMs: 1_767_225_600_000, timeApproximate: true),
                nil
            ),
            (
                clip(id: 8, startMs: nil, timeApproximate: false),
                nil
            ),
        ]

        for testCase in cases {
            #expect(Formatters.clipCreatedTime(testCase.clip, timeZone: utc) == testCase.text)
        }
    }

    @Test func clipDetailLinePrefixesTrustedCreatedTime() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let trusted = clip(id: 1, startMs: 1_767_225_600_000, timeApproximate: false)
        let approximate = clip(id: 2, startMs: 1_767_225_600_000, timeApproximate: true)

        #expect(Formatters.clipDetailLine(trusted, timeZone: utc) == "2026-01-01 00:00:00 · 00:30 · 1 byte")
        #expect(Formatters.clipDetailLine(approximate, timeZone: utc) == "00:30 · 1 byte")
    }

    @Test func countUpDurationFloorsSeconds() {
        let cases: [(durMs: UInt64, text: String)] = [
            (0, "00:00"),
            (999, "00:00"),
            (1_000, "00:01"),
            (59_999, "00:59"),
            (60_000, "01:00"),
            (600_000, "10:00"),
        ]

        for testCase in cases {
            #expect(Formatters.countUpDuration(testCase.durMs) == testCase.text)
        }
    }

    private func clip(
        id: Int,
        startMs: UInt64?,
        timeApproximate: Bool
    ) -> Clip {
        Clip(
            id: id,
            startMs: startMs,
            durMs: 30_000,
            bytes: 1,
            locked: false,
            etag: "etag",
            timeApproximate: timeApproximate
        )
    }
}
