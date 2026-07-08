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
            $0.headEpoch = 1
        }
        #expect(store.state.hasLoadedOnce == false)
        await store.receive(.clipsResponse(epoch: 1, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.nextCursor = "1"
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
                status: .loading,
                headEpoch: 4
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipFinalized(newClip)) {
            $0.clips = [newClip, oldClip]
            $0.clipFinalizeEpoch[2] = 4
        }
        await store.send(.clipFinalized(updatedOld)) {
            $0.clips = [newClip, updatedOld]
            $0.clipFinalizeEpoch[1] = 4
        }
    }

    @Test func staleLoadResponseKeepsClipFinalizedDuringThatRequest() async {
        let folded = CameraSamples.clip(id: 3)
        let staleResponse = CameraSamples.clipsResponse(ids: [2, 1])
        let queue = ClipsFetchQueue([.success(staleResponse)])
        let store = TestStore(
            initialState: ClipsFeature.State(),
            dependencies: dependencies(queue: queue),
            reduce: ClipsFeature.reduce
        )

        await store.send(.refresh) {
            $0.status = .loading
            $0.headEpoch = 1
        }
        await store.send(.clipFinalized(folded)) {
            $0.clips = [folded]
            $0.clipFinalizeEpoch[3] = 1
        }
        await store.receive(.clipsResponse(epoch: 1, .success(staleResponse))) {
            $0.clips = [folded] + staleResponse.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.clipFinalizeEpoch = [3: 1]
        }
    }

    @Test func failureKeepsExistingClips() async {
        let existing = [CameraSamples.clip(id: 4)]
        let store = TestStore(
            initialState: ClipsFeature.State(clips: existing, status: .loading, headEpoch: 1),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, .failure(.http(503)))) {
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
                headEpoch: 1
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
    }

    @Test func deleteTappedOptimisticallyRemovesAndSuccessKeepsRemoved() async {
        let clip = CameraSamples.clip(id: 7)
        let deleteProbe = ClipDeleteProbe([.success(())])
        let store = TestStore(
            initialState: ClipsFeature.State(clips: [clip]),
            dependencies: dependencies(deleteProbe: deleteProbe),
            reduce: ClipsFeature.reduce
        )

        await store.send(.deleteTapped(clip)) {
            $0.clips = []
            $0.pendingDeleteIDs = [7]
            $0.suppressedClipIDs = [7]
        }
        await store.receive(.deleteResponse(clip: clip, .success(true))) {
            $0.pendingDeleteIDs = []
        }
        #expect(await deleteProbe.deletedIDs() == [7])
    }

    @Test func deleteFailureReinsertsBut404StaysRemoved() async {
        let clip = CameraSamples.clip(id: 7)
        let store = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7],
                suppressedClipIDs: [7]
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.deleteResponse(clip: clip, .failure(.http(500)))) {
            $0.clips = [clip]
            $0.status = .failed("HTTP 500")
            $0.pendingDeleteIDs = []
            $0.suppressedClipIDs = []
        }

        let notFoundStore = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7],
                suppressedClipIDs: [7]
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )
        await notFoundStore.send(.deleteResponse(clip: clip, .failure(.http(404)))) {
            $0.pendingDeleteIDs = []
        }
    }

    @Test func clipRemovedBeatsLateDeleteFailure() async {
        let clip = CameraSamples.clip(id: 7)
        let store = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7],
                suppressedClipIDs: [7]
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipRemoved(id: 7)) {
            $0.pendingDeleteIDs = []
        }
        await store.send(.deleteResponse(clip: clip, .failure(.http(500))))
    }

    @Test func headConfirmsOptimisticallyRemovedDeleteBeforeLateFailure() async {
        let clip = CameraSamples.clip(id: 7)
        let response = CameraSamples.clipsResponse(ids: [9, 8], nextCursor: nil)
        let store = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7],
                suppressedClipIDs: [7],
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.pendingDeleteIDs = []
            $0.suppressedClipIDs = [7]
        }
        await store.send(.deleteResponse(clip: clip, .failure(.http(500))))
    }

    @Test func suppressedInputsDoNotResurrectPendingDeleteUntilFailure() async {
        let clip = CameraSamples.clip(id: 7)
        let response = CameraSamples.clipsResponse(ids: [7], nextCursor: nil)
        let store = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7],
                suppressedClipIDs: [7],
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, .success(response))) {
            $0.status = .idle
            $0.hasLoadedOnce = true
        }
        await store.send(.pageResponse(epoch: 1, .success(response)))
        await store.send(.clipFinalized(clip)) {
            $0.clipFinalizeEpoch[7] = 1
        }
        await store.send(.deleteResponse(clip: clip, .failure(.http(500)))) {
            $0.clips = [clip]
            $0.status = .failed("HTTP 500")
            $0.pendingDeleteIDs = []
            $0.suppressedClipIDs = []
        }
    }

    @Test func headLoadPrunesMissedDeletesWithinAuthoritativeWindow() async {
        let response = ClipsResponse(
            clips: [CameraSamples.clip(id: 7), CameraSamples.clip(id: 6), CameraSamples.clip(id: 4)],
            serverTimeMs: nil,
            nextCursor: nil
        )
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: CameraSamples.clipsResponse(ids: [7, 6, 5, 4]).clips,
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.suppressedClipIDs = [5]
        }
    }

    @Test func headLoadKeepsClipsBelowItsCursorBoundary() async {
        let response = CameraSamples.clipsResponse(ids: [8, 7, 6], nextCursor: "6")
        let older = CameraSamples.clipsResponse(ids: [4, 2]).clips
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: response.clips + older,
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, .success(response))) {
            $0.clips = response.clips + older
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.nextCursor = "6"
        }
    }

    @Test func headLoadPrunesStaleClipAboveReturnedHead() async {
        let response = CameraSamples.clipsResponse(ids: [8, 7], nextCursor: nil)
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: CameraSamples.clipsResponse(ids: [10, 8, 7]).clips,
                headEpoch: 2,
                clipFinalizeEpoch: [10: 1]
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 2, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.suppressedClipIDs = [10]
            $0.clipFinalizeEpoch = [:]
        }
    }

    @Test func emptyHeadPrunesEverythingInAuthoritativeWindow() async {
        let response = CameraSamples.clipsResponse(ids: [], nextCursor: nil)
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: CameraSamples.clipsResponse(ids: [5, 4, 3]).clips,
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, .success(response))) {
            $0.clips = []
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.suppressedClipIDs = [3, 4, 5]
        }
    }

    @Test func stalePageResponseDoesNotOverwriteResetFrontier() async {
        let started = AsyncSignal()
        let stalePage = CameraSamples.clipsResponse(ids: [400, 399], nextCursor: "399")
        let freshHead = CameraSamples.clipsResponse(ids: [700, 699], nextCursor: "601")
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: CameraSamples.clipsResponse(ids: [500, 499]).clips,
                nextCursor: "401",
                headEpoch: 5
            ),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                clips: ClipsClient(fetch: { cursor in
                    if cursor == "401" {
                        await started.signal()
                        try await Task.sleep(for: .seconds(60))
                        return stalePage
                    }
                    #expect(cursor == nil)
                    return freshHead
                })
            ),
            reduce: ClipsFeature.reduce
        )

        await store.send(.loadMore) {
            $0.isPaging = true
        }
        await started.wait()
        await store.send(.refresh) {
            $0.status = .loading
            $0.headEpoch = 6
        }
        await store.receive(.clipsResponse(epoch: 6, .success(freshHead))) {
            $0.clips = freshHead.clips + CameraSamples.clipsResponse(ids: [500, 499]).clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.nextCursor = "601"
            $0.isPaging = false
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
            $0.headEpoch = 1
        }
        await started.wait()
        await store.send(.onDisappear)
        await store.finishEffects()

        store.expectNoReceivedActions()
    }

    private func dependencies(
        queue: ClipsFetchQueue? = nil,
        deleteProbe: ClipDeleteProbe? = nil
    ) -> AppDependencies {
        AppDependencies(
            health: HealthClient(fetch: { fatalError() }),
            clips: ClipsClient(
                fetch: { cursor in
                    guard let queue else {
                        fatalError("Clips fetch should not be called.")
                    }
                    return try await queue.fetch(cursor: cursor)
                },
                delete: { clipID in
                    guard let deleteProbe else {
                        fatalError("Clip delete should not be called.")
                    }
                    try await deleteProbe.delete(clipID)
                }
            )
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

private actor ClipDeleteProbe {
    private var results: [Result<Void, ClipsError>]
    private var ids: [Int] = []

    init(_ results: [Result<Void, ClipsError>]) {
        self.results = results
    }

    func delete(_ id: Int) throws {
        ids.append(id)
        switch results.removeFirst() {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func deletedIDs() -> [Int] {
        ids
    }
}
