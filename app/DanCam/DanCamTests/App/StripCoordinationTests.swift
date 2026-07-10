import Testing
@testable import DanCam

struct StripCoordinationTests {
    @Test func connectionPillMapsCaptionAndTone() {
        let world = CameraSamples.world()
        let cases: [(Link, StripCoordination.ConnectionPill)] = [
            (.connecting, .init(caption: "Connecting", tone: .neutral)),
            (.online(world), .init(caption: "Connected", tone: .positive)),
            (.offline(last: world), .init(caption: "Not connected", tone: .negative)),
        ]

        for (link, expected) in cases {
            #expect(StripCoordination.connectionPill(for: link) == expected)
        }
    }

    @Test func resumesLiveWorkOnlyFromOfflineToOnline() {
        let cases: [(StripCoordination.LinkPhase, StripCoordination.LinkPhase, Bool)] = [
            (.offline, .online, true),
            (.connecting, .online, false),
            (.online, .online, false),
            (.online, .offline, false),
            (.offline, .offline, false),
            (.connecting, .offline, false),
        ]

        for (previous, next, expected) in cases {
            #expect(StripCoordination.shouldResumeLiveWork(from: previous, to: next) == expected)
        }
    }

    @Test func recordingPillMapsAllRecorderTruthStates() {
        let segment = RecorderSegment(id: 24, durMs: nil)
        let cases: [(RecordingFeature.State, RecorderTruth, StripCoordination.RecordingPill?)] = [
            (.unknown, .unknown, nil),
            (.idle, .live(snapshot(phase: .recording, currentSegment: segment)), .live),
            (.starting, .live(snapshot(phase: .idle)), .live),
            (.recording, .live(snapshot(phase: .idle)), .live),
            (.idle, .live(snapshot(phase: .starting)), .live),
            (.idle, .live(snapshot(phase: .recording)), .live),
            (.idle, .live(snapshot(phase: .idle)), .idle),
            (.idle, .live(snapshot(phase: .stopping)), .idle),
            (.idle, .lastKnown(snapshot(phase: .recording, currentSegment: segment)), .lastKnown),
            (.idle, .lastKnown(snapshot(phase: .recording)), .lastKnown),
            (.idle, .lastKnown(snapshot(phase: .starting)), .lastKnown),
            (.idle, .lastKnown(snapshot(phase: .stopping)), .idle),
            (.idle, .lastKnown(snapshot(phase: .idle)), .idle),
            (.starting, .lastKnown(snapshot(phase: .idle)), .idle),
        ]

        for (recording, recorder, expected) in cases {
            #expect(StripCoordination.recordingPill(recording: recording, recorder: recorder) == expected)
        }
    }

    @MainActor
    @Test func projectionIgnoresUnrelatedWorldDeltas() {
        var first = AppFeature.State()
        first.link = .online(CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000),
            storage: Storage(used: 100, total: 1_000),
            tempC: TempC(
                soc: TempReading(current: 40),
                sensor: TempReading(current: 41)
            ),
            uptimeS: 1
        ))
        first.recording = .recording

        var second = first
        second.link = .online(CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 24, durMs: 107_000),
            storage: Storage(used: 900, total: 1_000),
            tempC: TempC(
                soc: TempReading(current: 45),
                sensor: TempReading(current: 46)
            ),
            uptimeS: 30
        ))

        #expect(StripCoordination.project(first) == StripCoordination.project(second))
    }

    private func snapshot(
        phase: RecorderPhase,
        currentSegment: RecorderSegment? = nil
    ) -> RecorderSnapshot {
        RecorderSnapshot(
            phase: phase,
            session: 7,
            currentSegment: currentSegment,
            detail: nil
        )
    }
}
