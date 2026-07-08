import Foundation

nonisolated enum HomeSection: Hashable, Sendable {
    case day(startOfDay: Date, occurrence: Int)
    case dateUnknown(occurrence: Int)
}

nonisolated struct HomeSectionModel: Equatable, Sendable {
    var id: HomeSection
    var rows: [HomeRow]
}

private nonisolated enum HomeSectionBase: Hashable, Sendable {
    case day(Date)
    case dateUnknown

    func section(occurrence: Int) -> HomeSection {
        switch self {
        case .day(let startOfDay):
            return .day(startOfDay: startOfDay, occurrence: occurrence)
        case .dateUnknown:
            return .dateUnknown(occurrence: occurrence)
        }
    }
}

extension HomeRow {
    nonisolated static func composeSections(
        clips: [Clip],
        recording: RecordingFeature.State,
        recorder: RecorderTruth,
        previousLive: LiveSegment?,
        now: ContinuousClock.Instant,
        today: Date,
        calendar: Calendar
    ) -> [HomeSectionModel] {
        let rows = compose(
            clips: clips,
            recording: recording,
            recorder: recorder,
            previousLive: previousLive,
            now: now
        )
        let todayStart = calendar.startOfDay(for: today)
        var occurrenceCounts: [HomeSectionBase: Int] = [:]
        var sections: [HomeSectionModel] = []
        var currentBase: HomeSectionBase?
        var currentRows: [HomeRow] = []

        func appendCurrentSection() {
            guard let currentBase else { return }

            let occurrence = occurrenceCounts[currentBase, default: 0]
            occurrenceCounts[currentBase] = occurrence + 1
            sections.append(HomeSectionModel(
                id: currentBase.section(occurrence: occurrence),
                rows: currentRows
            ))
        }

        for row in rows {
            let base: HomeSectionBase
            switch row {
            case .pending, .live:
                base = .day(todayStart)
            case .finished(let clip):
                if let resolvedStartDate = clip.resolvedStartDate {
                    base = .day(calendar.startOfDay(for: resolvedStartDate))
                } else {
                    base = .dateUnknown
                }
            }

            if currentBase == base {
                currentRows.append(row)
            } else {
                appendCurrentSection()
                currentBase = base
                currentRows = [row]
            }
        }

        appendCurrentSection()
        return sections
    }
}
