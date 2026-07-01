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

    @Test func snapshotSeedsOnlineRecordingProjectionAndLoadsClips() async {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 43, durMs: 12_000)
        )
        let response = CameraSamples.clipsResponse(ids: [42])
        let queue = ClipsFetchQueue([.success(response)])
        let store = TestStore(
            initialState: AppFeature.State(),
            dependencies: dependencies(clips: ClipsClient(fetch: { cursor in
                try await queue.fetch(cursor: cursor)
            })),
            reduce: AppFeature.reduce
        )

        await store.send(.event(.snapshot(world))) {
            $0.link = .online(world)
            $0.recording = .recording
            $0.clips.status = .loading
        }
        await store.receive(.clips(.clipsResponse(.success(response)))) {
            $0.clips.clips = response.clips
            $0.clips.status = .idle
            $0.clips.loadEpoch = 1
        }
        await store.send(.streamStopped)
        await store.finishEffects()
    }

    @Test func heartbeatDoesNotBounceOptimisticStarting() async {
        let world = CameraSamples.world(phase: .idle)
        let store = TestStore(
            initialState: state(link: .online(world), recording: .starting),
            dependencies: dependencies(),
            reduce: AppFeature.reduce
        )

        await store.send(.event(.heartbeat(tMs: 12_000)))
        await store.finishEffects()

        #expect(store.state.recording == .starting)
        #expect(store.state.link == .online(world))
    }

    @Test func clipFinalizedPrependsAndSurvivesStaleLoadResponse() async {
        let world = CameraSamples.world()
        let folded = CameraSamples.clip(id: 3)
        let stale = CameraSamples.clipsResponse(ids: [2, 1])
        let store = TestStore(
            initialState: state(link: .online(world)),
            dependencies: dependencies(),
            reduce: AppFeature.reduce
        )

        await store.send(.event(.clipFinalized(folded))) {
            $0.clips.clips = [folded]
        }
        await store.send(.clips(.clipsResponse(.success(stale)))) {
            $0.clips.clips = [folded] + stale.clips
            $0.clips.status = .idle
            $0.clips.loadEpoch = 1
        }
        await store.finishEffects()
    }

    @Test func commandPhaseEventsDriveNonCommandingClientOverlay() async throws {
        let world = CameraSamples.world(phase: .idle)
        let store = TestStore(
            initialState: state(link: .online(world), recording: .idle),
            dependencies: dependencies(),
            reduce: AppFeature.reduce
        )

        await store.send(.event(.recordingStarting(session: 7, atMs: 5_000))) {
            var nextWorld = world
            nextWorld.recorder.phase = .starting
            nextWorld.recorder.currentSegment = nil
            $0.link = .online(nextWorld)
            $0.recording = .starting
        }
        let startingWorld = try #require(store.state.link.world)

        await store.send(.event(.recordingStarted(session: 7, atMs: 5_200))) {
            var nextWorld = startingWorld
            nextWorld.recorder.phase = .recording
            $0.link = .online(nextWorld)
            $0.recording = .recording
        }
        let recordingWorld = try #require(store.state.link.world)

        await store.send(.event(.recordingStopping(session: 7, atMs: 60_000))) {
            var nextWorld = recordingWorld
            nextWorld.recorder.phase = .stopping
            $0.link = .online(nextWorld)
            $0.recording = .stopping
        }
        let stoppingWorld = try #require(store.state.link.world)

        await store.send(.event(.recordingStopped(session: 7, atMs: 62_000))) {
            var nextWorld = stoppingWorld
            nextWorld.recorder.phase = .idle
            nextWorld.recorder.currentSegment = nil
            $0.link = .online(nextWorld)
            $0.recording = .idle
        }
        await store.finishEffects()
    }

    @Test func segmentOpenedUpdatesWorldWithoutClipsChurn() async {
        let world = CameraSamples.world(phase: .starting)
        let store = TestStore(
            initialState: state(link: .online(world), recording: .starting),
            dependencies: dependencies(
                clips: ClipsClient(fetch: { _ in fatalError("Segment open should not fetch clips.") })
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.event(.segmentOpened(session: 7, id: 43, atMs: 5_400))) {
            var nextWorld = world
            nextWorld.recorder.phase = .recording
            nextWorld.recorder.currentSegment = RecorderSegment(id: 43, durMs: nil)
            $0.link = .online(nextWorld)
            $0.recording = .recording
        }
        await store.finishEffects()
    }

    @Test func loadMoreRoutesThroughClipsFeature() async {
        let page = CameraSamples.clipsResponse(ids: [41, 40], nextCursor: nil)
        let queue = ClipsFetchQueue([.success(page)])
        let store = TestStore(
            initialState: state(
                clips: ClipsFeature.State(
                    clips: CameraSamples.clipsResponse(ids: [42], nextCursor: "42").clips,
                    nextCursor: "42"
                )
            ),
            dependencies: dependencies(clips: ClipsClient(fetch: { cursor in
                try await queue.fetch(cursor: cursor)
            })),
            reduce: AppFeature.reduce
        )

        await store.send(.clips(.loadMore)) {
            $0.clips.isPaging = true
        }
        await store.receive(.clips(.pageResponse(epoch: 0, .success(page)))) {
            $0.clips.clips = CameraSamples.clipsResponse(ids: [42]).clips + page.clips
            $0.clips.nextCursor = nil
            $0.clips.isPaging = false
        }

        let cursors = await queue.requestedCursors()
        #expect(cursors == [Optional("42")])
    }

    @Test func telemetryEventsFoldWorldSlices() async throws {
        let world = CameraSamples.world(storage: nil, tempC: TempC(soc: nil, sensor: nil), mem: nil)
        let store = TestStore(
            initialState: state(link: .online(world)),
            dependencies: dependencies(),
            reduce: AppFeature.reduce
        )

        await store.send(.event(.storageChanged(used: 1, total: 2))) {
            var nextWorld = world
            nextWorld.storage = Storage(used: 1, total: 2)
            $0.link = .online(nextWorld)
        }
        let storageWorld = try #require(store.state.link.world)

        await store.send(.event(.tempChanged(soc: 51.5, sensor: nil))) {
            var nextWorld = storageWorld
            nextWorld.tempC = TempC(soc: 51.5, sensor: nil)
            $0.link = .online(nextWorld)
        }
        let tempWorld = try #require(store.state.link.world)

        await store.send(.event(.memChanged(total: 3, available: 2, swapTotal: 1, swapUsed: 0))) {
            var nextWorld = tempWorld
            nextWorld.mem = Mem(total: 3, available: 2, swapTotal: 1, swapUsed: 0)
            $0.link = .online(nextWorld)
        }
        await store.finishEffects()
    }

    @Test func streamStartArmsHeartbeatTimeoutBeforeSnapshot() async {
        let streamTerminated = AsyncSignal()
        let heartbeatArmed = AsyncSignal()
        let store = TestStore(
            initialState: AppFeature.State(),
            dependencies: dependencies(
                events: EventsClient {
                    AsyncThrowingStream { continuation in
                        continuation.onTermination = { _ in
                            Task {
                                await streamTerminated.signal()
                            }
                        }
                    }
                },
                sleep: longSleep,
                heartbeatTimeout: {
                    await heartbeatArmed.signal()
                }
            ),
            reduce: AppFeature.reduce
        )

        await store.send(.streamStarted)
        await heartbeatArmed.wait()
        await store.receive(.heartbeatTimedOut) {
            $0.link = .offline(last: nil)
            $0.streamReconnectAttempt = 1
        }
        await streamTerminated.wait()
        await store.send(.streamStopped) {
            $0.streamReconnectAttempt = 0
        }
        await store.finishEffects()
    }

    @Test func streamFailureGoesOfflineAndSchedulesReconnect() async {
        let world = CameraSamples.world(phase: .recording)
        let store = TestStore(
            initialState: state(link: .online(world)),
            dependencies: dependencies(sleep: longSleep),
            reduce: AppFeature.reduce
        )

        await store.send(.streamFailed) {
            $0.link = .offline(last: world)
            $0.streamReconnectAttempt = 1
        }
        await store.send(.streamStopped) {
            $0.streamReconnectAttempt = 0
        }
        await store.finishEffects()
    }

    private func state(
        link: Link = .connecting,
        recording: RecordingFeature.State = .unknown,
        clips: ClipsFeature.State = ClipsFeature.State()
    ) -> AppFeature.State {
        var state = AppFeature.State()
        state.link = link
        state.recording = recording
        state.clips = clips
        return state
    }

    private func dependencies(
        events: EventsClient = .noop,
        clips: ClipsClient = .noop,
        recording: RecordingClient = .noop,
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in },
        heartbeatTimeout: @escaping @Sendable () async throws -> Void = { throw CancellationError() }
    ) -> AppDependencies {
        AppDependencies(
            health: HealthClient(fetch: { fatalError("Health should not be called.") }),
            events: events,
            clips: clips,
            recording: recording,
            sleep: sleep,
            heartbeatTimeout: heartbeatTimeout
        )
    }

    private func longSleep(_ duration: Duration) async {
        try? await Task.sleep(for: .seconds(60))
    }
}

private actor ClipsFetchQueue {
    private var results: [Result<ClipsResponse, ClipsError>]
    private var cursors: [String?] = []

    init(_ results: [Result<ClipsResponse, ClipsError>]) {
        self.results = results
    }

    func fetch(cursor: String?) throws -> ClipsResponse {
        cursors.append(cursor)
        switch results.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func requestedCursors() -> [String?] {
        cursors
    }
}
