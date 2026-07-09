import Foundation
import Testing
@testable import DanCam

struct HomeSectionsTests {
    @Test func datedClipsGroupByDayWithoutSorting() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let now = clock.now
        let jan3Morning = try date(year: 2026, month: 1, day: 3, hour: 10, calendar: calendar)
        let jan3Earlier = try date(year: 2026, month: 1, day: 3, hour: 9, calendar: calendar)
        let jan2Night = try date(year: 2026, month: 1, day: 2, hour: 23, calendar: calendar)
        let jan3Start = calendar.startOfDay(for: jan3Morning)
        let jan2Start = calendar.startOfDay(for: jan2Night)

        let sections = compose(
            clips: [
                datedClip(id: 5, date: jan3Morning),
                datedClip(id: 4, date: jan3Earlier),
                datedClip(id: 3, date: jan2Night),
            ],
            now: now,
            today: jan3Morning,
            calendar: calendar
        )

        #expect(sections.map(\.id) == [
            .day(startOfDay: jan3Start, occurrence: 0),
            .day(startOfDay: jan2Start, occurrence: 0),
        ])
        #expect(sections.map(rowIDs) == [
            [.finished(5), .finished(4)],
            [.finished(3)],
        ])
    }

    @Test func undatedRunsStayInPlaceBetweenDatedRuns() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let yesterday = try date(year: 2026, month: 1, day: 2, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                datedClip(id: 5, date: today),
                approximateClip(id: 4, date: today),
                undatedClip(id: 3),
                datedClip(id: 2, date: yesterday),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        )

        #expect(sections.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: today), occurrence: 0),
            .dateUnknown(occurrence: 0),
            .day(startOfDay: calendar.startOfDay(for: yesterday), occurrence: 0),
        ])
        #expect(sections.map(rowIDs) == [
            [.finished(5)],
            [.finished(4), .finished(3)],
            [.finished(2)],
        ])
    }

    @Test func stampedRunCollapsesToOneDriveCardWithNewestFirstClips() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a"),
                stampedDatedClip(id: 4, date: today, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        )
        let drive = try requireDrive(sections.first?.rows.first)

        #expect(sections.map(rowIDs) == [[.drive(bootTag: "boot-a", occurrence: 0)]])
        #expect(drive.bootTag == "boot-a")
        #expect(drive.clips.map(\.id) == [5, 4])
        #expect(drive.representative?.id == 4)
    }

    @Test func singleStampedClipIsStillADriveCard() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [stampedDatedClip(id: 5, date: today, bootTag: "boot-a")],
            now: clock.now,
            today: today,
            calendar: calendar
        )

        #expect(sections.map(rowIDs) == [[.drive(bootTag: "boot-a", occurrence: 0)]])
    }

    @Test func bareClipsStayFlatBetweenStampedDriveCards() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, bootTag: "boot-a"),
                datedClip(id: 5, date: today),
                stampedDatedClip(id: 4, date: today, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        )

        #expect(sections.map(rowIDs) == [[
            .drive(bootTag: "boot-a", occurrence: 0),
            .finished(5),
            .drive(bootTag: "boot-a", occurrence: 1),
        ]])
    }

    @Test func adjacentDifferentBootTagsBecomeDistinctCards() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, bootTag: "boot-b"),
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        )

        #expect(sections.map(rowIDs) == [[
            .drive(bootTag: "boot-b", occurrence: 0),
            .drive(bootTag: "boot-a", occurrence: 0),
        ]])
    }

    @Test func midnightSpanningDriveUsesDistinctOccurrencesAcrossDaySections() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let jan3 = try date(year: 2026, month: 1, day: 3, hour: 0, minute: 1, calendar: calendar)
        let jan2 = try date(year: 2026, month: 1, day: 2, hour: 23, minute: 59, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: jan3, bootTag: "boot-a"),
                stampedDatedClip(id: 5, date: jan2, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: jan3,
            calendar: calendar
        )

        #expect(sections.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: jan3), occurrence: 0),
            .day(startOfDay: calendar.startOfDay(for: jan2), occurrence: 0),
        ])
        #expect(sections.map(rowIDs) == [
            [.drive(bootTag: "boot-a", occurrence: 0)],
            [.drive(bootTag: "boot-a", occurrence: 1)],
        ])
    }

    @Test func undatedStampedDriveGroupsInDateUnknown() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedUndatedClip(id: 6, bootTag: "boot-a"),
                stampedUndatedClip(id: 5, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        )

        #expect(sections.map(\.id) == [.dateUnknown(occurrence: 0)])
        #expect(sections.map(rowIDs) == [[.drive(bootTag: "boot-a", occurrence: 0)]])
    }

    @Test func splitRunsUseDistinctOccurrences() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let todayMorning = try date(year: 2026, month: 1, day: 3, hour: 9, calendar: calendar)
        let todayAfternoon = try date(year: 2026, month: 1, day: 3, hour: 15, calendar: calendar)
        let todayStart = calendar.startOfDay(for: todayMorning)

        let sections = compose(
            clips: [
                datedClip(id: 6, date: todayMorning),
                undatedClip(id: 5),
                datedClip(id: 4, date: todayAfternoon),
                undatedClip(id: 3),
            ],
            now: clock.now,
            today: todayMorning,
            calendar: calendar
        )
        let ids = sections.map(\.id)

        #expect(ids == [
            .day(startOfDay: todayStart, occurrence: 0),
            .dateUnknown(occurrence: 0),
            .day(startOfDay: todayStart, occurrence: 1),
            .dateUnknown(occurrence: 1),
        ])
        #expect(Set(ids).count == ids.count)
    }

    @Test func liveAndPendingRowsStayStandaloneAboveDriveCards() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let now = clock.now
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let clips = [
            stampedDatedClip(id: 6, date: today, bootTag: "boot-a"),
            stampedDatedClip(id: 5, date: today, bootTag: "boot-a"),
        ]

        let liveSections = compose(
            clips: clips,
            recorder: .live(recorder(currentSegment: RecorderSegment(id: 99, durMs: nil))),
            now: now,
            today: today,
            calendar: calendar
        )
        #expect(liveSections.map(rowIDs) == [[
            .live(session: 7, id: 99),
            .drive(bootTag: "boot-a", occurrence: 0),
        ]])

        let pendingSections = compose(
            clips: clips,
            recording: .recording,
            recorder: .live(recorder(phase: .recording, currentSegment: nil)),
            now: now,
            today: today,
            calendar: calendar
        )
        #expect(pendingSections.map(rowIDs) == [[
            .pending,
            .drive(bootTag: "boot-a", occurrence: 0),
        ]])
    }

    @Test func liveRowUsesTodaySection() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let now = clock.now
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let yesterday = try date(year: 2026, month: 1, day: 2, hour: 12, calendar: calendar)
        let live = LiveSegment(sessionId: 7, id: 99, elapsed: .ticking(seedDurMs: nil, anchor: now))
        let recorderTruth = RecorderTruth.live(recorder(currentSegment: RecorderSegment(id: 99, durMs: nil)))

        let existingToday = compose(
            clips: [datedClip(id: 5, date: today)],
            recorder: recorderTruth,
            now: now,
            today: today,
            calendar: calendar
        )
        #expect(existingToday.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: today), occurrence: 0),
        ])
        #expect(existingToday.map(rowIDs) == [
            [.live(session: live.sessionId, id: live.id), .finished(5)],
        ])

        let olderNewest = compose(
            clips: [datedClip(id: 4, date: yesterday)],
            recorder: recorderTruth,
            now: now,
            today: today,
            calendar: calendar
        )
        #expect(olderNewest.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: today), occurrence: 0),
            .day(startOfDay: calendar.startOfDay(for: yesterday), occurrence: 0),
        ])
        #expect(olderNewest.map(rowIDs) == [
            [.live(session: live.sessionId, id: live.id)],
            [.finished(4)],
        ])

        let undatedNewest = compose(
            clips: [undatedClip(id: 3)],
            recorder: recorderTruth,
            now: now,
            today: today,
            calendar: calendar
        )
        #expect(undatedNewest.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: today), occurrence: 0),
            .dateUnknown(occurrence: 0),
        ])
        #expect(undatedNewest.map(rowIDs) == [
            [.live(session: live.sessionId, id: live.id)],
            [.finished(3)],
        ])
    }

    @Test func pendingRowUsesTodaySection() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let yesterday = try date(year: 2026, month: 1, day: 2, hour: 12, calendar: calendar)
        let recorderTruth = RecorderTruth.live(recorder(phase: .recording, currentSegment: nil))

        let existingToday = compose(
            clips: [datedClip(id: 5, date: today)],
            recording: .recording,
            recorder: recorderTruth,
            now: clock.now,
            today: today,
            calendar: calendar
        )
        #expect(existingToday.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: today), occurrence: 0),
        ])
        #expect(existingToday.map(rowIDs) == [
            [.pending, .finished(5)],
        ])

        let olderNewest = compose(
            clips: [datedClip(id: 4, date: yesterday)],
            recording: .recording,
            recorder: recorderTruth,
            now: clock.now,
            today: today,
            calendar: calendar
        )
        #expect(olderNewest.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: today), occurrence: 0),
            .day(startOfDay: calendar.startOfDay(for: yesterday), occurrence: 0),
        ])
        #expect(olderNewest.map(rowIDs) == [
            [.pending],
            [.finished(4)],
        ])

        let undatedNewest = compose(
            clips: [undatedClip(id: 3)],
            recording: .recording,
            recorder: recorderTruth,
            now: clock.now,
            today: today,
            calendar: calendar
        )
        #expect(undatedNewest.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: today), occurrence: 0),
            .dateUnknown(occurrence: 0),
        ])
        #expect(undatedNewest.map(rowIDs) == [
            [.pending],
            [.finished(3)],
        ])
    }

    @Test func runOccurrencesAreStableForTopPrependsAndBottomAppends() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let todayEarlier = try date(year: 2026, month: 1, day: 3, hour: 8, calendar: calendar)
        let yesterday = try date(year: 2026, month: 1, day: 2, hour: 12, calendar: calendar)
        let yesterdayEarlier = try date(year: 2026, month: 1, day: 2, hour: 8, calendar: calendar)

        let oldTopIDs = compose(
            clips: [datedClip(id: 4, date: today), undatedClip(id: 3), datedClip(id: 2, date: yesterday)],
            now: clock.now,
            today: today,
            calendar: calendar
        ).map(\.id)
        let newTopIDs = compose(
            clips: [
                datedClip(id: 5, date: today),
                datedClip(id: 4, date: todayEarlier),
                undatedClip(id: 3),
                datedClip(id: 2, date: yesterday),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        ).map(\.id)
        #expect(newTopIDs == oldTopIDs)

        let oldBottomIDs = compose(
            clips: [datedClip(id: 4, date: today), datedClip(id: 3, date: yesterday)],
            now: clock.now,
            today: today,
            calendar: calendar
        ).map(\.id)
        let newBottomIDs = compose(
            clips: [
                datedClip(id: 4, date: today),
                datedClip(id: 3, date: yesterday),
                datedClip(id: 2, date: yesterdayEarlier),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        ).map(\.id)
        #expect(newBottomIDs == oldBottomIDs)
    }

    @Test func driveOccurrencesAreStableAcrossSameDrivePrependAndAppend() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let earlier = try date(year: 2026, month: 1, day: 3, hour: 11, calendar: calendar)

        let oldTopIDs = compose(
            clips: [stampedDatedClip(id: 4, date: today, bootTag: "boot-a")],
            now: clock.now,
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        let newTopIDs = compose(
            clips: [
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a"),
                stampedDatedClip(id: 4, date: earlier, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        #expect(newTopIDs == oldTopIDs)

        let oldBottomIDs = compose(
            clips: [stampedDatedClip(id: 4, date: today, bootTag: "boot-a")],
            now: clock.now,
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        let newBottomIDs = compose(
            clips: [
                stampedDatedClip(id: 4, date: today, bootTag: "boot-a"),
                stampedDatedClip(id: 3, date: earlier, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        #expect(newBottomIDs == oldBottomIDs)
    }

    @Test func mixedDurationDriveOmitsAggregateDuration() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, durMs: 30_000, bootTag: "boot-a"),
                stampedDatedClip(id: 5, date: today, durMs: nil, bootTag: "boot-a"),
            ],
            now: clock.now,
            today: today,
            calendar: calendar
        )
        let drive = try requireDrive(sections.first?.rows.first)

        #expect(drive.totalDurMs == nil)
        #expect(Formatters.driveCardSubtitle(durationMs: drive.totalDurMs, clipCount: drive.clipCount) == "2 clips")
    }

    @Test func calendarTimeZoneControlsDayBoundaries() throws {
        let utcCalendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let plusTwoCalendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 2 * 60 * 60))
        let clock = ContinuousClock()
        let instant = try date(year: 2026, month: 1, day: 1, hour: 23, minute: 30, calendar: utcCalendar)
        let clip = datedClip(id: 7, date: instant)

        let utcSections = compose(
            clips: [clip],
            now: clock.now,
            today: instant,
            calendar: utcCalendar
        )
        let plusTwoSections = compose(
            clips: [clip],
            now: clock.now,
            today: instant,
            calendar: plusTwoCalendar
        )

        #expect(utcSections.map(\.id) == [
            .day(startOfDay: utcCalendar.startOfDay(for: instant), occurrence: 0),
        ])
        #expect(plusTwoSections.map(\.id) == [
            .day(startOfDay: plusTwoCalendar.startOfDay(for: instant), occurrence: 0),
        ])
        #expect(utcSections.map(\.id) != plusTwoSections.map(\.id))
    }

    @Test func emptyClipsWithoutLiveRowsReturnNoSections() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let clock = ContinuousClock()
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        #expect(compose(
            clips: [],
            recording: .idle,
            recorder: .unknown,
            now: clock.now,
            today: today,
            calendar: calendar
        ) == [])
    }

    private func compose(
        clips: [Clip],
        recording: RecordingFeature.State = .idle,
        recorder: RecorderTruth = .unknown,
        previousLive: LiveSegment? = nil,
        now: ContinuousClock.Instant,
        today: Date,
        calendar: Calendar
    ) -> [HomeSectionModel] {
        HomeRow.composeSections(
            clips: clips,
            recording: recording,
            recorder: recorder,
            previousLive: previousLive,
            now: now,
            today: today,
            calendar: calendar
        )
    }

    private func rowIDs(_ section: HomeSectionModel) -> [HomeRowID] {
        section.rows.map(\.id)
    }

    private func datedClip(id: Int, date: Date) -> Clip {
        CameraSamples.clip(
            id: id,
            startMs: UInt64((date.timeIntervalSince1970 * 1_000).rounded()),
            timeApproximate: false
        )
    }

    private func undatedClip(id: Int) -> Clip {
        CameraSamples.clip(id: id)
    }

    private func approximateClip(id: Int, date: Date) -> Clip {
        CameraSamples.clip(
            id: id,
            startMs: UInt64((date.timeIntervalSince1970 * 1_000).rounded()),
            timeApproximate: true
        )
    }

    private func stampedDatedClip(
        id: Int,
        date: Date,
        durMs: UInt64? = 30_000,
        bootTag: String
    ) -> Clip {
        CameraSamples.clip(
            id: id,
            startMs: UInt64((date.timeIntervalSince1970 * 1_000).rounded()),
            durMs: durMs,
            timeApproximate: false,
            bootTag: bootTag
        )
    }

    private func stampedUndatedClip(id: Int, bootTag: String) -> Clip {
        CameraSamples.clip(id: id, durMs: 30_000, bootTag: bootTag)
    }

    private func requireDrive(_ row: HomeRow?) throws -> DriveGroup {
        let row = try #require(row)
        guard case .drive(let drive) = row else {
            Issue.record("Expected a drive row.")
            return DriveGroup(bootTag: "", occurrence: -1, clips: [])
        }
        return drive
    }

    private func recorder(
        phase: RecorderPhase = .recording,
        session: UInt64 = 7,
        currentSegment: RecorderSegment?
    ) -> RecorderSnapshot {
        RecorderSnapshot(
            phase: phase,
            session: session,
            currentSegment: currentSegment,
            detail: nil
        )
    }

    private func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func timeZone(secondsFromGMT: Int) throws -> TimeZone {
        try #require(TimeZone(secondsFromGMT: secondsFromGMT))
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return try #require(calendar.date(from: components))
    }
}
