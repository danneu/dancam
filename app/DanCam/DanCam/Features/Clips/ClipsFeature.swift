import Foundation

enum ClipsFeature {
    struct State: Equatable {
        var clips: [Clip] = []
        var status: Status = .idle

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
        case clipsResponse(Result<ClipsResponse, ClipsError>)
    }

    private static let fetchID = "clips-fetch"

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .load, .refresh:
            state.status = .loading
            return fetchEffect(dependencies: dependencies)

        case .onDisappear:
            return .cancel(id: fetchID)

        case .clipFinalized(let clip):
            state.clips = merged(existing: state.clips, incoming: [clip])
            return .none

        case .clipsResponse(.success(let response)):
            state.clips = merged(existing: state.clips, incoming: response.clips)
            state.status = .idle
            return .none

        case .clipsResponse(.failure(let error)):
            state.status = .failed(error.displayMessage)
            return .none
        }
    }

    private static func fetchEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: fetchID, cancelInFlight: true) { send in
            do {
                let response = try await dependencies.clips.fetch()
                guard Task.isCancelled == false else { return }
                await send(.clipsResponse(.success(response)))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as ClipsError {
                guard Task.isCancelled == false else { return }
                await send(.clipsResponse(.failure(error)))
            } catch {
                guard Task.isCancelled == false else { return }
                await send(.clipsResponse(.failure(.transport(error.localizedDescription))))
            }
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
