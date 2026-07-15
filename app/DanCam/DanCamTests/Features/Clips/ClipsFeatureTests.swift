import Foundation
import Testing
@testable import DanCam

@MainActor
struct ClipsFeatureTests {
    @Test func loadFetchesClipsOnce() async {
        let response = CameraSamples.clipsResponse(ids: [2, 1], nextCursor: ClipCursor(1))
        let queue = ClipsFetchQueue([.success(response)])
        let store = TestStore(
            initialState: ClipsFeature.State(),
            dependencies: dependencies(queue: queue),
            reduce: ClipsFeature.reduce
        )

        await store.send(.load) {
            $0.status = .loading
            $0.headEpoch = 1
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.headRequest = 1
        }
        #expect(store.state.hasLoadedOnce == false)
        await store.receive(.clipsResponse(epoch: 1, generation: 1, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.nextCursor = ClipCursor(1)
            $0.inFlightRequests = []
            $0.headRequest = nil
        }
        let cursors = await queue.requestedCursors()
        #expect(cursors == [Optional<ClipCursor>.none])
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
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.headRequest = 1
        }
        await store.send(.clipFinalized(folded)) {
            $0.clips = [folded]
            $0.clipFinalizeEpoch[3] = 1
        }
        await store.receive(.clipsResponse(epoch: 1, generation: 1, .success(staleResponse))) {
            $0.clips = [folded] + staleResponse.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.clipFinalizeEpoch = [3: 1]
            $0.inFlightRequests = []
            $0.headRequest = nil
        }
    }

    @Test func failureKeepsExistingClips() async {
        let existing = [CameraSamples.clip(id: 4)]
        let store = TestStore(
            initialState: ClipsFeature.State(clips: existing, status: .loading, headEpoch: 1),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, generation: 0, .failure(.http(503)))) {
            $0.clips = existing
            $0.status = .failed(.http(503))
        }
    }

    @Test func loadMoreFetchesNextPageAndAdvancesCursor() async {
        let firstPage = CameraSamples.clipsResponse(ids: [3, 2], nextCursor: ClipCursor(2))
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
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.pageRequest = 1
        }
        await store.receive(.pageResponse(epoch: 1, generation: 1, .success(nextPage))) {
            $0.clips = firstPage.clips + nextPage.clips
            $0.nextCursor = nil
            $0.isPaging = false
            $0.inFlightRequests = []
            $0.pageRequest = nil
        }
        let cursors = await queue.requestedCursors()
        #expect(cursors == [ClipCursor(2)])
    }

    @Test func pageFailureClearsPagingForRetry() async {
        let queue = ClipsFetchQueue([.failure(.http(503))])
        let store = TestStore(
            initialState: ClipsFeature.State(nextCursor: ClipCursor(2)),
            dependencies: dependencies(queue: queue),
            reduce: ClipsFeature.reduce
        )

        await store.send(.loadMore) {
            $0.isPaging = true
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.pageRequest = 1
        }
        await store.receive(.pageResponse(epoch: 0, generation: 1, .failure(.http(503)))) {
            $0.status = .failed(.http(503))
            $0.isPaging = false
            $0.inFlightRequests = []
            $0.pageRequest = nil
        }
    }

    @Test func deleteTappedOptimisticallyRemovesAndSuccessKeepsRemoved() async {
        let clip = CameraSamples.clip(id: 7)
        let deleteProbe = ClipDeleteProbe([.success(())])
        let cacheProbe = ClipCacheProbe()
        let store = TestStore(
            initialState: ClipsFeature.State(clips: [clip]),
            dependencies: dependencies(deleteProbe: deleteProbe, cacheProbe: cacheProbe),
            reduce: ClipsFeature.reduce
        )

        await store.send(.deleteTapped(clip)) {
            $0.clips = []
            $0.pendingDeleteIDs = [7]
        }
        await store.receive(.deleteResponse(clip: clip, .success(true))) {
            $0.pendingDeleteIDs = []
        }
        #expect(await deleteProbe.deletedIDs() == [7])
        #expect(await cacheProbe.removedIDs() == [7])
    }

    @Test func clipRemovedKeepsCachedFootage() async {
        let cacheProbe = ClipCacheProbe()
        let store = TestStore(
            initialState: ClipsFeature.State(clips: [CameraSamples.clip(id: 7)]),
            dependencies: dependencies(cacheProbe: cacheProbe),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipRemoved(id: 7)) {
            $0.clips = []
        }
        #expect(store.state.removalTombstones.isEmpty)
        #expect(await cacheProbe.removedIDs() == [])
    }

    @Test func optimisticDeleteSurvivesRefreshBeforeDeleteResolves() async {
        let clip = CameraSamples.clip(id: 7)
        let staleHead = CameraSamples.clipsResponse(ids: [7])
        let deleteStarted = AsyncSignal()
        let releaseDelete = AsyncSignal()
        let store = TestStore(
            initialState: ClipsFeature.State(clips: [clip]),
            dependencies: AppDependencies(
                clips: ClipsClient(
                    fetch: { _ in staleHead },
                    delete: { _ in
                        await deleteStarted.signal()
                        await releaseDelete.wait()
                    }
                )
            ),
            reduce: ClipsFeature.reduce
        )

        await store.send(.deleteTapped(clip)) {
            $0.clips = []
            $0.pendingDeleteIDs = [7]
        }
        await deleteStarted.wait()
        await store.send(.refresh) {
            $0.status = .loading
            $0.headEpoch = 1
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.headRequest = 1
        }
        await store.receive(.clipsResponse(epoch: 1, generation: 1, .success(staleHead))) {
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.inFlightRequests = []
            $0.headRequest = nil
        }
        await releaseDelete.signal()
        await store.receive(.deleteResponse(clip: clip, .success(true))) {
            $0.pendingDeleteIDs = []
        }
        #expect(store.state.clips.contains { $0.id == 7 } == false)
        #expect(store.state.removalTombstones.isEmpty)
    }

    @Test func confirmedRemovalSuppressesStaleOlderPage() async {
        let clip = CameraSamples.clip(id: 7)
        let response = CameraSamples.clipsResponse(ids: [7])
        let store = TestStore(
            initialState: ClipsFeature.State(
                requestSeq: 1,
                inFlightRequests: [1],
                pageRequest: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipRemoved(id: 7)) {
            $0.removalTombstones = [7: 1]
        }
        await store.send(.pageResponse(epoch: 0, generation: 1, .success(response))) {
            $0.inFlightRequests = []
            $0.removalTombstones = [:]
            $0.pageRequest = nil
        }
        #expect(store.state.clips.contains(clip) == false)
        #expect(store.state.removalTombstones.isEmpty)
    }

    @Test func confirmedRemovalSuppressesStaleSuccessfulHead() async {
        let response = CameraSamples.clipsResponse(ids: [7])
        let store = TestStore(
            initialState: ClipsFeature.State(
                requestSeq: 1,
                inFlightRequests: [1],
                headRequest: 1,
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipRemoved(id: 7)) {
            $0.removalTombstones = [7: 1]
        }
        await store.send(.clipsResponse(epoch: 1, generation: 1, .success(response))) {
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.inFlightRequests = []
            $0.removalTombstones = [:]
            $0.headRequest = nil
        }
        #expect(store.state.clips.isEmpty)
        #expect(store.state.removalTombstones.isEmpty)
    }

    @Test func retainedTombstoneReleasedOnFailureAndStaleSettlement() async {
        let store = TestStore(
            initialState: ClipsFeature.State(
                requestSeq: 1,
                inFlightRequests: [1],
                removalTombstones: [7: 1],
                pageRequest: 1,
                headEpoch: 2
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.pageResponse(epoch: 1, generation: 1, .failure(.http(503)))) {
            $0.inFlightRequests = []
            $0.removalTombstones = [:]
            $0.pageRequest = nil
        }
    }

    @Test func cancelOnlySettlementLeavesNoOrphanedGenerationOrTombstone() async {
        let cancelingDependencies = AppDependencies(
            clips: ClipsClient(fetch: { _ in
                CameraSamples.clipsResponse(ids: [])
            })
        )
        let replacedHead = TestStore(
            initialState: ClipsFeature.State(
                requestSeq: 1,
                inFlightRequests: [1],
                removalTombstones: [7: 1],
                headRequest: 1
            ),
            dependencies: cancelingDependencies,
            reduce: ClipsFeature.reduce
        )
        await replacedHead.send(.refresh) {
            $0.status = .loading
            $0.requestSeq = 2
            $0.inFlightRequests = [2]
            $0.removalTombstones = [:]
            $0.headRequest = 2
            $0.headEpoch = 1
        }
        await replacedHead.receive(
            .clipsResponse(epoch: 1, generation: 2, .success(CameraSamples.clipsResponse(ids: [])))
        ) {
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.inFlightRequests = []
            $0.headRequest = nil
        }

        let disappearedPage = TestStore(
            initialState: ClipsFeature.State(
                isPaging: true,
                requestSeq: 1,
                inFlightRequests: [1],
                removalTombstones: [7: 1],
                pageRequest: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )
        await disappearedPage.send(.onDisappear) {
            $0.isPaging = false
            $0.inFlightRequests = []
            $0.removalTombstones = [:]
            $0.pageRequest = nil
        }

        let headCancelsPage = TestStore(
            initialState: ClipsFeature.State(
                requestSeq: 2,
                inFlightRequests: [1, 2],
                removalTombstones: [7: 1],
                headRequest: 2,
                pageRequest: 1,
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )
        let response = CameraSamples.clipsResponse(ids: [])
        await headCancelsPage.send(.clipsResponse(epoch: 1, generation: 2, .success(response))) {
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.inFlightRequests = []
            $0.removalTombstones = [:]
            $0.headRequest = nil
            $0.pageRequest = nil
        }
    }

    @Test func manyRemovalsWithNoRequestInFlightStayBounded() async {
        let clips = (1...50).map { CameraSamples.clip(id: $0) }
        let store = TestStore(
            initialState: ClipsFeature.State(clips: clips),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        for id in 1...50 {
            await store.send(.clipRemoved(id: id)) {
                $0.clips.removeAll { $0.id == id }
            }
            #expect(store.state.removalTombstones.isEmpty)
        }
    }

    @Test func deleteFailureReinsertsBut404StaysRemoved() async {
        let clip = CameraSamples.clip(id: 7)
        let store = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7]
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.deleteResponse(clip: clip, .failure(.http(500)))) {
            $0.clips = [clip]
            $0.status = .failed(.http(500))
            $0.pendingDeleteIDs = []
        }

        let notFoundStore = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7]
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
                pendingDeleteIDs: [7]
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
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, generation: 0, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.pendingDeleteIDs = []
        }
        await store.send(.deleteResponse(clip: clip, .failure(.http(500))))
    }

    @Test func suppressedInputsDoNotResurrectPendingDeleteUntilFailure() async {
        let clip = CameraSamples.clip(id: 7)
        let response = CameraSamples.clipsResponse(ids: [7], nextCursor: nil)
        let store = TestStore(
            initialState: ClipsFeature.State(
                pendingDeleteIDs: [7],
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, generation: 0, .success(response))) {
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
        }
        await store.send(.pageResponse(epoch: 1, generation: 0, .success(response)))
        await store.send(.clipFinalized(clip)) {
            $0.clipFinalizeEpoch[7] = 1
        }
        await store.send(.deleteResponse(clip: clip, .failure(.http(500)))) {
            $0.clips = [clip]
            $0.status = .failed(.http(500))
            $0.pendingDeleteIDs = []
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

        await store.send(.clipsResponse(epoch: 1, generation: 0, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
        }
    }

    @Test func headLoadKeepsClipsBelowItsCursorBoundary() async {
        let response = CameraSamples.clipsResponse(ids: [8, 7, 6], nextCursor: ClipCursor(6))
        let older = CameraSamples.clipsResponse(ids: [4, 2]).clips
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: response.clips + older,
                headEpoch: 1
            ),
            dependencies: dependencies(),
            reduce: ClipsFeature.reduce
        )

        await store.send(.clipsResponse(epoch: 1, generation: 0, .success(response))) {
            $0.clips = response.clips + older
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.nextCursor = ClipCursor(6)
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

        await store.send(.clipsResponse(epoch: 2, generation: 0, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 2
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

        await store.send(.clipsResponse(epoch: 1, generation: 0, .success(response))) {
            $0.clips = []
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
        }
    }

    @Test func stalePageResponseDoesNotOverwriteResetFrontier() async {
        let started = AsyncSignal()
        let stalePage = CameraSamples.clipsResponse(ids: [400, 399], nextCursor: ClipCursor(399))
        let freshHead = CameraSamples.clipsResponse(ids: [700, 699], nextCursor: ClipCursor(601))
        let store = TestStore(
            initialState: ClipsFeature.State(
                clips: CameraSamples.clipsResponse(ids: [500, 499]).clips,
                nextCursor: ClipCursor(401),
                headEpoch: 5
            ),
            dependencies: AppDependencies(
                clips: ClipsClient(fetch: { cursor in
                    if cursor == ClipCursor(401) {
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
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.pageRequest = 1
        }
        await started.wait()
        await store.send(.refresh) {
            $0.status = .loading
            $0.headEpoch = 6
            $0.requestSeq = 2
            $0.inFlightRequests = [1, 2]
            $0.headRequest = 2
        }
        await store.receive(.clipsResponse(epoch: 6, generation: 2, .success(freshHead))) {
            $0.clips = freshHead.clips + CameraSamples.clipsResponse(ids: [500, 499]).clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 6
            $0.nextCursor = ClipCursor(601)
            $0.isPaging = false
            $0.inFlightRequests = []
            $0.headRequest = nil
            $0.pageRequest = nil
        }
        await store.send(.pageResponse(epoch: 5, generation: 1, .success(stalePage)))
        await store.finishEffects()

        store.expectNoReceivedActions()
    }

    @Test func headFetchSurvivesDisappearAndItsResponseStillApplies() async {
        let started = AsyncSignal()
        let release = AsyncSignal()
        let response = CameraSamples.clipsResponse(ids: [1])
        let store = TestStore(
            initialState: ClipsFeature.State(),
            dependencies: AppDependencies(
                clips: ClipsClient(fetch: { _ in
                    await started.signal()
                    await release.wait()
                    return response
                })
            ),
            reduce: ClipsFeature.reduce
        )

        await store.send(.load) {
            $0.status = .loading
            $0.headEpoch = 1
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.headRequest = 1
        }
        await started.wait()
        await store.send(.onDisappear)
        await release.signal()
        await store.receive(.clipsResponse(epoch: 1, generation: 1, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.hasLoadedOnce = true
            $0.lastSuccessfulHeadEpoch = 1
            $0.inFlightRequests = []
            $0.headRequest = nil
        }
        await store.finishEffects()
    }

    @Test func onDisappearCancelsInFlightPaging() async {
        let started = AsyncSignal()
        let store = TestStore(
            initialState: ClipsFeature.State(nextCursor: ClipCursor(2)),
            dependencies: AppDependencies(
                clips: ClipsClient(fetch: { _ in
                    await started.signal()
                    try await Task.sleep(for: .seconds(60))
                    return CameraSamples.clipsResponse(ids: [1])
                })
            ),
            reduce: ClipsFeature.reduce
        )

        await store.send(.loadMore) {
            $0.isPaging = true
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.pageRequest = 1
        }
        await started.wait()
        await store.send(.onDisappear) {
            $0.isPaging = false
            $0.inFlightRequests = []
            $0.pageRequest = nil
        }
        await store.finishCanceledEffects()
        store.expectNoReceivedActions()
    }

    private func dependencies(
        queue: ClipsFetchQueue? = nil,
        deleteProbe: ClipDeleteProbe? = nil,
        cacheProbe: ClipCacheProbe? = nil
    ) -> AppDependencies {
        var cache = ClipCache.noop
        if let cacheProbe {
            cache.remove = { await cacheProbe.record($0) }
        }
        return AppDependencies(
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
            ),
            clipCache: cache
        )
    }
}

private actor ClipCacheProbe {
    private var ids: [Int] = []

    func record(_ id: Int) {
        ids.append(id)
    }

    func removedIDs() -> [Int] {
        ids
    }
}

private actor ClipsFetchQueue {
    private var results: [Result<ClipsResponse, ClipsError>]
    private var cursors: [ClipCursor?] = []

    init(_ results: [Result<ClipsResponse, ClipsError>]) {
        self.results = results
    }

    func fetch(cursor: ClipCursor?) throws -> ClipsResponse {
        cursors.append(cursor)
        switch results.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func requestedCursors() -> [ClipCursor?] {
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
