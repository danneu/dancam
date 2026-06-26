import Testing
@testable import DanCam

struct HomeCoordinationTests {
    @Test func refreshesExactlyOnRecordingStopTransitions() {
        let cases: [(RecordingFeature.State, RecordingFeature.State, Bool)] = [
            (.recording, .idle, true),
            (.stopping, .idle, true),
            (.idle, .idle, false),
            (.starting, .recording, false),
            (.recording, .failed("lost"), false),
            (.unknown, .idle, false),
        ]

        for (previous, next, expected) in cases {
            #expect(
                HomeCoordination.shouldRefreshClips(from: previous, to: next) == expected
            )
        }
    }
}
