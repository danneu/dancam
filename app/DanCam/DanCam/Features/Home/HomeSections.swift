import Foundation

nonisolated enum HomeSection: Hashable, Sendable {
    case day(startOfDay: Date, occurrence: Int)
    case dateUnknown(occurrence: Int)
}

nonisolated struct HomeSectionModel: Equatable, Sendable {
    var id: HomeSection
    var rows: [HomeRow]
}

nonisolated struct RecordingGroup: Equatable, Sendable {
    var recordingID: RecordingID
    var occurrence: Int
    var clips: [Clip]
    var recording: RecordingAttribution.Freshness? = nil

    var representative: Clip? {
        clips.last
    }

    var clipCount: Int {
        clips.count
    }

    var totalDurMs: UInt64? {
        var total: UInt64 = 0
        for clip in clips {
            guard let durMs = clip.durMs else { return nil }
            total += durMs
        }
        return total
    }

    var startDate: Date? {
        clips.last?.resolvedStartDate
    }

    var endDate: Date? {
        clips.first?.resolvedStartDate
    }
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
        recordingAttribution: RecordingAttribution?,
        today _: Date,
        calendar: Calendar
    ) -> [HomeSectionModel] {
        let rows = clips.map(HomeRow.finished)
        var occurrenceCounts: [HomeSectionBase: Int] = [:]
        var recordingOccurrenceCounts: [RecordingID: Int] = [:]
        var sections: [HomeSectionModel] = []
        var currentBase: HomeSectionBase?
        var currentRows: [HomeRow] = []

        func appendCurrentSection() {
            guard let currentBase else { return }

            let occurrence = occurrenceCounts[currentBase, default: 0]
            occurrenceCounts[currentBase] = occurrence + 1
            sections.append(HomeSectionModel(
                id: currentBase.section(occurrence: occurrence),
                rows: coalescedRecordingRows(
                    currentRows,
                    recordingAttribution: recordingAttribution,
                    recordingOccurrenceCounts: &recordingOccurrenceCounts
                )
            ))
        }

        for row in rows {
            let base: HomeSectionBase
            switch row {
            case .finished(let clip):
                if let resolvedStartDate = clip.resolvedStartDate {
                    base = .day(calendar.startOfDay(for: resolvedStartDate))
                } else {
                    base = .dateUnknown
                }
            case .recording(let recording):
                if let startDate = recording.startDate {
                    base = .day(calendar.startOfDay(for: startDate))
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

    private nonisolated static func coalescedRecordingRows(
        _ rows: [HomeRow],
        recordingAttribution: RecordingAttribution?,
        recordingOccurrenceCounts: inout [RecordingID: Int]
    ) -> [HomeRow] {
        var output: [HomeRow] = []
        var index = rows.startIndex

        while index < rows.endIndex {
            guard case .finished(let firstClip) = rows[index],
                  let recordingID = firstClip.recordingID else {
                output.append(rows[index])
                index = rows.index(after: index)
                continue
            }

            var clips = [firstClip]
            var scan = rows.index(after: index)
            while scan < rows.endIndex {
                guard case .finished(let clip) = rows[scan],
                      clip.recordingID == recordingID else {
                    break
                }

                clips.append(clip)
                scan = rows.index(after: scan)
            }

            let occurrence = recordingOccurrenceCounts[recordingID, default: 0]
            recordingOccurrenceCounts[recordingID] = occurrence + 1
            let recording = recordingID == recordingAttribution?.id && occurrence == 0
                ? recordingAttribution?.freshness
                : nil
            output.append(.recording(RecordingGroup(
                recordingID: recordingID,
                occurrence: occurrence,
                clips: clips,
                recording: recording
            )))
            index = scan
        }

        return output
    }
}
