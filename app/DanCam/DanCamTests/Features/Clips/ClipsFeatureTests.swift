import Foundation
import Testing
@testable import DanCam

@MainActor
struct ClipsFeatureTests {
    @Test func onAppearFetchesClipsAndPollsAgain() async {
        let first = ClipsResponse.sample(ids: [1])
        let second = ClipsResponse.sample(ids: [2, 1])
        let queue = ClipsFetchQueue([.success(first), .success(second)])
        let store = TestStore(
            initialState: ClipsFeature.State.idle,
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: ClipsFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await store.receive(.clipsResponse(.success(first))) {
            $0 = .loaded(first.clips)
        }
        await store.receive(.poll)
        await store.receive(.clipsResponse(.success(second))) {
            $0 = .loaded(second.clips)
        }
    }

    @Test func refreshTriggersImmediateFetch() async {
        let initial = ClipsResponse.sample(ids: [1])
        let refreshed = ClipsResponse.sample(ids: [2, 1])
        let queue = ClipsFetchQueue([.success(initial), .success(refreshed)])
        let store = TestStore(
            initialState: ClipsFeature.State.idle,
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: ClipsFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await store.receive(.clipsResponse(.success(initial))) {
            $0 = .loaded(initial.clips)
        }
        await store.send(.refresh)
        await store.receive(.clipsResponse(.success(refreshed))) {
            $0 = .loaded(refreshed.clips)
        }
    }

    @Test func failureStillSchedulesRecoveryPoll() async {
        let recovered = ClipsResponse.sample(ids: [1])
        let queue = ClipsFetchQueue([.failure(.http(503)), .success(recovered)])
        let store = TestStore(
            initialState: ClipsFeature.State.idle,
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: ClipsFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await store.receive(.clipsResponse(.failure(.http(503)))) {
            $0 = .failed("HTTP 503")
        }
        await store.receive(.poll)
        await store.receive(.clipsResponse(.success(recovered))) {
            $0 = .loaded(recovered.clips)
        }
    }

    @Test func onDisappearCancelsInFlightFetch() async {
        let started = AsyncSignal()
        let store = TestStore(
            initialState: ClipsFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                clips: ClipsClient(fetch: {
                    await started.signal()
                    try await Task.sleep(for: .seconds(60))
                    return ClipsResponse.sample(ids: [1])
                })
            ),
            reduce: ClipsFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await started.wait()
        await store.send(.onDisappear)
        await store.finishEffects()

        store.expectNoReceivedActions()
    }

    private func dependencies(
        queue: ClipsFetchQueue,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) -> AppDependencies {
        AppDependencies(
            health: HealthClient(fetch: { fatalError() }),
            clips: ClipsClient(fetch: { try await queue.fetch() }),
            sleep: sleep
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
