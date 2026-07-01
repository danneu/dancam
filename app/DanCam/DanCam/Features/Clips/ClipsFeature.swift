import Foundation

enum ClipsFeature {
    struct State: Equatable {
        var clips: [Clip] = []
        var status: Status = .idle
        var nextCursor: String?
        var isPaging = false
        var loadEpoch = 0

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
        case clipsResponse(Result<ClipsResponse, ClipsError>)
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
            return fetchEffect(cursor: nil, dependencies: dependencies)

        case .onDisappear:
            state.isPaging = false
            return .merge([
                .cancel(id: fetchID),
                .cancel(id: pageID),
            ])

        case .clipFinalized(let clip):
            state.clips = merged(existing: state.clips, incoming: [clip])
            return .none

        case .loadMore:
            guard let cursor = state.nextCursor, state.isPaging == false else {
                return .none
            }
            state.isPaging = true
            return pageEffect(
                cursor: cursor,
                epoch: state.loadEpoch,
                dependencies: dependencies
            )

        case .clipsResponse(.success(let response)):
            state.clips = merged(existing: state.clips, incoming: response.clips)
            state.status = .idle
            state.nextCursor = response.nextCursor
            state.loadEpoch += 1
            state.isPaging = false
            return .cancel(id: pageID)

        case .clipsResponse(.failure(let error)):
            state.status = .failed(error.displayMessage)
            return .none

        case .pageResponse(let epoch, .success(let response)):
            guard epoch == state.loadEpoch else { return .none }
            state.clips = merged(existing: state.clips, incoming: response.clips)
            state.nextCursor = response.nextCursor
            state.isPaging = false
            return .none

        case .pageResponse(let epoch, .failure):
            guard epoch == state.loadEpoch else { return .none }
            state.isPaging = false
            return .none
        }
    }

    private static func fetchEffect(
        cursor: String?,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: fetchID, cancelInFlight: true) { send in
            guard let result = await fetchResult(cursor: cursor, dependencies: dependencies),
                  Task.isCancelled == false else {
                return
            }
            await send(.clipsResponse(result))
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

    private static func merged(existing: [Clip], incoming: [Clip]) -> [Clip] {
        var byID: [Int: Clip] = [:]

        for clip in existing {
            byID[clip.id] = clip
        }
        for clip in incoming {
            byID[clip.id] = clip
        }

        return byID.values.sorted { lhs, rhs in
            lhs.id > rhs.id
        }
    }
}
