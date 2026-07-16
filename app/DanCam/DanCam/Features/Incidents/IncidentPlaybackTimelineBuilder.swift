import AVFoundation
import Foundation

nonisolated enum IncidentPlaybackGapReason: Equatable, Sendable {
    case saving
    case missing
    case unavailable
}

nonisolated struct IncidentPlaybackGap: Equatable, Sendable {
    var seq: Int
    var reason: IncidentPlaybackGapReason
}

nonisolated struct IncidentPlaybackSegment: Equatable, Sendable {
    var seq: Int
    var start: CMTime
    var duration: CMTime
    var sourceURL: URL

    var end: CMTime { CMTimeAdd(start, duration) }
}

nonisolated struct IncidentPlaybackAnchor: Equatable, Sendable {
    var seq: Int
    var offset: CMTime
}

nonisolated struct IncidentPlaybackIdentity: Equatable, Sendable {
    var seq: Int
    var sourceURL: URL
}

nonisolated struct IncidentPlaybackTimeline {
    var composition: AVMutableComposition
    var segments: [IncidentPlaybackSegment]
    var gaps: [IncidentPlaybackGap]

    var duration: CMTime { composition.duration }
    var identity: [IncidentPlaybackIdentity] {
        segments.map { IncidentPlaybackIdentity(seq: $0.seq, sourceURL: $0.sourceURL) }
    }

    func startTime(for seq: Int) -> CMTime? {
        segments.first(where: { $0.seq == seq })?.start
    }

    func anchor(at time: CMTime) -> IncidentPlaybackAnchor? {
        guard let first = segments.first else { return nil }
        if CMTimeCompare(time, first.start) < 0 {
            return IncidentPlaybackAnchor(seq: first.seq, offset: .zero)
        }

        for segment in segments where CMTimeCompare(time, segment.end) < 0 {
            return IncidentPlaybackAnchor(
                seq: segment.seq,
                offset: CMTimeMaximum(.zero, CMTimeSubtract(time, segment.start))
            )
        }

        guard let last = segments.last else { return nil }
        return IncidentPlaybackAnchor(seq: last.seq, offset: last.duration)
    }

    func restorationTime(for anchor: IncidentPlaybackAnchor?) -> CMTime {
        guard let anchor else { return .zero }
        if let segment = segments.first(where: { $0.seq == anchor.seq }) {
            return CMTimeAdd(segment.start, CMTimeMinimum(CMTimeMaximum(.zero, anchor.offset), segment.duration))
        }
        if let next = segments.first(where: { $0.seq >= anchor.seq }) {
            return next.start
        }
        return duration
    }

    func pressTime(markSeq: Int, markAgeMs: UInt64) -> CMTime {
        guard let marked = segments.first(where: { $0.seq == markSeq }) else {
            return segments.first(where: { $0.seq >= markSeq })?.start ?? duration
        }

        let age = CMTime(value: Int64(clamping: markAgeMs), timescale: 1_000)
        if CMTimeCompare(age, marked.duration) < 0 {
            return CMTimeAdd(marked.start, age)
        }
        return segments.first(where: { $0.seq > markSeq })?.start ?? duration
    }
}

nonisolated enum IncidentPlaybackTimelineBuilder {
    @concurrent
    static func build(
        segments: [IncidentSegment],
        directoryURL: URL
    ) async -> sending IncidentPlaybackTimeline {
        let composition = AVMutableComposition()
        let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        var mapped: [IncidentPlaybackSegment] = []
        var gaps: [IncidentPlaybackGap] = []
        var cursor = CMTime.zero
        var installedTransform = false

        for segment in segments.sorted(by: { $0.seq < $1.seq }) {
            if Task.isCancelled { break }
            guard segment.state == .pulled else {
                gaps.append(IncidentPlaybackGap(
                    seq: segment.seq,
                    reason: segment.state == .unresolved || segment.state == .wanted ? .saving : .missing
                ))
                continue
            }

            let sourceURL = directoryURL.appending(
                path: String(format: "seg_%05d.mp4", segment.seq)
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path),
                  let compositionTrack else {
                gaps.append(IncidentPlaybackGap(seq: segment.seq, reason: .unavailable))
                continue
            }

            do {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: sourceURL)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let sourceTrack = tracks.first else {
                    gaps.append(IncidentPlaybackGap(seq: segment.seq, reason: .unavailable))
                    continue
                }
                let sourceRange = try await sourceTrack.load(.timeRange)
                guard sourceRange.duration.isNumeric,
                      CMTimeCompare(sourceRange.duration, .zero) > 0 else {
                    gaps.append(IncidentPlaybackGap(seq: segment.seq, reason: .unavailable))
                    continue
                }

                let preferredTransform = installedTransform
                    ? nil
                    : try? await sourceTrack.load(.preferredTransform)
                try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: cursor)
                if let preferredTransform {
                    compositionTrack.preferredTransform = preferredTransform
                    installedTransform = true
                }
                mapped.append(IncidentPlaybackSegment(
                    seq: segment.seq,
                    start: cursor,
                    duration: sourceRange.duration,
                    sourceURL: sourceURL
                ))
                cursor = CMTimeAdd(cursor, sourceRange.duration)
            } catch is CancellationError {
                break
            } catch {
                gaps.append(IncidentPlaybackGap(seq: segment.seq, reason: .unavailable))
            }
        }

        return IncidentPlaybackTimeline(composition: composition, segments: mapped, gaps: gaps)
    }
}
