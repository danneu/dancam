import Foundation

enum RecordingFeature {
    enum State: Equatable {
        case unknown
        case idle
        case starting
        case recording
        case stopping
        case failed(String)
    }

    enum Action: Equatable {
        case onAppear
        case startTapped
        case stopTapped
        case recordingResponse(Result<Bool, RecordingError>)
        case healthResponse(Result<HealthResponse, HealthError>)
    }

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .onAppear:
            state = .unknown
            return healthEffect(dependencies: dependencies)

        case .startTapped:
            state = .starting
            return .run(id: "recording", cancelInFlight: true) { send in
                do {
                    try await dependencies.recording.start()
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.success(true)))
                    try await refreshHealth(send: send, dependencies: dependencies)
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch let error as RecordingError {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(error)))
                } catch {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(.transport(error.localizedDescription))))
                }
            }

        case .stopTapped:
            state = .stopping
            return .run(id: "recording", cancelInFlight: true) { send in
                do {
                    try await dependencies.recording.stop()
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.success(false)))
                    try await refreshHealth(send: send, dependencies: dependencies)
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch let error as RecordingError {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(error)))
                } catch {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(.transport(error.localizedDescription))))
                }
            }

        case .recordingResponse(.success(true)):
            state = .recording
            return .none

        case .recordingResponse(.success(false)):
            state = .idle
            return .none

        case .recordingResponse(.failure(let error)):
            state = .failed(error.displayMessage)
            return .none

        case .healthResponse(.success(let response)):
            state = response.recording ? .recording : .idle
            return .none

        case .healthResponse(.failure(let error)):
            state = .failed(error.displayMessage)
            return .none
        }
    }

    private static func healthEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: "recording-health", cancelInFlight: true) { send in
            do {
                try await refreshHealth(send: send, dependencies: dependencies)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                return
            }
        }
    }

    private static func refreshHealth(
        send: (Action) async -> Void,
        dependencies: AppDependencies
    ) async throws {
        do {
            let response = try await dependencies.health.fetch()
            guard Task.isCancelled == false else { return }
            await send(.healthResponse(.success(response)))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as HealthError {
            guard Task.isCancelled == false else { return }
            await send(.healthResponse(.failure(error)))
        } catch {
            guard Task.isCancelled == false else { return }
            await send(.healthResponse(.failure(.transport(error.localizedDescription))))
        }
    }
}
