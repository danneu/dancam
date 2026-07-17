import Foundation

nonisolated struct LiveSegment: Equatable, Sendable {
    enum Elapsed: Equatable, Sendable {
        case ticking(seedDurMs: UInt64?, anchor: ContinuousClock.Instant)
        case frozen(durMs: UInt64)
    }

    var sessionId: UInt64
    var id: Int
    var elapsed: Elapsed

    func elapsedDurMs(at now: ContinuousClock.Instant) -> UInt64 {
        switch elapsed {
        case .ticking(let seedDurMs, let anchor):
            (seedDurMs ?? 0) + Self.milliseconds(from: anchor.duration(to: now))
        case .frozen(let durMs):
            durMs
        }
    }

    var isTicking: Bool {
        switch elapsed {
        case .ticking:
            true
        case .frozen:
            false
        }
    }

    private static func milliseconds(from duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }

        let seconds = UInt64(max(components.seconds, 0))
        let attoseconds = UInt64(max(components.attoseconds, 0))
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}

nonisolated enum LiveRecordingStatus: Equatable, Sendable {
    case none
    case pending
    case live(LiveSegment)

    static func from(
        recording: RecordingFeature.State,
        recorder: RecorderTruth,
        previous: LiveSegment?,
        now: ContinuousClock.Instant
    ) -> Self {
        let live: LiveSegment?
        switch recorder {
        case .unknown:
            live = nil
        case .live(let snapshot):
            live = tickingLiveSegment(from: snapshot, previousLive: previous, now: now)
        case .lastKnown(let snapshot):
            live = frozenLiveSegment(from: snapshot, previousLive: previous, now: now)
        }

        guard let live else {
            return shouldShowPending(recording: recording, recorder: recorder) ? .pending : .none
        }

        return .live(live)
    }

    var liveSegment: LiveSegment? {
        if case .live(let segment) = self {
            return segment
        }
        return nil
    }

    static func shouldShowPending(
        recording: RecordingFeature.State,
        recorder: RecorderTruth
    ) -> Bool {
        guard case .live(let snapshot) = recorder,
              snapshot.currentSegment == nil else { return false }

        let commandWantsRecording: Bool
        switch recording {
        case .starting, .recording:
            commandWantsRecording = true
        case .unknown, .idle, .stopping, .failed:
            commandWantsRecording = false
        }

        let worldStartGap = snapshot.phase.claimsRecording
        return commandWantsRecording || worldStartGap
    }

    private static func tickingLiveSegment(
        from recorder: RecorderSnapshot,
        previousLive: LiveSegment?,
        now: ContinuousClock.Instant
    ) -> LiveSegment? {
        guard let currentSegment = recorder.currentSegment else { return nil }

        if let previousLive,
           previousLive.sessionId == recorder.session,
           previousLive.id == currentSegment.id {
            let previousDurMs = previousLive.elapsedDurMs(at: now)
            if let durMs = currentSegment.durMs {
                return LiveSegment(
                    sessionId: recorder.session,
                    id: currentSegment.id,
                    elapsed: .ticking(seedDurMs: max(durMs, previousDurMs), anchor: now)
                )
            }

            if previousLive.isTicking {
                return previousLive
            }

            return LiveSegment(
                sessionId: recorder.session,
                id: currentSegment.id,
                elapsed: .ticking(seedDurMs: previousDurMs, anchor: now)
            )
        }

        return LiveSegment(
            sessionId: recorder.session,
            id: currentSegment.id,
            elapsed: .ticking(seedDurMs: currentSegment.durMs, anchor: now)
        )
    }

    private static func frozenLiveSegment(
        from recorder: RecorderSnapshot,
        previousLive: LiveSegment?,
        now: ContinuousClock.Instant
    ) -> LiveSegment? {
        guard let currentSegment = recorder.currentSegment else { return nil }

        let durMs: UInt64
        if let previousLive,
           previousLive.sessionId == recorder.session,
           previousLive.id == currentSegment.id {
            durMs = previousLive.elapsedDurMs(at: now)
        } else {
            durMs = currentSegment.durMs ?? 0
        }

        return LiveSegment(
            sessionId: recorder.session,
            id: currentSegment.id,
            elapsed: .frozen(durMs: durMs)
        )
    }
}

nonisolated struct RecordingAttribution: Equatable, Sendable {
    enum Freshness: Equatable, Sendable {
        case live
        case lastKnown
    }

    var id: RecordingID
    var freshness: Freshness

    static func from(
        status: LiveRecordingStatus,
        storageGeneration: String?,
        worldBootTag: String?,
        recorder: RecorderTruth
    ) -> Self? {
        guard let storageGeneration, let worldBootTag else { return nil }

        switch status {
        case .none:
            return nil
        case .pending:
            // `shouldShowPending` already guarantees a live recorder here; guard defensively
            // for the session so a non-live truth degrades to no attribution rather than a
            // misattributed recording.
            guard case .live(let snapshot) = recorder else { return nil }
            return RecordingAttribution(
                id: RecordingID(
                    storageGeneration: storageGeneration,
                    bootTag: worldBootTag,
                    session: snapshot.session
                ),
                freshness: .live
            )
        case .live(let segment):
            return RecordingAttribution(
                id: RecordingID(
                    storageGeneration: storageGeneration,
                    bootTag: worldBootTag,
                    session: segment.sessionId
                ),
                freshness: segment.isTicking ? .live : .lastKnown
            )
        }
    }
}

nonisolated struct LiveRecordingInputs: Equatable, Sendable {
    var recording: RecordingFeature.State
    var recorder: RecorderTruth
    var storageGeneration: String?
    var worldBootTag: String?

    static func from(_ state: AppFeature.State) -> Self {
        LiveRecordingInputs(
            recording: state.recording,
            recorder: state.link.recorderTruth,
            storageGeneration: state.link.world?.storageGeneration,
            worldBootTag: state.link.world?.bootTag
        )
    }
}
