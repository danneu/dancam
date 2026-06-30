import Foundation
import Testing
@testable import DanCam

@MainActor
struct RecordingFeatureTests {
    @Test func recorderPhaseSeedsRecordingState() async {
        let store = TestStore(
            initialState: RecordingFeature.State.unknown,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                recording: RecordingClient(start: { fatalError() }, stop: { fatalError() })
            ),
            reduce: RecordingFeature.reduce
        )

        await store.send(.recorderPhaseObserved(.recording)) {
            $0 = .recording
        }
    }

    @Test func commandPhasesMoveNonCommandingClient() async {
        let store = TestStore(
            initialState: RecordingFeature.State.idle,
            dependencies: AppDependencies(health: HealthClient(fetch: { fatalError() })),
            reduce: RecordingFeature.reduce
        )

        await store.send(.recorderPhaseObserved(.starting)) {
            $0 = .starting
        }
        await store.send(.recorderPhaseObserved(.recording)) {
            $0 = .recording
        }
        await store.send(.recorderPhaseObserved(.stopping)) {
            $0 = .stopping
        }
        await store.send(.recorderPhaseObserved(.idle)) {
            $0 = .idle
        }
    }

    @Test func optimisticStartingIgnoresStaleIdleButAcceptsRecording() async {
        let store = TestStore(
            initialState: RecordingFeature.State.starting,
            dependencies: AppDependencies(health: HealthClient(fetch: { fatalError() })),
            reduce: RecordingFeature.reduce
        )

        await store.send(.recorderPhaseObserved(.idle))
        #expect(store.state == .starting)

        await store.send(.recorderPhaseObserved(.recording)) {
            $0 = .recording
        }
    }

    @Test func optimisticStoppingIgnoresStaleRecordingButAcceptsIdle() async {
        let store = TestStore(
            initialState: RecordingFeature.State.stopping,
            dependencies: AppDependencies(health: HealthClient(fetch: { fatalError() })),
            reduce: RecordingFeature.reduce
        )

        await store.send(.recorderPhaseObserved(.recording))
        #expect(store.state == .stopping)

        await store.send(.recorderPhaseObserved(.idle)) {
            $0 = .idle
        }
    }

    @Test func startTappedStartsRecording() async {
        let store = TestStore(
            initialState: RecordingFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
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
    }

    @Test func stopTappedStopsRecording() async {
        let store = TestStore(
            initialState: RecordingFeature.State.recording,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
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
    }

    @Test func recordingFailureMapsToFailedState() async {
        let store = TestStore(
            initialState: RecordingFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: { fatalError() }),
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
                status: StatusClient(fetch: { fatalError() }),
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
