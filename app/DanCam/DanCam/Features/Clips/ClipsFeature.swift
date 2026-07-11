import Foundation

enum ClipsFeature {
    struct State: Equatable {
        var clips: [Clip] = []
        var status: Status = .idle
        var nextCursor: String?
        var isPaging = false
        var pendingDeleteIDs: Set<Int> = []
        var requestSeq = 0
        var inFlightRequests: Set<Int> = []
        var removalTombstones: [Int: Int] = [:]
        var headRequest: Int?
        var pageRequest: Int?
        var headEpoch = 0
        var hasLoadedOnce = false
        var clipFinalizeEpoch: [Int: Int] = [:]

        enum Status: Equatable {
            case idle
            case loading
            case failed(ClipsError)
        }
    }

    enum Action: Equatable {
        case load
        case refresh
        case onDisappear
        case clipFinalized(Clip)
        case loadMore
        case deleteTapped(Clip)
        case deleteResponse(clip: Clip, Result<Bool, ClipsError>)
        case clipRemoved(id: Int)
        case clipsResponse(epoch: Int, generation: Int, Result<ClipsResponse, ClipsError>)
        case pageResponse(epoch: Int, generation: Int, Result<ClipsResponse, ClipsError>)
    }

    private static let fetchID = "clips-fetch"
    private static let pageID = "clips-page"

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .load, .refresh:
            settle(state.headRequest, state: &state)
            state.status = .loading
            state.headEpoch += 1
            let generation = issueRequest(state: &state)
            state.headRequest = generation
            return fetchEffect(
                epoch: state.headEpoch,
                generation: generation,
                cursor: nil,
                dependencies: dependencies
            )

        case .onDisappear:
            state.isPaging = false
            settle(state.pageRequest, state: &state)
            state.pageRequest = nil
            return .cancel(id: pageID)

        case .clipFinalized(let clip):
            state.clipFinalizeEpoch[clip.id] = state.headEpoch
            state.clips = merged(
                existing: state.clips,
                incoming: [clip],
                suppressed: suppressedIDs(state)
            )
            return .none

        case .loadMore:
            guard let cursor = state.nextCursor, state.isPaging == false else {
                return .none
            }
            state.isPaging = true
            let generation = issueRequest(state: &state)
            state.pageRequest = generation
            return pageEffect(
                cursor: cursor,
                epoch: state.headEpoch,
                generation: generation,
                dependencies: dependencies
            )

        case .deleteTapped(let clip):
            state.pendingDeleteIDs.insert(clip.id)
            state.clips.removeAll { $0.id == clip.id }
            return deleteEffect(clip: clip, dependencies: dependencies)

        case .deleteResponse(let clip, .success):
            confirmRemoval(clip.id, state: &state)
            return .none

        case .deleteResponse(let clip, .failure(.http(404))):
            confirmRemoval(clip.id, state: &state)
            return .none

        case .deleteResponse(let clip, .failure(let error)):
            guard state.pendingDeleteIDs.contains(clip.id) else {
                return .none
            }
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

        case .clipsResponse(let epoch, let generation, .success(let response)):
            guard epoch == state.headEpoch else {
                settleHead(generation, state: &state)
                return .none
            }
            let reconciliation = reconciledHead(
                existing: state.clips,
                pending: state.pendingDeleteIDs,
                response: response,
                suppressed: suppressedIDs(state),
                requestEpoch: epoch,
                finalizeEpoch: state.clipFinalizeEpoch
            )
            for id in reconciliation.authoritativeAbsentIDs {
                state.removalTombstones[id] = state.requestSeq
            }
            state.pendingDeleteIDs.subtract(reconciliation.authoritativeAbsentIDs)
            state.clips = merged(
                existing: reconciliation.clips,
                incoming: [],
                suppressed: suppressedIDs(state)
            )
            state.status = .idle
            state.hasLoadedOnce = true
            state.nextCursor = response.nextCursor
            state.isPaging = false
            state.clipFinalizeEpoch = state.clipFinalizeEpoch.filter { $0.value >= epoch }
            settleHead(generation, state: &state)
            settle(state.pageRequest, state: &state)
            state.pageRequest = nil
            return .cancel(id: pageID)

        case .clipsResponse(let epoch, let generation, .failure(let error)):
            settleHead(generation, state: &state)
            guard epoch == state.headEpoch else { return .none }
            state.status = .failed(error)
            return .none

        case .pageResponse(let epoch, let generation, .success(let response)):
            guard epoch == state.headEpoch else {
                settlePage(generation, state: &state)
                return .none
            }
            state.clips = merged(
                existing: state.clips,
                incoming: response.clips,
                suppressed: suppressedIDs(state)
            )
            state.nextCursor = response.nextCursor
            state.isPaging = false
            settlePage(generation, state: &state)
            return .none

        case .pageResponse(let epoch, let generation, .failure):
            settlePage(generation, state: &state)
            guard epoch == state.headEpoch else { return .none }
            state.isPaging = false
            return .none
        }
    }

    private static func fetchEffect(
        epoch: Int,
        generation: Int,
        cursor: String?,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: fetchID, cancelInFlight: true) { send in
            guard let result = await fetchResult(cursor: cursor, dependencies: dependencies),
                  Task.isCancelled == false else {
                return
            }
            await send(.clipsResponse(epoch: epoch, generation: generation, result))
        }
    }

    private static func deleteEffect(
        clip: Clip,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: "clip-delete-\(clip.id)", cancelInFlight: true) { send in
            await dependencies.clipCache.remove(clip.id)

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

    private static func pageEffect(
        cursor: String,
        epoch: Int,
        generation: Int,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: pageID) { send in
            guard let result = await fetchResult(cursor: cursor, dependencies: dependencies),
                  Task.isCancelled == false else {
                return
            }
            await send(.pageResponse(epoch: epoch, generation: generation, result))
        }
    }

    private static func issueRequest(state: inout State) -> Int {
        state.requestSeq += 1
        state.inFlightRequests.insert(state.requestSeq)
        return state.requestSeq
    }

    private static func settle(_ generation: Int?, state: inout State) {
        guard let generation else { return }
        state.inFlightRequests.remove(generation)
        pruneTombstones(state: &state)
    }

    private static func settleHead(_ generation: Int, state: inout State) {
        settle(generation, state: &state)
        if state.headRequest == generation {
            state.headRequest = nil
        }
    }

    private static func settlePage(_ generation: Int, state: inout State) {
        settle(generation, state: &state)
        if state.pageRequest == generation {
            state.pageRequest = nil
        }
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
        cursor: String?,
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

        for clip in existing where suppressed.contains(clip.id) == false {
            byID[clip.id] = clip
        }
        for clip in incoming where suppressed.contains(clip.id) == false {
            byID[clip.id] = clip
        }

        return byID.values.sorted { lhs, rhs in
            lhs.id > rhs.id
        }
    }

    private static func reconciledHead(
        existing: [Clip],
        pending: Set<Int>,
        response: ClipsResponse,
        suppressed: Set<Int>,
        requestEpoch: Int,
        finalizeEpoch: [Int: Int]
    ) -> HeadReconciliation {
        let lower = response.nextCursor.flatMap(Int.init) ?? 0
        let incomingIDs = Set(response.clips.map(\.id))
        let candidates = Set(existing.map(\.id)).union(pending)
        let authoritativeAbsent = candidates.filter { id in
            guard id >= lower else { return false }
            guard incomingIDs.contains(id) == false else { return false }
            return (finalizeEpoch[id] ?? Int.min) < requestEpoch
        }
        let filtered = suppressed.union(authoritativeAbsent)
        return HeadReconciliation(
            clips: merged(existing: existing, incoming: response.clips, suppressed: filtered),
            authoritativeAbsentIDs: authoritativeAbsent
        )
    }

    private struct HeadReconciliation {
        var clips: [Clip]
        var authoritativeAbsentIDs: Set<Int>
    }
}
