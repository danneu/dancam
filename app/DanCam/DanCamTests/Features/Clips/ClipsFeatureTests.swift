import Foundation
import Testing
@testable import DanCam

@MainActor
struct ClipsFeatureTests {
    @Test func initialHeadEstablishesBrowseAndAuthoritativeFrontiers() throws {
        var state = ClipsFeature.State()
        send(.load, to: &state)
        let request = try #require(state.request)
        #expect(request.cursor == nil)

        respond(
            request,
            with: .success(CameraSamples.clipsResponse(ids: [5, 4, 3], nextCursor: ClipCursor(3))),
            to: &state
        )

        #expect(state.clips.map(\.id) == [5, 4, 3])
        #expect(state.nextCursor == ClipCursor(3))
        #expect(state.authoritativeNextCursor == ClipCursor(3))
        #expect(state.hasLoadedOnce)
    }

    @Test func snapshotWalksMiddlePagesToSavedFrontierAndRepairsArbitraryGaps() throws {
        var state = loadedState(ids: [10, 9, 8, 7, 6, 5], cursor: ClipCursor(5))
        send(.load, to: &state)
        let head = try #require(state.request)
        respond(
            head,
            with: .success(CameraSamples.clipsResponse(ids: [13, 12, 10], nextCursor: ClipCursor(10))),
            to: &state
        )

        let middle = try #require(state.request)
        #expect(middle.cursor == ClipCursor(10))
        respond(
            middle,
            with: .success(CameraSamples.clipsResponse(ids: [9, 7, 6, 5, 4], nextCursor: ClipCursor(4))),
            to: &state
        )

        #expect(state.request == nil)
        #expect(state.nextCursor == ClipCursor(5))
        #expect(state.authoritativeNextCursor == ClipCursor(5))
        #expect(state.clips.map(\.id) == [13, 12, 10, 9, 7, 6, 5])
    }

    @Test func fullyLoadedCatalogRecoversToNewEndAndRemovesOldestFirstGC() throws {
        var state = loadedState(ids: [5, 4, 3, 2, 1], cursor: nil)
        send(.load, to: &state)
        let head = try #require(state.request)
        respond(
            head,
            with: .success(CameraSamples.clipsResponse(ids: [7, 6, 5], nextCursor: ClipCursor(5))),
            to: &state
        )
        let tail = try #require(state.request)
        respond(
            tail,
            with: .success(CameraSamples.clipsResponse(ids: [4, 3], nextCursor: nil)),
            to: &state
        )

        #expect(state.request == nil)
        #expect(state.nextCursor == nil)
        #expect(state.authoritativeNextCursor == nil)
        #expect(state.clips.map(\.id) == [7, 6, 5, 4, 3])
    }

    @Test func recoveryOvershootDoesNotMergeOrInferBelowSavedFrontier() throws {
        var state = loadedState(ids: [9, 8, 7, 6, 5, 4], cursor: ClipCursor(5))
        send(.load, to: &state)
        let head = try #require(state.request)
        respond(
            head,
            with: .success(CameraSamples.clipsResponse(ids: [12, 11, 9, 4, 3], nextCursor: ClipCursor(3))),
            to: &state
        )

        #expect(state.clips.map(\.id) == [12, 11, 9, 4])
        #expect(state.nextCursor == ClipCursor(5))
        #expect(state.authoritativeNextCursor == ClipCursor(5))
    }

    @Test func incidentBoundaryAuthorizesOnlyItsExactLowerLimit() throws {
        var state = loadedState(ids: [9, 8, 7, 6, 5], cursor: ClipCursor(5))
        send(.load, to: &state)
        let head = try #require(state.request)
        respond(
            head,
            with: .success(CameraSamples.clipsResponse(ids: [11, 10, 9, 8, 7, 6, 5], nextCursor: ClipCursor(5))),
            to: &state
        )
        send(.setIncidentBoundary(ClipCursor(3)), to: &state)
        let incidentPage = try #require(state.request)
        respond(
            incidentPage,
            with: .success(CameraSamples.clipsResponse(ids: [4, 3, 2, 1], nextCursor: ClipCursor(1))),
            to: &state
        )

        #expect(state.clips.map(\.id).suffix(2) == [4, 3])
        #expect(state.clips.contains { $0.id < 3 } == false)
        #expect(state.nextCursor == ClipCursor(5))
        #expect(state.authoritativeNextCursor == ClipCursor(3))
    }

    @Test func userDemandAuthorizesOneFullPageAndAdvancesBrowseFrontier() throws {
        var state = loadedFreshState(ids: [7, 6, 5], cursor: ClipCursor(5))
        send(.loadMore, to: &state)
        let page = try #require(state.request)
        #expect(page.advancesBrowseFrontier)
        respond(
            page,
            with: .success(CameraSamples.clipsResponse(ids: [4, 3, 2], nextCursor: ClipCursor(2))),
            to: &state
        )

        #expect(state.nextCursor == ClipCursor(2))
        #expect(state.clips.map(\.id) == [7, 6, 5, 4, 3, 2])
        #expect(state.userLoadMorePending == false)
    }

    @Test func pageFailurePausesAllGoalsUntilExplicitRetry() throws {
        var state = loadedFreshState(ids: [5, 4, 3], cursor: ClipCursor(3))
        send(.loadMore, to: &state)
        let page = try #require(state.request)
        respond(page, with: .failure(.http(503)), to: &state)

        #expect(state.status == .failed(.http(503)))
        #expect(state.request == nil)
        #expect(state.userLoadMorePending)
        send(.loadMore, to: &state)
        send(.setIncidentBoundary(ClipCursor(1)), to: &state)
        let pausedRequestSequence = state.requestSeq
        send(.setIncidentBoundary(ClipCursor(1)), to: &state)
        #expect(state.request == nil)
        #expect(state.requestSeq == pausedRequestSequence)

        send(.retry, to: &state)
        #expect(state.request?.cursor == nil)
        #expect(state.userLoadMorePending)
        #expect(state.incidentBoundary == ClipCursor(1))
    }

    @Test func nonAdvancingPageCursorFailsInsteadOfLooping() throws {
        var state = loadedFreshState(ids: [5, 4, 3], cursor: ClipCursor(3))
        send(.loadMore, to: &state)
        let page = try #require(state.request)
        respond(
            page,
            with: .success(CameraSamples.clipsResponse(ids: [2], nextCursor: ClipCursor(3))),
            to: &state
        )

        #expect(state.status == .failed(.decoding("Clip page cursor did not advance.")))
        #expect(state.request == nil)
        #expect(state.nextCursor == ClipCursor(3))
        #expect(state.userLoadMorePending)
    }

    @Test func revocationRetainsRowsFrontiersAndGoalsButRejectsLateResponse() throws {
        var state = loadedFreshState(ids: [5, 4, 3], cursor: ClipCursor(3))
        send(.loadMore, to: &state)
        let stale = try #require(state.request)
        send(.setIncidentBoundary(ClipCursor(1)), to: &state)
        send(.revokeEpoch, to: &state)

        #expect(state.epoch == nil)
        #expect(state.clips.map(\.id) == [5, 4, 3])
        #expect(state.nextCursor == ClipCursor(3))
        #expect(state.userLoadMorePending)
        #expect(state.incidentBoundary == ClipCursor(1))
        respond(stale, with: .success(CameraSamples.clipsResponse(ids: [2, 1])), to: &state)
        #expect(state.clips.map(\.id) == [5, 4, 3])
        #expect(ClipsFeature.incidentCoverage(state) == .unloaded)
    }

    @Test func replacementSnapshotResumesRetainedGoalsFromHead() throws {
        var state = loadedFreshState(ids: [5, 4, 3], cursor: ClipCursor(3))
        send(.loadMore, to: &state)
        send(.setIncidentBoundary(ClipCursor(1)), to: &state)
        send(.revokeEpoch, to: &state)
        send(.load, to: &state)

        let head = try #require(state.request)
        #expect(head.cursor == nil)
        #expect(head.target == ClipCursor(1))
    }

    @Test func concurrentFinalizeAndRemovalBeatAuthoritativeAbsence() throws {
        var state = loadedState(ids: [6, 5, 4], cursor: ClipCursor(4))
        send(.load, to: &state)
        let head = try #require(state.request)
        let finalized = CameraSamples.clip(id: 7, durMs: 99_000)
        send(.clipFinalized(finalized), to: &state)
        send(.clipRemoved(id: 5), to: &state)
        respond(
            head,
            with: .success(CameraSamples.clipsResponse(ids: [7, 6, 5, 4], nextCursor: ClipCursor(4))),
            to: &state
        )

        #expect(state.clips.map(\.id) == [7, 6, 4])
        #expect(state.clips.first == finalized)
    }

    @Test func sharedRecoverySurvivesHomeDisappearance() async throws {
        let started = AsyncSignal()
        let release = AsyncSignal()
        let response = CameraSamples.clipsResponse(ids: [6, 5, 4], nextCursor: ClipCursor(4))
        let store = TestStore(
            initialState: loadedFreshState(ids: [5, 4], cursor: ClipCursor(4)),
            dependencies: AppDependencies(clips: ClipsClient(fetch: { _ in
                await started.signal()
                await release.wait()
                return response
            })),
            reduce: ClipsFeature.reduce
        )

        await store.send(.refresh) {
            $0.replacementHeadPending = false
            $0.status = .loading
            $0.requestSeq = 1
            $0.inFlightRequests = [1]
            $0.headRequest = 1
            $0.request = .init(
                epoch: ClipCoverageEpoch(rawValue: 1),
                generation: 1,
                cursor: nil,
                target: ClipCursor(4),
                advancesBrowseFrontier: false
            )
        }
        await started.wait()
        // Home no longer sends a clip lifecycle action when it disappears.
        await release.signal()
        await store.receive(.clipsResponse(epoch: 1, generation: 1, .success(response))) {
            $0.clips = response.clips
            $0.status = .idle
            $0.inFlightRequests = []
            $0.headRequest = nil
            $0.request = nil
            $0.hasAuthoritativeCoverage = true
            $0.authoritativeNextCursor = ClipCursor(4)
            $0.recoveryCursor = ClipCursor(4)
            $0.lastSuccessfulHeadEpoch = 1
        }
        await store.finishEffects()
    }

    @Test func deleteFailureRestoresClipAndConfirmedRemovalSuppressesStaleList() {
        let clip = CameraSamples.clip(id: 7)
        var state = loadedFreshState(ids: [7], cursor: nil)
        send(.deleteTapped(clip), to: &state)
        send(.deleteResponse(clip: clip, .failure(.http(500))), to: &state)
        #expect(state.clips == [clip])

        state.status = .idle
        send(.clipRemoved(id: 7), to: &state)
        #expect(state.clips.isEmpty)
    }

    private func send(
        _ action: ClipsFeature.Action,
        to state: inout ClipsFeature.State,
        dependencies: AppDependencies = AppDependencies()
    ) {
        _ = ClipsFeature.reduce(state: &state, action: action, dependencies: dependencies)
    }

    private func respond(
        _ request: ClipsFeature.State.Request,
        with result: Result<ClipsResponse, ClipsError>,
        to state: inout ClipsFeature.State
    ) {
        if let cursor = request.cursor {
            send(.pageResponse(
                epoch: request.epoch.rawValue,
                generation: request.generation,
                requestedCursor: cursor,
                result
            ), to: &state)
        } else {
            send(.clipsResponse(
                epoch: request.epoch.rawValue,
                generation: request.generation,
                result
            ), to: &state)
        }
    }

    private func loadedState(ids: [Int], cursor: ClipCursor?) -> ClipsFeature.State {
        ClipsFeature.State(
            clips: CameraSamples.clipsResponse(ids: ids).clips,
            nextCursor: cursor,
            hasLoadedOnce: true
        )
    }

    private func loadedFreshState(ids: [Int], cursor: ClipCursor?) -> ClipsFeature.State {
        ClipsFeature.State(
            clips: CameraSamples.clipsResponse(ids: ids).clips,
            nextCursor: cursor,
            headEpoch: 1,
            lastSuccessfulHeadEpoch: 1,
            hasLoadedOnce: true,
            epoch: ClipCoverageEpoch(rawValue: 1),
            hasAuthoritativeCoverage: true,
            authoritativeNextCursor: cursor,
            recoveryCursor: cursor
        )
    }
}
