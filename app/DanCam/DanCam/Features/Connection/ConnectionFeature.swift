import Foundation

enum ConnectionFeature {
    struct State: Equatable {
        var connectivity: Connectivity = .connecting
        var consecutiveFailures = 0
        var lastStatus: StatusResponse?
    }

    nonisolated enum Connectivity: Equatable {
        case connecting
        case connected
        case disconnected
    }

    enum Action: Equatable {
        case start
        case stop
        case poll
        case statusResponse(Result<StatusResponse, StatusError>)
    }

    static let failureThreshold = 3
    private static let pollID = "connection-poll"
    private static let pollInterval = Duration.milliseconds(1500)

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .start:
            state.consecutiveFailures = 0
            return fetchEffect(dependencies: dependencies)

        case .stop:
            return .cancel(id: pollID)

        case .poll:
            return fetchEffect(dependencies: dependencies)

        case .statusResponse(.success(let response)):
            state.connectivity = .connected
            state.consecutiveFailures = 0
            state.lastStatus = response
            return schedulePoll(dependencies: dependencies)

        case .statusResponse(.failure):
            state.consecutiveFailures += 1
            if state.consecutiveFailures >= failureThreshold {
                state.connectivity = .disconnected
            }
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
