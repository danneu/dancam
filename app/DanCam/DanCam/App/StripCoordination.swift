nonisolated enum StripCoordination {
    enum LinkPhase: Equatable {
        case suspended
        case connecting
        case online
        case offline

        init(_ link: Link) {
            switch link {
            case .suspended:
                self = .suspended
            case .connecting:
                self = .connecting
            case .online:
                self = .online
            case .offline:
                self = .offline
            }
        }
    }

    enum Tone: Equatable {
        case neutral
        case positive
        case negative
    }

    struct ConnectionPill: Equatable {
        let caption: String
        let tone: Tone
    }

    enum RecordingPill: Equatable {
        case live
        case lastKnown
        case idle
    }

    struct Projection: Equatable {
        let connection: ConnectionPill
        let recording: RecordingPill?
        let linkPhase: LinkPhase
    }

    static func project(_ state: AppFeature.State) -> Projection {
        Projection(
            connection: connectionPill(for: state.link),
            recording: recordingPill(
                recording: state.recording,
                recorder: state.link.recorderTruth
            ),
            linkPhase: LinkPhase(state.link)
        )
    }

    static func connectionPill(for link: Link) -> ConnectionPill {
        switch link {
        case .suspended:
            ConnectionPill(caption: "Paused", tone: .neutral)
        case .connecting:
            ConnectionPill(caption: "Connecting", tone: .neutral)
        case .online:
            ConnectionPill(caption: "Connected", tone: .positive)
        case .offline:
            ConnectionPill(caption: "Not connected", tone: .negative)
        }
    }

    static func recordingPill(
        recording: RecordingFeature.State,
        recorder: RecorderTruth
    ) -> RecordingPill? {
        switch recorder {
        case .unknown:
            return nil
        case .live(let snapshot):
            if snapshot.currentSegment != nil ||
                LiveRecordingStatus.shouldShowPending(recording: recording, recorder: recorder) {
                return .live
            }
            return .idle
        case .lastKnown(let snapshot):
            if snapshot.currentSegment != nil || snapshot.phase.claimsRecording {
                return .lastKnown
            }
            return .idle
        }
    }

    static func shouldResumeLiveWork(
        from previous: LinkPhase,
        to next: LinkPhase
    ) -> Bool {
        previous == .offline && next == .online
    }
}
