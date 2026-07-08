import Foundation

enum ClipsFeature {
    struct State: Equatable {
        var clips: [Clip] = []
        var status: Status = .idle
        var nextCursor: String?
        var isPaging = false
        var pendingDeleteIDs: Set<Int> = []
        var suppressedClipIDs: Set<Int> = []
        var headEpoch = 0
        var hasLoadedOnce = false
        var clipFinalizeEpoch: [Int: Int] = [:]

        enum Status: Equatable {
            case idle
            case loading
            case failed(String)
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
        case clipsResponse(epoch: Int, Result<ClipsResponse, ClipsError>)
        case pageResponse(epoch: Int, Result<ClipsResponse, ClipsError>)
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
            state.status = .loading
            state.headEpoch += 1
            return fetchEffect(epoch: state.headEpoch, cursor: nil, dependencies: dependencies)

        case .onDisappear:
            state.isPaging = false
            return .merge([
                .cancel(id: fetchID),
                .cancel(id: pageID),
            ])

        case .clipFinalized(let clip):
            state.clipFinalizeEpoch[clip.id] = state.headEpoch
            state.clips = merged(
                existing: state.clips,
                incoming: [clip],
                suppressed: state.suppressedClipIDs
            )
            return .none

        case .loadMore:
            guard let cursor = state.nextCursor, state.isPaging == false else {
                return .none
            }
            state.isPaging = true
            return pageEffect(
                cursor: cursor,
                epoch: state.headEpoch,
                dependencies: dependencies
            )

        case .deleteTapped(let clip):
            state.pendingDeleteIDs.insert(clip.id)
            state.suppressedClipIDs.insert(clip.id)
            state.clips.removeAll { $0.id == clip.id }
            return deleteEffect(clip: clip, dependencies: dependencies)

        case .deleteResponse(let clip, .success):
            state.pendingDeleteIDs.remove(clip.id)
            return .none

        case .deleteResponse(let clip, .failure(.http(404))):
            state.pendingDeleteIDs.remove(clip.id)
            return .none

        case .deleteResponse(let clip, .failure(let error)):
            guard state.pendingDeleteIDs.contains(clip.id) else {
                return .none
            }
            state.pendingDeleteIDs.remove(clip.id)
            state.suppressedClipIDs.remove(clip.id)
            state.clips = merged(
                existing: state.clips,
                incoming: [clip],
                suppressed: state.suppressedClipIDs
            )
            state.status = .failed(error.displayMessage)
            return .none

        case .clipRemoved(let id):
            state.suppressedClipIDs.insert(id)
            state.pendingDeleteIDs.remove(id)
            state.clips.removeAll { $0.id == id }
            return .none

        case .clipsResponse(let epoch, .success(let response)):
            guard epoch == state.headEpoch else { return .none }
            let reconciliation = reconciledHead(
                existing: state.clips,
                pending: state.pendingDeleteIDs,
                response: response,
                suppressed: state.suppressedClipIDs,
                requestEpoch: epoch,
                finalizeEpoch: state.clipFinalizeEpoch
            )
            state.suppressedClipIDs.formUnion(reconciliation.authoritativeAbsentIDs)
            state.pendingDeleteIDs.subtract(reconciliation.authoritativeAbsentIDs)
            state.clips = reconciliation.clips
            state.status = .idle
            state.hasLoadedOnce = true
            state.nextCursor = response.nextCursor
            state.isPaging = false
            state.clipFinalizeEpoch = state.clipFinalizeEpoch.filter { $0.value >= epoch }
            return .cancel(id: pageID)

        case .clipsResponse(let epoch, .failure(let error)):
            guard epoch == state.headEpoch else { return .none }
            state.status = .failed(error.displayMessage)
            return .none

        case .pageResponse(let epoch, .success(let response)):
            guard epoch == state.headEpoch else { return .none }
            state.clips = merged(
                existing: state.clips,
                incoming: response.clips,
                suppressed: state.suppressedClipIDs
            )
            state.nextCursor = response.nextCursor
            state.isPaging = false
            return .none

        case .pageResponse(let epoch, .failure):
            guard epoch == state.headEpoch else { return .none }
            state.isPaging = false
            return .none
        }
    }

    private static func fetchEffect(
        epoch: Int,
        cursor: String?,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: fetchID, cancelInFlight: true) { send in
            guard let result = await fetchResult(cursor: cursor, dependencies: dependencies),
                  Task.isCancelled == false else {
                return
            }
            await send(.clipsResponse(epoch: epoch, result))
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
                await send(.deleteResponse(clip: clip, .failure(.transport(error.localizedDescription))))
            }
        }
    }

    private static func pageEffect(
        cursor: String,
        epoch: Int,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: pageID) { send in
            guard let result = await fetchResult(cursor: cursor, dependencies: dependencies),
                  Task.isCancelled == false else {
                return
            }
            await send(.pageResponse(epoch: epoch, result))
        }
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
            return .failure(.transport(error.localizedDescription))
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
