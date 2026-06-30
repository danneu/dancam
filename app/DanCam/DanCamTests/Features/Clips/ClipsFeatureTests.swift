import Foundation
import Testing
@testable import DanCam

@MainActor
struct ClipsFeatureTests {
    @Test func loadFetchesClipsOnce() async {
        let response = CameraSamples.clipsResponse(ids: [2, 1])
        let queue = ClipsFetchQueue([.success(response)])
        let store = TestStore(
            initialState: ClipsFeature.State(),
            dependencies: dependencies(queue: queue),
            reduce: ClipsFeature.reduce
        )

        await store.send(.load) {
            $0.status = .loading
        }
        await store.receive(.clipsResponse(.success(response))) {
            $0.clips = response.clips
            $0.status = .idle
        }
    }

    @Test func clipFinalizedPrependsAndDedupsRegardlessOfStatus() async {
        let oldClip = CameraSamples.clip(id: 1)
        let newClip = CameraSamples.clip(id: 2)
        let updatedOld = CameraSamples.clip(id: 1, durMs: 30_000)
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: [oldClip],
                status: .loading
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipFinalized(newClip)) {
            $0.clips = [newClip, oldClip]
        }
        await store.send(.clipFinalized(updatedOld)) {
            $0.clips = [newClip, updatedOld]
        }
    }

    @Test func staleLoadResponseMergesWithFoldedFinalizedClip() async {
        let folded = CameraSamples.clip(id: 3)
        let staleResponse = CameraSamples.clipsResponse(ids: [2, 1])
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: [folded],
                status: .loading
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(.success(staleResponse))) {
            $0.clips = [folded] + staleResponse.clips
            $0.status = .idle
        }
    }

    @Test func failureKeepsExistingClips() async {
        let existing = [CameraSamples.clip(id: 4)]
        let store = TestStore(
            initialState: ClipsFeature.State(clips: existing, status: .loading),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(.failure(.http(503)))) {
            $0.clips = existing
            $0.status = .failed("HTTP 503")
        }
    }

    @Test func onDisappearCancelsInFlightFetch() async {
        let started = AsyncSignal()
        let store = TestStore(
            initialState: ClipsFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                clips: ClipsClient(fetch: {
                    await started.signal()
                    try await Task.sleep(for: .seconds(60))
                    return CameraSamples.clipsResponse(ids: [1])
                })
            ),
            reduce: ClipsFeature.reduce
        )

        await store.send(.load) {
            $0.status = .loading
        }
        await started.wait()
        await store.send(.onDisappear)
        await store.finishEffects()

        store.expectNoReceivedActions()
    }

    private func dependencies(
        queue: ClipsFetchQueue? = nil
    ) -> AppDependencies {
        AppDependencies(
            health: HealthClient(fetch: { fatalError() }),
            clips: ClipsClient(fetch: {
                guard let queue else {
                    fatalError("Clips fetch should not be called.")
                }
                return try await queue.fetch()
            })
        )
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
