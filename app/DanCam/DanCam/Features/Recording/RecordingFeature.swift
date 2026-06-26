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
        case startTapped
        case stopTapped
        case recordingResponse(Result<Bool, RecordingError>)
        case statusObserved(recording: Bool)
    }

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .startTapped:
            state = .starting
            return .run(id: "recording", cancelInFlight: true) { send in
                do {
                    try await dependencies.recording.start()
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.success(true)))
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

        case .statusObserved(let isRecording):
            switch state {
            case .starting, .stopping:
                break
            case .unknown, .idle, .recording, .failed:
                state = isRecording ? .recording : .idle
            }
            return .none
        }
    }
}
