import Foundation

nonisolated struct ClipCoverageEpoch: Equatable, Sendable {
    let rawValue: Int
}

enum ClipsFeature {
    struct State: Equatable {
        var clips: [Clip] = []
        var status: Status = .idle
        // The durable browse frontier. A nil cursor with hasLoadedOnce means catalog end.
        var nextCursor: ClipCursor?
        var isPaging = false
        var pendingDeleteIDs: Set<Int> = []
        var requestSeq = 0
        var inFlightRequests: Set<Int> = []
        var removalTombstones: [Int: Int] = [:]
        var headRequest: Int?
        var pageRequest: Int?
        var headEpoch = 0
        var lastSuccessfulHeadEpoch = 0
        var hasLoadedOnce = false

        var epoch: ClipCoverageEpoch?
        var hasAuthoritativeCoverage = false
        var authoritativeNextCursor: ClipCursor?
        var recoveryCursor: ClipCursor?
        var incidentBoundary: ClipCursor?
        var userLoadMorePending = false
        var replacementHeadPending = false
        var request: Request?

        enum Status: Equatable {
            case idle
            case loading
            case failed(ClipsError)
        }

        struct Request: Equatable {
            var epoch: ClipCoverageEpoch
            var generation: Int
            var cursor: ClipCursor?
            var target: ClipCursor?
            var advancesBrowseFrontier: Bool
            var finalizedClipIDs: Set<Int> = []
        }

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.clips == rhs.clips
                && lhs.status == rhs.status
                && lhs.nextCursor == rhs.nextCursor
                && lhs.isPaging == rhs.isPaging
                && lhs.pendingDeleteIDs == rhs.pendingDeleteIDs
                && lhs.requestSeq == rhs.requestSeq
                && lhs.inFlightRequests == rhs.inFlightRequests
                && lhs.removalTombstones == rhs.removalTombstones
                && lhs.headRequest == rhs.headRequest
                && lhs.pageRequest == rhs.pageRequest
                && lhs.headEpoch == rhs.headEpoch
                && lhs.lastSuccessfulHeadEpoch == rhs.lastSuccessfulHeadEpoch
                && lhs.hasLoadedOnce == rhs.hasLoadedOnce
        }
    }

    enum Action: Equatable {
        case load
        case refresh
        case retry
        case revokeEpoch
        case setIncidentBoundary(ClipCursor?)
        case clipFinalized(Clip)
        case loadMore
        case deleteTapped(Clip)
        case deleteResponse(clip: Clip, Result<Bool, ClipsError>)
        case clipRemoved(id: Int)
        case clipsResponse(epoch: Int, generation: Int, Result<ClipsResponse, ClipsError>)
        case pageResponse(
            epoch: Int,
            generation: Int,
            requestedCursor: ClipCursor,
            Result<ClipsResponse, ClipsError>
        )
    }

    private static let fetchID = "clips-list"

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .load:
            retireRequest(state: &state)
            state.headEpoch += 1
            state.epoch = ClipCoverageEpoch(rawValue: state.headEpoch)
            state.hasAuthoritativeCoverage = false
            state.authoritativeNextCursor = nil
            state.recoveryCursor = nil
            state.replacementHeadPending = true
            state.status = .idle
            return .merge([
                .cancel(id: fetchID),
                schedule(state: &state, dependencies: dependencies),
            ])

        case .refresh:
            state.replacementHeadPending = true
            guard state.epoch != nil else { return .none }
            retireRequest(state: &state)
            state.status = .idle
            return .merge([
                .cancel(id: fetchID),
                schedule(state: &state, dependencies: dependencies),
            ])

        case .retry:
            state.replacementHeadPending = true
            guard state.epoch != nil else { return .none }
            state.status = .idle
            return schedule(state: &state, dependencies: dependencies)

        case .revokeEpoch:
            retireRequest(state: &state)
            state.epoch = nil
            state.hasAuthoritativeCoverage = false
            state.authoritativeNextCursor = nil
            state.recoveryCursor = nil
            state.isPaging = false
            state.status = .idle
            return .cancel(id: fetchID)

        case .setIncidentBoundary(let boundary):
            state.incidentBoundary = boundary
            return schedule(state: &state, dependencies: dependencies)

        case .clipFinalized(let clip):
            state.request?.finalizedClipIDs.insert(clip.id)
            state.clips = merged(
                existing: state.clips,
                incoming: [clip],
                suppressed: suppressedIDs(state)
            )
            return .none

        case .loadMore:
            guard state.hasLoadedOnce, state.nextCursor != nil else { return .none }
            state.userLoadMorePending = true
            return schedule(state: &state, dependencies: dependencies)

        case .deleteTapped(let clip):
            state.pendingDeleteIDs.insert(clip.id)
            state.clips.removeAll { $0.id == clip.id }
            return deleteEffect(clip: clip, dependencies: dependencies)

        case .deleteResponse(let clip, .success),
             .deleteResponse(let clip, .failure(.http(404))):
            confirmRemoval(clip.id, state: &state)
            return .none

        case .deleteResponse(let clip, .failure(let error)):
            guard state.pendingDeleteIDs.contains(clip.id) else { return .none }
            state.pendingDeleteIDs.remove(clip.id)
            state.clips = merged(
                existing: state.clips,
                incoming: [clip],
                suppressed: suppressedIDs(state)
            )
            state.status = .failed(error)
            return .none

        case .clipRemoved(let id):
            confirmRemoval(id, state: &state)
            state.clips.removeAll { $0.id == id }
            return .none

        case .clipsResponse(let epoch, let generation, let result):
            return handleResponse(
                epoch: epoch,
                generation: generation,
                requestedCursor: nil,
                result: result,
                state: &state,
                dependencies: dependencies
            )

        case .pageResponse(let epoch, let generation, let requestedCursor, let result):
            return handleResponse(
                epoch: epoch,
                generation: generation,
                requestedCursor: requestedCursor,
                result: result,
                state: &state,
                dependencies: dependencies
            )
        }
    }

    static func incidentCoverage(_ state: State) -> IncidentListCoverage {
        guard let epoch = state.epoch, state.hasAuthoritativeCoverage else { return .unloaded }
        return .loaded(epoch: epoch, nextCursor: state.authoritativeNextCursor)
    }

    private static func schedule(
        state: inout State,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        guard let epoch = state.epoch, state.request == nil else { return .none }
        if case .failed = state.status { return .none }
        return scheduleReady(epoch: epoch, state: &state, dependencies: dependencies)
    }

    private static func scheduleReady(
        epoch: ClipCoverageEpoch,
        state: inout State,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        let request: State.Request
        if state.replacementHeadPending {
            state.replacementHeadPending = false
            request = issueRequest(
                epoch: epoch,
                cursor: nil,
                target: recoveryTarget(state),
                advancesBrowseFrontier: state.hasLoadedOnce == false,
                state: &state
            )
            state.headRequest = request.generation
        } else if let recoveryCursor = state.recoveryCursor,
                  let target = recoveryTarget(state),
                  recoveryCursor.rawValue > target.rawValue {
            request = issueRequest(
                epoch: epoch,
                cursor: recoveryCursor,
                target: target,
                advancesBrowseFrontier: false,
                state: &state
            )
            state.pageRequest = request.generation
        } else if state.userLoadMorePending, let cursor = state.nextCursor {
            request = issueRequest(
                epoch: epoch,
                cursor: cursor,
                target: nil,
                advancesBrowseFrontier: true,
                state: &state
            )
            state.pageRequest = request.generation
        } else if let cursor = state.authoritativeNextCursor,
                  let boundary = state.incidentBoundary,
                  cursor.rawValue > boundary.rawValue {
            request = issueRequest(
                epoch: epoch,
                cursor: cursor,
                target: boundary,
                advancesBrowseFrontier: false,
                state: &state
            )
            state.pageRequest = request.generation
        } else {
            state.status = .idle
            state.isPaging = false
            return .none
        }

        state.request = request
        state.status = .loading
        state.isPaging = request.cursor != nil
        return fetchEffect(request: request, dependencies: dependencies)
    }

    private static func recoveryTarget(_ state: State) -> ClipCursor? {
        var target: ClipCursor?
        if state.hasLoadedOnce {
            target = state.nextCursor ?? ClipCursor(0)
        }
        if let incident = state.incidentBoundary {
            target = target.map { min($0, incident) } ?? incident
        }
        return target
    }

    private static func issueRequest(
        epoch: ClipCoverageEpoch,
        cursor: ClipCursor?,
        target: ClipCursor?,
        advancesBrowseFrontier: Bool,
        state: inout State
    ) -> State.Request {
        state.requestSeq += 1
        state.inFlightRequests.insert(state.requestSeq)
        return State.Request(
            epoch: epoch,
            generation: state.requestSeq,
            cursor: cursor,
            target: target,
            advancesBrowseFrontier: advancesBrowseFrontier
        )
    }

    private static func handleResponse(
        epoch: Int,
        generation: Int,
        requestedCursor: ClipCursor?,
        result: Result<ClipsResponse, ClipsError>,
        state: inout State,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        guard let request = state.request,
              request.epoch.rawValue == epoch,
              request.generation == generation,
              request.cursor == requestedCursor,
              state.epoch == request.epoch else {
            return .none
        }

        switch result {
        case .failure(let error):
            settleRequest(request, state: &state)
            state.status = .failed(error)
            state.isPaging = false
            return .none

        case .success(let response):
            if let requestedCursor,
               let nextCursor = response.nextCursor,
               nextCursor.rawValue >= requestedCursor.rawValue {
                settleRequest(request, state: &state)
                state.status = .failed(.decoding("Clip page cursor did not advance."))
                state.isPaging = false
                return .none
            }
            apply(response: response, request: request, state: &state)
            settleRequest(request, state: &state)
            return schedule(state: &state, dependencies: dependencies)
        }
    }

    private static func apply(response: ClipsResponse, request: State.Request, state: inout State) {
        let wireLower = response.nextCursor.map { Int($0.rawValue) } ?? 0
        let targetLower = request.target.map { Int($0.rawValue) } ?? 0
        let lower = max(wireLower, targetLower)
        let upper = request.cursor.map { Int($0.rawValue) }
        let incoming = response.clips.filter { clip in
            clip.id >= lower
                && (upper.map { clip.id < $0 } ?? true)
                && request.finalizedClipIDs.contains(clip.id) == false
        }
        let incomingIDs = Set(incoming.map(\.id))
        let candidates = Set(state.clips.map(\.id)).union(state.pendingDeleteIDs)
        let authoritativeAbsent = candidates.filter { id in
            guard id >= lower, upper.map({ id < $0 }) ?? true else { return false }
            guard incomingIDs.contains(id) == false else { return false }
            return request.finalizedClipIDs.contains(id) == false
        }
        for id in authoritativeAbsent {
            state.removalTombstones[id] = state.requestSeq
        }
        state.pendingDeleteIDs.subtract(authoritativeAbsent)
        state.clips = merged(
            existing: state.clips,
            incoming: incoming,
            suppressed: suppressedIDs(state).union(authoritativeAbsent)
        )

        let established = ClipCursor(UInt32(lower))
        state.hasAuthoritativeCoverage = true
        state.authoritativeNextCursor = lower == 0 ? nil : established
        state.lastSuccessfulHeadEpoch = request.epoch.rawValue
        state.recoveryCursor = state.authoritativeNextCursor

        if request.advancesBrowseFrontier {
            state.hasLoadedOnce = true
            state.nextCursor = lower == 0 ? nil : established
            state.userLoadMorePending = false
        }
        pruneTombstones(state: &state)
    }

    private static func fetchEffect(
        request: State.Request,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: fetchID) { send in
            guard let result = await fetchResult(cursor: request.cursor, dependencies: dependencies),
                  Task.isCancelled == false else { return }
            if let cursor = request.cursor {
                await send(.pageResponse(
                    epoch: request.epoch.rawValue,
                    generation: request.generation,
                    requestedCursor: cursor,
                    result
                ))
            } else {
                await send(.clipsResponse(
                    epoch: request.epoch.rawValue,
                    generation: request.generation,
                    result
                ))
            }
        }
    }

    private static func deleteEffect(
        clip: Clip,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: "clip-delete-\(clip.id)", cancelInFlight: true) { send in
            await dependencies.clipMedia.remove(clip)
            do {
                try await dependencies.clips.delete(clip.id)
                guard Task.isCancelled == false else { return }
                await send(.deleteResponse(clip: clip, .success(true)))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as ClipsError {
                await send(.deleteResponse(clip: clip, .failure(error)))
            } catch {
                await send(.deleteResponse(clip: clip, .failure(.transport(.wrapping(error)))))
            }
        }
    }

    private static func retireRequest(state: inout State) {
        guard let request = state.request else { return }
        settleRequest(request, state: &state)
    }

    private static func settleRequest(_ request: State.Request, state: inout State) {
        state.inFlightRequests.remove(request.generation)
        if state.headRequest == request.generation { state.headRequest = nil }
        if state.pageRequest == request.generation { state.pageRequest = nil }
        if state.request == request { state.request = nil }
        pruneTombstones(state: &state)
    }

    private static func confirmRemoval(_ id: Int, state: inout State) {
        state.removalTombstones[id] = state.requestSeq
        state.pendingDeleteIDs.remove(id)
        pruneTombstones(state: &state)
    }

    private static func pruneTombstones(state: inout State) {
        let floor = state.inFlightRequests.min()
        state.removalTombstones = state.removalTombstones.filter { _, bornAt in
            floor.map { $0 <= bornAt } ?? false
        }
    }

    private static func suppressedIDs(_ state: State) -> Set<Int> {
        state.pendingDeleteIDs.union(state.removalTombstones.keys)
    }

    private static func fetchResult(
        cursor: ClipCursor?,
        dependencies: AppDependencies
    ) async -> Result<ClipsResponse, ClipsError>? {
        do {
            return .success(try await dependencies.clips.fetch(cursor))
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch let error as ClipsError {
            return .failure(error)
        } catch {
            return .failure(.transport(.wrapping(error)))
        }
    }

    private static func merged(existing: [Clip], incoming: [Clip], suppressed: Set<Int>) -> [Clip] {
        var byID: [Int: Clip] = [:]
        for clip in existing where suppressed.contains(clip.id) == false { byID[clip.id] = clip }
        for clip in incoming where suppressed.contains(clip.id) == false { byID[clip.id] = clip }
        return byID.values.sorted { $0.id > $1.id }
    }
}
