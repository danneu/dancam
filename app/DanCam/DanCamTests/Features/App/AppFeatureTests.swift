import Foundation
import Testing
@testable import DanCam

@MainActor
struct AppFeatureTests {
    @Test func recordTappedRoutesByCurrentRecordingState() async {
        let startStore = TestStore(
            initialState: state(recording: .idle),
            dependencies: dependencies(
                recording: RecordingClient(
                    start: { throw CancellationError() },
                    stop: { fatalError("Stop should not be called.") }
                )
            ),
            reduce: AppFeature.reduce
        )

        await startStore.send(.recordTapped) {
            $0.recording = .starting
        }
        await startStore.finishEffects()
        startStore.expectNoReceivedActions()

        let stopStore = TestStore(
            initialState: state(recording: .recording),
            dependencies: dependencies(
                recording: RecordingClient(
                    start: { fatalError("Start should not be called.") },
                    stop: { throw CancellationError() }
                )
            ),
            reduce: AppFeature.reduce
        )

        await stopStore.send(.recordTapped) {
            $0.recording = .stopping
        }
        await stopStore.finishEffects()
        stopStore.expectNoReceivedActions()

        let busyStore = TestStore(
            initialState: state(recording: .starting),
            dependencies: dependencies(),
            reduce: AppFeature.reduce
        )

        await busyStore.send(.recordTapped)
        #expect(busyStore.state.recording == .starting)
    }

    @Test func recordingTransitionToIdleRefreshesClips() async {
        let response = ClipsResponse.sample(ids: [1])
        let queue = ClipsFetchQueue([.success(response)])
        let store = TestStore(
            initialState: state(recording: .recording, clips: .idle),
            dependencies: dependencies(
                clips: ClipsClient(fetch: { try await queue.fetch() }),
                sleep: longSleep
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.recording(.recordingResponse(.success(false)))) {
            $0.recording = .idle
            $0.clips = .loading
        }
        await store.receive(.clips(.clipsResponse(.success(response)))) {
            $0.clips = .loaded(response.clips)
        }
        await store.send(.clips(.onDisappear))
        await store.finishEffects()
    }

    @Test func connectionRecordingFlipSyncsRecordingAndRefreshesClipsOnStop() async {
        let stopped = StatusResponse.sample(recording: false, uptimeS: 2)
        let response = ClipsResponse.sample(ids: [1])
        let queue = ClipsFetchQueue([.success(response)])
        let store = TestStore(
            initialState: state(
                connectionStatus: .sample(recording: true),
                recording: .recording,
                clips: .idle
            ),
            dependencies: dependencies(
                clips: ClipsClient(fetch: { try await queue.fetch() }),
                sleep: longSleep
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.connection(.statusResponse(.success(stopped)))) {
            $0.connection.connectivity = .connected
            $0.connection.consecutiveFailures = 0
            $0.connection.lastStatus = stopped
            $0.recording = .idle
            $0.clips = .loading
        }
        await store.receive(.clips(.clipsResponse(.success(response)))) {
            $0.clips = .loaded(response.clips)
        }
        await store.send(.connection(.stop))
        await store.send(.clips(.onDisappear))
        await store.finishEffects()
    }

    @Test func connectionRecordingStartDoesNotRefreshClips() async {
        let loaded = ClipsResponse.sample(ids: [1])
        let recording = StatusResponse.sample(recording: true, uptimeS: 2)
        let store = TestStore(
            initialState: state(
                connectionStatus: .sample(recording: false),
                recording: .idle,
                clips: .loaded(loaded.clips)
            ),
            dependencies: dependencies(
                clips: ClipsClient(fetch: { ClipsResponse.sample(ids: [2]) }),
                sleep: longSleep
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.connection(.statusResponse(.success(recording)))) {
            $0.connection.connectivity = .connected
            $0.connection.consecutiveFailures = 0
            $0.connection.lastStatus = recording
            $0.recording = .recording
        }
        await store.send(.connection(.stop))
        await store.finishEffects()

        #expect(store.state.clips == .loaded(loaded.clips))
        store.expectNoReceivedActions()
    }

    @Test func connectionSegmentRolloverRefreshesClipsWhileRecordingStaysTrue() async {
        let loaded = ClipsResponse.sample(ids: [7])
        let refreshed = ClipsResponse.sample(ids: [8, 7])
        let nextStatus = StatusResponse.sample(
            recording: true,
            uptimeS: 2,
            currentSegmentId: 8
        )
        let queue = ClipsFetchQueue([.success(refreshed)])
        let store = TestStore(
            initialState: state(
                connectionStatus: .sample(recording: true, currentSegmentId: 7),
                recording: .recording,
                clips: .loaded(loaded.clips)
            ),
            dependencies: dependencies(
                clips: ClipsClient(fetch: { try await queue.fetch() }),
                sleep: longSleep
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.connection(.statusResponse(.success(nextStatus)))) {
            $0.connection.connectivity = .connected
            $0.connection.consecutiveFailures = 0
            $0.connection.lastStatus = nextStatus
        }
        await store.receive(.clips(.clipsResponse(.success(refreshed)))) {
            $0.clips = .loaded(refreshed.clips)
        }
        await store.send(.connection(.stop))
        await store.send(.clips(.onDisappear))
        await store.finishEffects()
    }

    @Test func unchangedConnectionSegmentDoesNotRefreshClips() async {
        let loaded = ClipsResponse.sample(ids: [7])
        let nextStatus = StatusResponse.sample(
            recording: true,
            uptimeS: 2,
            currentSegmentId: 7
        )
        let store = TestStore(
            initialState: state(
                connectionStatus: .sample(recording: true, currentSegmentId: 7),
                recording: .recording,
                clips: .loaded(loaded.clips)
            ),
            dependencies: dependencies(
                clips: ClipsClient(fetch: { fatalError("Clips should not refresh.") }),
                sleep: longSleep
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.connection(.statusResponse(.success(nextStatus)))) {
            $0.connection.connectivity = .connected
            $0.connection.consecutiveFailures = 0
            $0.connection.lastStatus = nextStatus
        }
        await store.send(.connection(.stop))
        await store.finishEffects()

        #expect(store.state.clips == .loaded(loaded.clips))
        store.expectNoReceivedActions()
    }

    @Test func firstConnectionStatusSeedsRecordingState() async {
        let response = StatusResponse.sample(recording: true)
        let store = TestStore(
            initialState: AppFeature.State(),
            dependencies: dependencies(sleep: longSleep),
            reduce: AppFeature.reduce
        )

        await store.send(.connection(.statusResponse(.success(response)))) {
            $0.connection.connectivity = .connected
            $0.connection.consecutiveFailures = 0
            $0.connection.lastStatus = response
            $0.recording = .recording
        }
        await store.send(.connection(.stop))
        await store.finishEffects()
    }

    @Test func manualRefreshSetsPendingAndClearsOnSuccess() async {
        let response = ClipsResponse.sample(ids: [1])
        let store = TestStore(
            initialState: AppFeature.State(),
            dependencies: cancellationDependencies(sleep: longSleep),
            reduce: AppFeature.reduce
        )

        await store.send(.manualRefresh) {
            $0.pendingManualRefresh = true
            $0.clips = .loading
        }
        await store.finishEffects()
        store.expectNoReceivedActions()

        await store.send(.clips(.clipsResponse(.success(response)))) {
            $0.pendingManualRefresh = false
            $0.clips = .loaded(response.clips)
        }
        await store.send(.clips(.onDisappear))
        await store.finishEffects()
    }

    @Test func manualRefreshClearsOnFailure() async {
        let store = TestStore(
            initialState: AppFeature.State(),
            dependencies: cancellationDependencies(sleep: longSleep),
            reduce: AppFeature.reduce
        )

        await store.send(.manualRefresh) {
            $0.pendingManualRefresh = true
            $0.clips = .loading
        }
        await store.finishEffects()
        store.expectNoReceivedActions()

        await store.send(.clips(.clipsResponse(.failure(.http(503))))) {
            $0.pendingManualRefresh = false
            $0.clips = .failed("HTTP 503")
        }
        await store.send(.clips(.onDisappear))
        await store.finishEffects()
    }

    @Test func mappedClipCancellationStopsPollingThroughRootStore() async {
        let started = AsyncSignal()
        let store = TestStore(
            initialState: AppFeature.State(),
            dependencies: dependencies(
                clips: ClipsClient(fetch: {
                    await started.signal()
                    try await Task.sleep(for: .seconds(60))
                    return ClipsResponse.sample(ids: [1])
                })
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.clips(.onAppear)) {
            $0.clips = .loading
        }
        await started.wait()
        await store.send(.clips(.onDisappear))
        await store.finishEffects()

        store.expectNoReceivedActions()
    }

    private func state(
        connectionStatus: StatusResponse? = nil,
        recording: RecordingFeature.State = .unknown,
        clips: ClipsFeature.State = .idle,
        pendingManualRefresh: Bool = false
    ) -> AppFeature.State {
        var state = AppFeature.State()
        state.recording = recording
        state.clips = clips
        state.pendingManualRefresh = pendingManualRefresh

        if let connectionStatus {
            state.connection.connectivity = .connected
            state.connection.lastStatus = connectionStatus
        }

        return state
    }

    private func dependencies(
        status: StatusClient = .noop,
        clips: ClipsClient = .noop,
        recording: RecordingClient = .noop,
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> AppDependencies {
        AppDependencies(
            health: HealthClient(fetch: { fatalError("Health should not be called.") }),
            status: status,
            clips: clips,
            recording: recording,
            sleep: sleep
        )
    }

    private func cancellationDependencies(
        sleep: @escaping @Sendable (Duration) async -> Void
    ) -> AppDependencies {
        dependencies(
            status: StatusClient(fetch: { throw CancellationError() }),
            clips: ClipsClient(fetch: { throw CancellationError() }),
            sleep: sleep
        )
    }

    private func longSleep(_ duration: Duration) async {
        try? await Task.sleep(for: .seconds(60))
    }
}

private actor ClipsFetchQueue {
    private var results: [Result<ClipsResponse, ClipsError>]

    init(_ results: [Result<ClipsResponse, ClipsError>]) {
        self.results = results
    }

    func fetch() throws -> ClipsResponse {
        switch results.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

private extension StatusResponse {
    static func sample(
        recording: Bool,
        uptimeS: UInt64 = 1,
        currentSegmentId: Int? = nil,
        currentSegmentDurMs: UInt64? = nil
    ) -> StatusResponse {
        StatusResponse(
            recording: recording,
            currentSegmentId: currentSegmentId,
            currentSegmentDurMs: currentSegmentDurMs,
            cameraState: .running,
            bootId: "boot-123",
            uptimeS: uptimeS,
            storage: Storage(used: 100, total: 1000),
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil
        )
    }
}

private extension ClipsResponse {
    static func sample(ids: [Int]) -> ClipsResponse {
        ClipsResponse(
            clips: ids.map {
                Clip(
                    id: $0,
                    startMs: nil,
                    durMs: nil,
                    bytes: UInt64($0 * 100),
                    locked: false,
                    etag: "\($0)-\($0 * 100)",
                    timeApproximate: true
                )
            },
            serverTimeMs: 123456789,
            nextCursor: nil
        )
    }
}
