import Foundation

enum ClipsFeature {
    enum State: Equatable {
        case idle
        case loading
        case loaded([Clip])
        case failed(String)
    }

    enum Action: Equatable {
        case onAppear
        case onDisappear
        case poll
        case refresh
        case clipsResponse(Result<ClipsResponse, ClipsError>)
    }

    private static let pollID = "clips-poll"
    private static let pollInterval = Duration.seconds(10)

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .onAppear, .poll, .refresh:
            if case .idle = state {
                state = .loading
            }
            return fetchEffect(dependencies: dependencies)

        case .onDisappear:
            return .cancel(id: pollID)

        case .clipsResponse(.success(let response)):
            state = .loaded(response.clips)
            return schedulePoll(dependencies: dependencies)

        case .clipsResponse(.failure(let error)):
            state = .failed(error.displayMessage)
            return schedulePoll(dependencies: dependencies)
        }
    }

    private static func fetchEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: pollID, cancelInFlight: true) { send in
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

    private static func schedulePoll(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: pollID, cancelInFlight: true) { send in
            await dependencies.sleep(pollInterval)
            guard Task.isCancelled == false else { return }
            await send(.poll)
        }
    }
}
