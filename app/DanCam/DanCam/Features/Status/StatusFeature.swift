import Foundation

enum StatusFeature {
    enum State: Equatable {
        case idle
        case loading
        case loaded(StatusResponse)
        case failed(String)
    }

    enum Action: Equatable {
        case onAppear
        case onDisappear
        case poll
        case statusResponse(Result<StatusResponse, StatusError>)
    }

    private static let pollID = "status-poll"
    private static let pollInterval = Duration.milliseconds(1500)

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .onAppear, .poll:
            if case .idle = state {
                state = .loading
            }
            return fetchEffect(dependencies: dependencies)

        case .onDisappear:
            return .cancel(id: pollID)

        case .statusResponse(.success(let response)):
            state = .loaded(response)
            return schedulePoll(dependencies: dependencies)

        case .statusResponse(.failure(let error)):
            state = .failed(error.displayMessage)
            return schedulePoll(dependencies: dependencies)
        }
    }

    private static func fetchEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: pollID, cancelInFlight: true) { send in
            do {
                let response = try await dependencies.status.fetch()
                guard Task.isCancelled == false else { return }
                await send(.statusResponse(.success(response)))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as StatusError {
                guard Task.isCancelled == false else { return }
                await send(.statusResponse(.failure(error)))
            } catch {
                guard Task.isCancelled == false else { return }
                await send(.statusResponse(.failure(.transport(error.localizedDescription))))
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
