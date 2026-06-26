import Foundation
import Testing
@testable import DanCam

@MainActor
struct RecordingFeatureTests {
    @Test func onAppearSeedsRecordingStateFromHealth() async {
        let health = HealthResponse.recording(true)
        let store = TestStore(
            initialState: RecordingFeature.State.unknown,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { health }),
                recording: RecordingClient(start: { fatalError() }, stop: { fatalError() })
            ),
            reduce: RecordingFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .unknown
        }
        await store.receive(.healthResponse(.success(health))) {
            $0 = .recording
        }
    }

    @Test func startTappedStartsRecordingThenRefreshesHealth() async {
        let health = HealthResponse.recording(true)
        let store = TestStore(
            initialState: RecordingFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { health }),
                recording: RecordingClient(start: {}, stop: { fatalError() })
            ),
            reduce: RecordingFeature.reduce
        )

        await store.send(.startTapped) {
            $0 = .starting
        }
        await store.receive(.recordingResponse(.success(true))) {
            $0 = .recording
        }
        await store.receive(.healthResponse(.success(health))) {
            $0 = .recording
        }
    }

    @Test func stopTappedStopsRecordingThenRefreshesHealth() async {
        let health = HealthResponse.recording(false)
        let store = TestStore(
            initialState: RecordingFeature.State.recording,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { health }),
                recording: RecordingClient(start: { fatalError() }, stop: {})
            ),
            reduce: RecordingFeature.reduce
        )

        await store.send(.stopTapped) {
            $0 = .stopping
        }
        await store.receive(.recordingResponse(.success(false))) {
            $0 = .idle
        }
        await store.receive(.healthResponse(.success(health))) {
            $0 = .idle
        }
    }

    @Test func recordingFailureMapsToFailedState() async {
        let store = TestStore(
            initialState: RecordingFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                recording: RecordingClient(start: { throw RecordingError.http(503) }, stop: {})
            ),
            reduce: RecordingFeature.reduce
        )

        await store.send(.startTapped) {
            $0 = .starting
        }
        await store.receive(.recordingResponse(.failure(.http(503)))) {
            $0 = .failed("HTTP 503")
        }
    }

    @Test func cancellationSendsNoActionAndLeavesStartingState() async {
        let store = TestStore(
            initialState: RecordingFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                recording: RecordingClient(start: { throw CancellationError() }, stop: {})
            ),
            reduce: RecordingFeature.reduce
        )

        await store.send(.startTapped) {
            $0 = .starting
        }
        await store.finishEffects()

        #expect(store.state == .starting)
        store.expectNoReceivedActions()
    }
}

private extension HealthResponse {
    static func recording(_ isRecording: Bool) -> HealthResponse {
        HealthResponse(
            bootId: "boot-123",
            uptimeS: 42,
            recording: isRecording,
            tMs: 123456789
        )
    }
}
