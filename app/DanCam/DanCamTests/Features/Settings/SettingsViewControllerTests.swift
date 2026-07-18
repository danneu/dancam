import Testing
import UIKit
@testable import DanCam

@MainActor
struct SettingsViewControllerTests {
    @Test func projectionsCoverConnectionTelemetryAndReadyStates() {
        var state = AppFeature.State()
        #expect(RecordingStorageProjection.project(state).estimate == "Not connected")

        state.link = .online(CameraSamples.world(storage: nil))
        #expect(RecordingStorageProjection.project(state).estimate == "Unavailable")

        state.link = .online(CameraSamples.world(storage: storage))
        #expect(RecordingStorageProjection.project(state).estimate == "Calculating...")

        state.retentionEstimator.observe(mockClip)
        #expect(RecordingStorageProjection.project(state).estimate == "About 23 hours")
    }

    @Test func setupProjectionUsesCanonicalCommissioningState() {
        var state = AppFeature.State()
        #expect(CameraSetupProjection.project(state).status == "Not connected")

        state.link = .online(CameraSamples.world(
            commissioning: Commissioning(state: .preparing, reason: nil)
        ))
        #expect(CameraSetupProjection.project(state).status == "Preparing camera...")

        state.link = .online(CameraSamples.world(
            commissioning: Commissioning(
                state: .failed,
                reason: "data_partition_growth_failed"
            )
        ))
        #expect(CameraSetupProjection.project(state).status == "Setup failed: data partition growth failed")

        state.link = .online(CameraSamples.world(commissioning: .complete))
        #expect(CameraSetupProjection.project(state).status == "Ready")

        state.link = .offline(last: CameraSamples.world(commissioning: .complete))
        #expect(CameraSetupProjection.project(state).status == "Not connected")
    }

    @Test func controllerObservesLiveStoreUpdates() {
        var state = AppFeature.State()
        state.link = .online(CameraSamples.world(storage: storage))
        let dependencies = AppDependencies(heartbeatTimeout: { throw CancellationError() })
        let store = AppStore(
            initialState: state,
            dependencies: dependencies,
            reduce: AppFeature.reduce
        )
        let controller = SettingsViewController(dependencies: dependencies, store: store)
        controller.loadViewIfNeeded()
        #expect(controller.renderedProjection?.estimate == "Calculating...")

        store.send(.event(.clipFinalized(mockClip)))

        #expect(controller.renderedProjection?.estimate == "About 23 hours")
    }

    @Test func snapshotAndDisconnectPathsResetTheEstimator() {
        let dependencies = AppDependencies(heartbeatTimeout: { throw CancellationError() })
        var snapshotState = readyState()
        _ = AppFeature.reduce(
            state: &snapshotState,
            action: .event(.snapshot(CameraSamples.world(storage: storage))),
            dependencies: dependencies
        )
        #expect(snapshotState.retentionEstimator.maxBytesPerSecond == nil)

        for action in [
            AppFeature.Action.streamFailed,
            .heartbeatTimedOut,
            .streamStopped,
        ] {
            var state = readyState()
            _ = AppFeature.reduce(state: &state, action: action, dependencies: dependencies)
            #expect(state.retentionEstimator.maxBytesPerSecond == nil)
        }
    }

    @Test func nullStorageDeltaMakesReadyEstimateUnavailableWhileOnline() {
        let dependencies = AppDependencies(heartbeatTimeout: { throw CancellationError() })
        var state = readyState()
        #expect(RecordingStorageProjection.project(state).estimate == "About 23 hours")

        _ = AppFeature.reduce(
            state: &state,
            action: .event(.storageChanged(storage: nil, storageGeneration: nil, recordingReadiness: .ready)),
            dependencies: dependencies
        )

        #expect(state.link.onlineWorld?.storage == nil)
        #expect(RecordingStorageProjection.project(state).estimate == "Unavailable")
    }

    @Test func durationFormattingFloorsHoursAndSubHourMinutes() {
        #expect(Formatters.estimatedFootage(3_599_999).display == "About 59 minutes")
        #expect(Formatters.estimatedFootage(3_600_000).display == "About 1 hour")
    }

    private func readyState() -> AppFeature.State {
        var state = AppFeature.State()
        state.link = .online(CameraSamples.world(storage: storage))
        state.retentionEstimator.observe(mockClip)
        return state
    }

    private var storage: Storage {
        Storage(used: 1_000, total: 200_000_000, recordingCapacityBytes: 162_432_000)
    }

    private var mockClip: Clip {
        Clip(
            id: 1,
            startMs: nil,
            durMs: 30_100,
            bytes: 56_776,
            locked: false,
            etag: "1-56776",
            timeApproximate: true
        )
    }
}
