import Foundation

enum HealthFeature {
    enum State: Equatable {
        case idle
        case loading
        case loaded(HealthResponse)
        case failed(String)
    }

    enum Action: Equatable {
        case onAppear
        case reload
        case healthResponse(Result<HealthResponse, HealthError>)
    }

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .onAppear, .reload:
            state = .loading
            return .run(id: "health", cancelInFlight: true) { send in
                do {
                    let response = try await dependencies.health.fetch()
                    guard Task.isCancelled == false else { return }
                    await send(.healthResponse(.success(response)))
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch let error as HealthError {
                    guard Task.isCancelled == false else { return }
                    await send(.healthResponse(.failure(error)))
                } catch {
                    guard Task.isCancelled == false else { return }
                    await send(.healthResponse(.failure(.transport(error.localizedDescription))))
                }
            }

        case .healthResponse(.success(let response)):
            state = .loaded(response)
            return .none

        case .healthResponse(.failure(let error)):
            state = .failed(error.displayMessage)
            return .none
        }
    }
}
