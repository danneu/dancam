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

    @Test func memoryDisplayFormatsUsedMemoryAndFraction() throws {
        let display = try #require(
            Formatters.memoryDisplay(
                Mem(total: 512_000_000, available: 100_000_000, swapTotal: 0, swapUsed: 0)
            )
        )

        #expect(display.detailText == "412 MB of 512 MB")
        #expect(abs(display.usedFraction - 0.804_687_5) < 0.000_000_1)
    }

    @Test func memoryDisplayClampsAvailableGreaterThanTotal() throws {
        let display = try #require(
            Formatters.memoryDisplay(
                Mem(total: 512_000_000, available: 600_000_000, swapTotal: 0, swapUsed: 0)
            )
        )

        #expect(display.detailText == "Zero KB of 512 MB")
        #expect(display.usedFraction == 0)
    }

    @Test func memoryDisplayGuardsZeroTotal() {
        let display = Formatters.memoryDisplay(
            Mem(total: 0, available: 0, swapTotal: 0, swapUsed: 0)
        )

        #expect(display == nil)
    }

    @Test func swapDisplayFormatsAndClampsUsage() throws {
        let cases: [(swapUsed: UInt64, detailText: String, usedFraction: Double)] = [
            (128_000_000, "128 MB of 256 MB", 0.5),
            (300_000_000, "256 MB of 256 MB", 1),
        ]

        for testCase in cases {
            let display = try #require(
                Formatters.swapDisplay(
                    Mem(
                        total: 512_000_000,
                        available: 100_000_000,
                        swapTotal: 256_000_000,
                        swapUsed: testCase.swapUsed
                    )
                )
            )

            #expect(display.detailText == testCase.detailText)
            #expect(display.usedFraction == testCase.usedFraction)
        }
    }

    @Test func swapDisplayGuardsZeroTotal() {
        let display = Formatters.swapDisplay(
            Mem(total: 512_000_000, available: 100_000_000, swapTotal: 0, swapUsed: 0)
        )

        #expect(display == nil)
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

    @Test(arguments: [
        (value: 69.9, expected: TempWarning?.none),
        (value: 70.0, expected: TempWarning?.some(.warn)),
        (value: 79.9, expected: TempWarning?.some(.warn)),
        (value: 80.0, expected: TempWarning?.some(.critical)),
    ])
    func socWarningUsesInclusiveSocThresholds(value: Double, expected: TempWarning?) {
        #expect(Formatters.socWarning(for: value) == expected)
    }

    @Test func temperatureFormatsRoundedAndPreciseVariants() {
        #expect(Formatters.temperature(52.3) == "52 C")
        #expect(Formatters.temperature(52.6) == "53 C")
        #expect(Formatters.temperature(52.3, precise: true) == "52.3 C")
    }

    @Test func temperatureNumberFormatsWithoutUnit() {
        #expect(Formatters.temperatureNumber(62.54) == "62.5")
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

    @Test func clipTimeOfDayUsesTrustedTimesOnly() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let cases: [(clip: Clip, text: String?)] = [
            (
                clip(id: 1, startMs: 1_767_276_151_000, timeApproximate: false),
                "14:02:31"
            ),
            (
                clip(id: 7, startMs: 1_767_276_151_000, timeApproximate: true),
                nil
            ),
            (
                clip(id: 8, startMs: nil, timeApproximate: false),
                nil
            ),
        ]

        for testCase in cases {
            #expect(Formatters.clipTimeOfDay(testCase.clip, timeZone: utc) == testCase.text)
        }
    }

    @Test func timeOfDayShortFormatsHourAndMinuteOnly() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        let start = try date(2026, 1, 1, hour: 14, minute: 2, second: 31, calendar: calendar)

        #expect(Formatters.timeOfDayShort(start, timeZone: utc) == "14:02")
    }

    @Test func timeSpanFormatsSameDayAndCrossMidnightRanges() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        let sameDayStart = try date(2026, 1, 1, hour: 14, minute: 2, calendar: calendar)
        let sameDayEnd = try date(2026, 1, 1, hour: 15, minute: 37, calendar: calendar)
        let crossMidnightStart = try date(2026, 1, 1, hour: 23, minute: 58, calendar: calendar)
        let crossMidnightEnd = try date(2026, 1, 2, hour: 0, minute: 2, calendar: calendar)

        #expect(Formatters.timeSpan(start: sameDayStart, end: sameDayEnd, timeZone: utc) == "14:02 - 15:37")
        #expect(Formatters.timeSpan(start: crossMidnightStart, end: crossMidnightEnd, timeZone: utc) == "23:58 - 00:02")
    }

    @Test func dayHeaderFormatsRelativeAndCalendarDates() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        let now = try date(2026, 1, 3, hour: 12, calendar: calendar)

        let cases: [(dayStart: Date, text: String)] = [
            (try date(2026, 1, 3, calendar: calendar), "Today"),
            (try date(2026, 1, 2, calendar: calendar), "Yesterday"),
            (try date(2026, 1, 1, calendar: calendar), "Thursday, Jan 1"),
            (try date(2025, 12, 31, calendar: calendar), "Wednesday, Dec 31, 2025"),
        ]

        for testCase in cases {
            #expect(Formatters.dayHeader(testCase.dayStart, now: now, calendar: calendar) == testCase.text)
        }
    }

    @Test func clipDetailLinePrefixesTrustedCreatedTime() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let trusted = clip(id: 1, startMs: 1_767_225_600_000, timeApproximate: false)
        let approximate = clip(id: 2, startMs: 1_767_225_600_000, timeApproximate: true)

        #expect(Formatters.clipDetailLine(trusted, timeZone: utc) == "2026-01-01 00:00:00 · 00:30 · 1 byte")
        #expect(Formatters.clipDetailLine(approximate, timeZone: utc) == "00:30 · 1 byte")
    }

    @Test func clipListLinePrefixesTrustedTimeOfDayWithoutByteSize() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let trusted = clip(id: 1, startMs: 1_767_225_600_000, timeApproximate: false)
        let approximate = clip(id: 2, startMs: 1_767_225_600_000, timeApproximate: true)

        #expect(Formatters.clipListLine(trusted, timeZone: utc) == "00:00:00 · 00:30")
        #expect(Formatters.clipListLine(approximate, timeZone: utc) == "00:30")
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

    @Test func approximateDurationPrefixesFlooredMinutesAndSeconds() {
        let cases: [(durMs: UInt64, text: String)] = [
            (0, "~00:00"),
            (999, "~00:00"),
            (1_000, "~00:01"),
            (94_000, "~01:34"),
            (600_000, "~10:00"),
        ]

        for testCase in cases {
            #expect(Formatters.approximateDuration(testCase.durMs) == testCase.text)
        }
    }

    @Test func compactDurationFormatsSecondsMinutesHoursAndDays() {
        let cases: [(durMs: UInt64, text: String)] = [
            (0, "0s"),
            (59_000, "59s"),
            (60_000, "1m"),
            (3_599_000, "59m"),
            (3_600_000, "1h"),
            (4_860_000, "1h 21m"),
            (200_000_000, "2d 7h 33m"),
        ]

        for testCase in cases {
            #expect(Formatters.compactDuration(testCase.durMs) == testCase.text)
        }
    }

    @Test func uptimeFormatsElapsedSeconds() {
        let cases: [(seconds: UInt64, text: String)] = [
            (45, "45s"),
            (3_725, "1h 2m"),
            (200_000, "2d 7h 33m"),
        ]

        for testCase in cases {
            #expect(Formatters.uptime(testCase.seconds) == testCase.text)
        }
    }

    @Test func clipCountFormatsSingularAndPluralCounts() {
        let cases: [(count: Int, text: String)] = [
            (0, "0 clips"),
            (1, "1 clip"),
            (2, "2 clips"),
        ]

        for testCase in cases {
            #expect(Formatters.clipCount(testCase.count) == testCase.text)
        }
    }

    @Test func recordingCardTitleUsesSpanOrUndatedFallback() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        let start = try date(2026, 1, 1, hour: 14, minute: 2, calendar: calendar)
        let end = try date(2026, 1, 1, hour: 15, minute: 37, calendar: calendar)

        #expect(Formatters.recordingCardTitle(start: start, end: end, timeZone: utc) == "14:02 - 15:37")
        #expect(Formatters.recordingCardTitle(start: nil, end: end, timeZone: utc) == "Recording")
        #expect(Formatters.recordingCardTitle(start: start, end: nil, timeZone: utc) == "Recording")
        #expect(Formatters.recordingCardTitle(start: nil, end: nil, timeZone: utc) == "Recording")
    }

    @Test func recordingCardSubtitleOmitsUnknownDurationAndFormatsClipCount() {
        #expect(Formatters.recordingCardSubtitle(durationMs: 4_860_000, clipCount: 163) == "1h 21m · 163 clips")
        #expect(Formatters.recordingCardSubtitle(durationMs: nil, clipCount: 3) == "3 clips")
        #expect(Formatters.recordingCardSubtitle(durationMs: 30_000, clipCount: 1) == "30s · 1 clip")
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

    private func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try #require(
            DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            ).date
        )
    }
}
