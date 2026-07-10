import Foundation
import Testing
@testable import DanCam

struct HomeSectionsTests {
    @Test func datedClipsGroupByDayWithoutSorting() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
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
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let yesterday = try date(year: 2026, month: 1, day: 2, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                datedClip(id: 5, date: today),
                approximateClip(id: 4, date: today),
                undatedClip(id: 3),
                datedClip(id: 2, date: yesterday),
            ],
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

    @Test func stampedRunCollapsesToOneRecordingCardWithNewestFirstClips() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a"),
                stampedDatedClip(id: 4, date: today, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        )
        let recording = try requireRecording(sections.first?.rows.first)

        #expect(sections.map(rowIDs) == [[.recording(recording: recordingID("boot-a"), occurrence: 0)]])
        #expect(recording.recordingID == recordingID("boot-a"))
        #expect(recording.clips.map(\.id) == [5, 4])
        #expect(recording.representative?.id == 4)
    }

    @Test func singleStampedClipIsStillARecordingCard() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [stampedDatedClip(id: 5, date: today, bootTag: "boot-a")],
            today: today,
            calendar: calendar
        )

        #expect(sections.map(rowIDs) == [[.recording(recording: recordingID("boot-a"), occurrence: 0)]])
    }

    @Test func bareClipsStayFlatBetweenStampedRecordingCards() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, bootTag: "boot-a"),
                datedClip(id: 5, date: today),
                stampedDatedClip(id: 4, date: today, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        )

        #expect(sections.map(rowIDs) == [[
            .recording(recording: recordingID("boot-a"), occurrence: 0),
            .finished(5),
            .recording(recording: recordingID("boot-a"), occurrence: 1),
        ]])
    }

    @Test func adjacentDifferentBootTagsBecomeDistinctCards() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, bootTag: "boot-b"),
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        )

        #expect(sections.map(rowIDs) == [[
            .recording(recording: recordingID("boot-b"), occurrence: 0),
            .recording(recording: recordingID("boot-a"), occurrence: 0),
        ]])
    }

    @Test func sameBootTwoSessionsBecomeTwoRecordingCards() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, bootTag: "boot-a", session: 2),
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a", session: 1),
            ],
            today: today,
            calendar: calendar
        )

        // One boot, two sessions: two separate cards, each occurrence 0 of its own RecordingID.
        #expect(sections.map(rowIDs) == [[
            .recording(recording: recordingID("boot-a", session: 2), occurrence: 0),
            .recording(recording: recordingID("boot-a", session: 1), occurrence: 0),
        ]])
    }

    @Test func partialIdentityClipStaysUngroupedFinishedRow() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        // A clip with a non-nil bootTag but nil session (recordingID == nil) is not a recording:
        // it stays an ordinary finished row and does not coalesce with the adjacent same-bootTag
        // stamped clip -- pinning the all-or-nothing degrade.
        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, bootTag: "boot-a"),
                partialIdentityClip(id: 5, date: today, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        )

        #expect(sections.map(rowIDs) == [[
            .recording(recording: recordingID("boot-a"), occurrence: 0),
            .finished(5),
        ]])
    }

    @Test func midnightSpanningRecordingUsesDistinctOccurrencesAcrossDaySections() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let jan3 = try date(year: 2026, month: 1, day: 3, hour: 0, minute: 1, calendar: calendar)
        let jan2 = try date(year: 2026, month: 1, day: 2, hour: 23, minute: 59, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: jan3, bootTag: "boot-a"),
                stampedDatedClip(id: 5, date: jan2, bootTag: "boot-a"),
            ],
            today: jan3,
            calendar: calendar
        )

        #expect(sections.map(\.id) == [
            .day(startOfDay: calendar.startOfDay(for: jan3), occurrence: 0),
            .day(startOfDay: calendar.startOfDay(for: jan2), occurrence: 0),
        ])
        // The same RecordingID split across two day sections gets distinct per-RecordingID
        // occurrences, so each card keeps a stable identity.
        #expect(sections.map(rowIDs) == [
            [.recording(recording: recordingID("boot-a"), occurrence: 0)],
            [.recording(recording: recordingID("boot-a"), occurrence: 1)],
        ])
    }

    @Test func recordingAttributionMarksOnlyNewestOccurrence() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let jan3 = try date(year: 2026, month: 1, day: 3, hour: 0, minute: 1, calendar: calendar)
        let jan2 = try date(year: 2026, month: 1, day: 2, hour: 23, minute: 59, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: jan3, bootTag: "boot-a"),
                stampedDatedClip(id: 5, date: jan2, bootTag: "boot-a"),
            ],
            recordingAttribution: RecordingAttribution(id: recordingID("boot-a"), freshness: .live),
            today: jan3,
            calendar: calendar
        )

        let newestRecording = try requireRecording(sections.first?.rows.first)
        let olderRecording = try requireRecording(sections.last?.rows.first)
        #expect(newestRecording.recording == .live)
        #expect(olderRecording.recording == nil)
    }

    @Test func recordingAttributionMarksOnlySessionMatchingCard() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, bootTag: "boot-a", session: 2),
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a", session: 1),
            ],
            recordingAttribution: RecordingAttribution(
                id: recordingID("boot-a", session: 2),
                freshness: .live
            ),
            today: today,
            calendar: calendar
        )
        let rows = sections.first?.rows ?? []
        let recordingSession = try requireRecording(rows.first)
        let otherSession = try requireRecording(rows.last)

        // REC attaches only to the session actually being recorded, not the same boot's other
        // session.
        #expect(recordingSession.recordingID == recordingID("boot-a", session: 2))
        #expect(recordingSession.recording == .live)
        #expect(otherSession.recordingID == recordingID("boot-a", session: 1))
        #expect(otherSession.recording == nil)
    }

    @Test func recordingAttributionDoesNotMarkTagMismatchOrNilAttribution() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let mismatch = compose(
            clips: [stampedDatedClip(id: 5, date: today, bootTag: "boot-a")],
            recordingAttribution: RecordingAttribution(id: recordingID("boot-b"), freshness: .live),
            today: today,
            calendar: calendar
        )
        let nilAttribution = compose(
            clips: [stampedDatedClip(id: 5, date: today, bootTag: "boot-a")],
            recordingAttribution: nil,
            today: today,
            calendar: calendar
        )
        let mismatchRecording = try requireRecording(mismatch.first?.rows.first)
        let nilAttributionRecording = try requireRecording(nilAttribution.first?.rows.first)

        #expect(mismatchRecording.recording == nil)
        #expect(nilAttributionRecording.recording == nil)
    }

    @Test func undatedStampedRecordingGroupsInDateUnknown() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedUndatedClip(id: 6, bootTag: "boot-a"),
                stampedUndatedClip(id: 5, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        )

        #expect(sections.map(\.id) == [.dateUnknown(occurrence: 0)])
        #expect(sections.map(rowIDs) == [[.recording(recording: recordingID("boot-a"), occurrence: 0)]])
    }

    @Test func splitRunsUseDistinctOccurrences() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
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

    @Test func runOccurrencesAreStableForTopPrependsAndBottomAppends() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let todayEarlier = try date(year: 2026, month: 1, day: 3, hour: 8, calendar: calendar)
        let yesterday = try date(year: 2026, month: 1, day: 2, hour: 12, calendar: calendar)
        let yesterdayEarlier = try date(year: 2026, month: 1, day: 2, hour: 8, calendar: calendar)

        let oldTopIDs = compose(
            clips: [datedClip(id: 4, date: today), undatedClip(id: 3), datedClip(id: 2, date: yesterday)],
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
            today: today,
            calendar: calendar
        ).map(\.id)
        #expect(newTopIDs == oldTopIDs)

        let oldBottomIDs = compose(
            clips: [datedClip(id: 4, date: today), datedClip(id: 3, date: yesterday)],
            today: today,
            calendar: calendar
        ).map(\.id)
        let newBottomIDs = compose(
            clips: [
                datedClip(id: 4, date: today),
                datedClip(id: 3, date: yesterday),
                datedClip(id: 2, date: yesterdayEarlier),
            ],
            today: today,
            calendar: calendar
        ).map(\.id)
        #expect(newBottomIDs == oldBottomIDs)
    }

    @Test func recordingOccurrencesAreStableAcrossSameRecordingPrependAndAppend() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)
        let earlier = try date(year: 2026, month: 1, day: 3, hour: 11, calendar: calendar)

        let oldTopIDs = compose(
            clips: [stampedDatedClip(id: 4, date: today, bootTag: "boot-a")],
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        let newTopIDs = compose(
            clips: [
                stampedDatedClip(id: 5, date: today, bootTag: "boot-a"),
                stampedDatedClip(id: 4, date: earlier, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        #expect(newTopIDs == oldTopIDs)

        let oldBottomIDs = compose(
            clips: [stampedDatedClip(id: 4, date: today, bootTag: "boot-a")],
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        let newBottomIDs = compose(
            clips: [
                stampedDatedClip(id: 4, date: today, bootTag: "boot-a"),
                stampedDatedClip(id: 3, date: earlier, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        ).flatMap(rowIDs)
        #expect(newBottomIDs == oldBottomIDs)
    }

    @Test func mixedDurationRecordingOmitsAggregateDuration() throws {
        let calendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        let sections = compose(
            clips: [
                stampedDatedClip(id: 6, date: today, durMs: 30_000, bootTag: "boot-a"),
                stampedDatedClip(id: 5, date: today, durMs: nil, bootTag: "boot-a"),
            ],
            today: today,
            calendar: calendar
        )
        let recording = try requireRecording(sections.first?.rows.first)

        #expect(recording.totalDurMs == nil)
        #expect(Formatters.recordingCardSubtitle(
            durationMs: recording.totalDurMs,
            clipCount: recording.clipCount
        ) == "2 clips")
    }

    @Test func calendarTimeZoneControlsDayBoundaries() throws {
        let utcCalendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 0))
        let plusTwoCalendar = gregorianCalendar(timeZone: try timeZone(secondsFromGMT: 2 * 60 * 60))
        let instant = try date(year: 2026, month: 1, day: 1, hour: 23, minute: 30, calendar: utcCalendar)
        let clip = datedClip(id: 7, date: instant)

        let utcSections = compose(
            clips: [clip],
            today: instant,
            calendar: utcCalendar
        )
        let plusTwoSections = compose(
            clips: [clip],
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
        let today = try date(year: 2026, month: 1, day: 3, hour: 12, calendar: calendar)

        #expect(compose(
            clips: [],
            today: today,
            calendar: calendar
        ) == [])
    }

    private func compose(
        clips: [Clip],
        recordingAttribution: RecordingAttribution? = nil,
        today: Date,
        calendar: Calendar
    ) -> [HomeSectionModel] {
        HomeRow.composeSections(
            clips: clips,
            recordingAttribution: recordingAttribution,
            today: today,
            calendar: calendar
        )
    }

    private func rowIDs(_ section: HomeSectionModel) -> [HomeRowID] {
        section.rows.map(\.id)
    }

    private func recordingID(_ bootTag: String, session: UInt64 = 7) -> RecordingID {
        RecordingID(bootTag: bootTag, session: session)
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
        bootTag: String,
        session: UInt64 = 7
    ) -> Clip {
        CameraSamples.clip(
            id: id,
            startMs: UInt64((date.timeIntervalSince1970 * 1_000).rounded()),
            durMs: durMs,
            timeApproximate: false,
            bootTag: bootTag,
            session: session
        )
    }

    private func stampedUndatedClip(id: Int, bootTag: String, session: UInt64 = 7) -> Clip {
        CameraSamples.clip(id: id, durMs: 30_000, bootTag: bootTag, session: session)
    }

    /// A clip with stamped bootTag but no session -- the all-or-nothing degrade: `recordingID`
    /// is nil, so it never groups.
    private func partialIdentityClip(id: Int, date: Date, bootTag: String) -> Clip {
        CameraSamples.clip(
            id: id,
            startMs: UInt64((date.timeIntervalSince1970 * 1_000).rounded()),
            durMs: 30_000,
            timeApproximate: false,
            bootTag: bootTag,
            session: nil
        )
    }

    private func requireRecording(_ row: HomeRow?) throws -> RecordingGroup {
        let row = try #require(row)
        guard case .recording(let recording) = row else {
            Issue.record("Expected a recording row.")
            return RecordingGroup(recordingID: RecordingID(bootTag: "", session: 0), occurrence: -1, clips: [])
        }
        return recording
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
