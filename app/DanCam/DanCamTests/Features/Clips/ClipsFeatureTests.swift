import Foundation
import Testing
@testable import DanCam

@MainActor
struct ClipsFeatureTests {
    @Test func loadFetchesClipsOnce() async {
        let response = CameraSamples.clipsResponse(ids: [2, 1], nextCursor: "1")
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
            $0.nextCursor = "1"
            $0.loadEpoch = 1
        }
        let cursors = await queue.requestedCursors()
        #expect(cursors == [Optional<String>.none])
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
            $0.loadEpoch = 1
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

    @Test func loadMoreFetchesNextPageAndAdvancesCursor() async {
        let firstPage = CameraSamples.clipsResponse(ids: [3, 2], nextCursor: "2")
        let nextPage = CameraSamples.clipsResponse(ids: [1, 0], nextCursor: nil)
        let queue = ClipsFetchQueue([.success(nextPage)])
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: firstPage.clips,
                status: .idle,
                nextCursor: firstPage.nextCursor,
                loadEpoch: 1
            ),
            dependencies: dependencies(queue: queue),
            reduce: ClipsFeature.reduce
        )

        await store.send(.loadMore) {
            $0.isPaging = true
        }
        await store.receive(.pageResponse(epoch: 1, .success(nextPage))) {
            $0.clips = firstPage.clips + nextPage.clips
            $0.nextCursor = nil
            $0.isPaging = false
        }
        let cursors = await queue.requestedCursors()
        #expect(cursors == [Optional("2")])
    }

    @Test func loadMoreDoesNothingWithoutCursorOrWhilePaging() async {
        let noCursorStore = TestStore(
            initialState: ClipsFeature.State(nextCursor: nil),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await noCursorStore.send(.loadMore)

        let pagingStore = TestStore(
            initialState: ClipsFeature.State(nextCursor: "2", isPaging: true),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await pagingStore.send(.loadMore)
    }

    @Test func pageFailureClearsPagingForRetry() async {
        let queue = ClipsFetchQueue([.failure(.http(503))])
        let store = TestStore(
            initialState: ClipsFeature.State(nextCursor: "2"),
            dependencies: dependencies(queue: queue),
            reduce: ClipsFeature.reduce
        )

        await store.send(.loadMore) {
            $0.isPaging = true
        }
        await store.receive(.pageResponse(epoch: 0, .failure(.http(503)))) {
            $0.isPaging = false
        }
        let cursors = await queue.requestedCursors()
        #expect(cursors == [Optional("2")])
    }

    @Test func successfulHeadLoadResetsPaginationFrontierAfterReconnectGap() async {
        let alreadyLoaded = CameraSamples.clipsResponse(ids: [500, 499], nextCursor: "401")
        let freshHead = CameraSamples.clipsResponse(ids: [700, 699, 698], nextCursor: "601")
        let missingMiddle = CameraSamples.clipsResponse(ids: [600, 599], nextCursor: "599")
        let queue = ClipsFetchQueue([.success(missingMiddle)])
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: alreadyLoaded.clips,
                nextCursor: alreadyLoaded.nextCursor,
                loadEpoch: 2
            ),
            dependencies: dependencies(queue: queue),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(.success(freshHead))) {
            $0.clips = freshHead.clips + alreadyLoaded.clips
            $0.status = .idle
            $0.nextCursor = "601"
            $0.loadEpoch = 3
            $0.isPaging = false
        }
        await store.send(.loadMore) {
            $0.isPaging = true
        }
        await store.receive(.pageResponse(epoch: 3, .success(missingMiddle))) {
            $0.clips = freshHead.clips + missingMiddle.clips + alreadyLoaded.clips
            $0.nextCursor = "599"
            $0.isPaging = false
        }
        let cursors = await queue.requestedCursors()
        #expect(cursors == [Optional("601")])
    }

    @Test func stalePageResponseDoesNotOverwriteResetFrontier() async {
        let started = AsyncSignal()
        let stalePage = CameraSamples.clipsResponse(ids: [400, 399], nextCursor: "399")
        let freshHead = CameraSamples.clipsResponse(ids: [700, 699], nextCursor: "601")
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: CameraSamples.clipsResponse(ids: [500, 499]).clips,
                nextCursor: "401",
                loadEpoch: 5
            ),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                clips: ClipsClient(fetch: { cursor in
                    #expect(cursor == "401")
                    await started.signal()
                    try await Task.sleep(for: .seconds(60))
                    return stalePage
                })
            ),
            reduce: ClipsFeature.reduce
        )

        await store.send(.loadMore) {
            $0.isPaging = true
        }
        await started.wait()
        await store.send(.clipsResponse(.success(freshHead))) {
            $0.clips = freshHead.clips + CameraSamples.clipsResponse(ids: [500, 499]).clips
            $0.status = .idle
            $0.nextCursor = "601"
            $0.isPaging = false
            $0.loadEpoch = 6
        }
        await store.send(.pageResponse(epoch: 5, .success(stalePage)))
        await store.finishEffects()

        store.expectNoReceivedActions()
    }

    @Test func onDisappearCancelsInFlightFetch() async {
        let started = AsyncSignal()
        let store = TestStore(
            initialState: ClipsFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                clips: ClipsClient(fetch: { _ in
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
            clips: ClipsClient(fetch: { cursor in
                guard let queue else {
                    fatalError("Clips fetch should not be called.")
                }
                return try await queue.fetch(cursor: cursor)
            })
        )
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
