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
