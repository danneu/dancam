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
        case statusResponse(Result<StatusResponse, StatusError>)
    }

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .onAppear:
            state = .unknown
            return statusEffect(dependencies: dependencies)

        case .startTapped:
            state = .starting
            return .run(id: "recording", cancelInFlight: true) { send in
                do {
                    try await dependencies.recording.start()
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.success(true)))
                    try await refreshStatus(send: send, dependencies: dependencies)
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
                    try await refreshStatus(send: send, dependencies: dependencies)
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

        case .statusResponse(.success(let response)):
            state = response.recording ? .recording : .idle
            return .none

        case .statusResponse(.failure(let error)):
            state = .failed(error.displayMessage)
            return .none
        }
    }

    private static func statusEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: "recording-status", cancelInFlight: true) { send in
            do {
                try await refreshStatus(send: send, dependencies: dependencies)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                return
            }
        }
    }

    private static func refreshStatus(
        send: (Action) async -> Void,
        dependencies: AppDependencies
    ) async throws {
        do {
            let response = try await dependencies.status.fetch()
            guard Task.isCancelled == false else { return }
            await send(.statusResponse(.success(response)))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as StatusError {
            guard Task.isCancelled == false else { return }
            await send(.statusResponse(.failure(error)))
        } catch {
            guard Task.isCancelled == false else { return }
            await send(.statusResponse(.failure(.transport(error.localizedDescription))))
        }
    }
}
