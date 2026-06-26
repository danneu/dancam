import Foundation
import Testing
@testable import DanCam

@MainActor
struct RecordingFeatureTests {
    @Test func onAppearSeedsRecordingStateFromStatus() async {
        let status = StatusResponse.recording(true)
        let store = TestStore(
            initialState: RecordingFeature.State.unknown,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: { status }),
                recording: RecordingClient(start: { fatalError() }, stop: { fatalError() })
            ),
            reduce: RecordingFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .unknown
        }
        await store.receive(.statusResponse(.success(status))) {
            $0 = .recording
        }
    }

    @Test func startTappedStartsRecordingThenRefreshesStatus() async {
        let status = StatusResponse.recording(true)
        let store = TestStore(
            initialState: RecordingFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: { status }),
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
        await store.receive(.statusResponse(.success(status))) {
            $0 = .recording
        }
    }

    @Test func stopTappedStopsRecordingThenRefreshesStatus() async {
        let status = StatusResponse.recording(false)
        let store = TestStore(
            initialState: RecordingFeature.State.recording,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: { status }),
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
        await store.receive(.statusResponse(.success(status))) {
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

private extension StatusResponse {
    static func recording(_ isRecording: Bool) -> StatusResponse {
        StatusResponse(
            recording: isRecording,
            cameraState: .running,
            bootId: "boot-123",
            uptimeS: 42,
            storage: nil,
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil
        )
    }
}
