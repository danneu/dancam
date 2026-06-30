import Foundation
import Network
import Testing
@testable import DanCam

struct NWByteStreamTests {
    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func stalledReceiveSurfacesAsReceiveIdleTimeout() async throws {
        let server = try LoopbackByteServer { connection, queue in
            connection.start(queue: queue)
            Self.send(
                chunks: [Data("HTTP/1.1 200 OK\r\n".utf8)],
                everyMilliseconds: 0,
                finishAfterLastChunk: false,
                on: connection,
                queue: queue
            )
        }
        let url = try await server.start()
        defer { server.cancel() }
        let stream = try await NWByteStream.open(
            url: url,
            request: request(),
            pinning: .disabled,
            connectTimeout: .seconds(1),
            receiveIdleTimeout: .milliseconds(200)
        )

        do {
            _ = try await withTimeout(.seconds(2)) {
                try await collect(stream)
            }
            Issue.record("Expected receive idle timeout.")
        } catch NWByteStreamError.receiveIdleTimedOut {
        } catch TestTimeoutError.timedOut {
            Issue.record("Timed out waiting for receive idle timeout.")
        } catch {
            Issue.record("Expected receive idle timeout, got \(error).")
        }
    }

    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func slowButValidTransferSurvives() async throws {
        let chunks = [
            Data("HTTP/1.1 200 OK\r\n\r\n".utf8),
            Data("alpha".utf8),
            Data("beta".utf8),
            Data("gamma".utf8),
        ]
        let server = try LoopbackByteServer { connection, queue in
            connection.start(queue: queue)
            Self.send(
                chunks: chunks,
                everyMilliseconds: 75,
                finishAfterLastChunk: true,
                on: connection,
                queue: queue
            )
        }
        let url = try await server.start()
        defer { server.cancel() }
        let stream = try await NWByteStream.open(
            url: url,
            request: request(),
            pinning: .disabled,
            connectTimeout: .seconds(1),
            receiveIdleTimeout: .seconds(1)
        )

        let received = try await withTimeout(.seconds(2)) {
            try await collect(stream)
        }

        #expect(received == chunks.reduce(into: Data()) { $0.append($1) })
    }

    @Test(.tags(.networking), .timeLimit(.minutes(1)))
    func slowConsumerDoesNotTripIdleTimer() async throws {
        let chunks = [
            Data("HTTP/1.1 200 OK\r\n\r\n".utf8),
            Data("one".utf8),
            Data("two".utf8),
            Data("three".utf8),
        ]
        let server = try LoopbackByteServer { connection, queue in
            connection.start(queue: queue)
            Self.send(
                chunks: chunks,
                everyMilliseconds: 25,
                finishAfterLastChunk: true,
                on: connection,
                queue: queue
            )
        }
        let url = try await server.start()
        defer { server.cancel() }
        let stream = try await NWByteStream.open(
            url: url,
            request: request(),
            pinning: .disabled,
            connectTimeout: .seconds(1),
            receiveIdleTimeout: .milliseconds(250)
        )

        let received = try await withTimeout(.seconds(3)) {
            try await collect(stream, pausingAfterEachChunkFor: .milliseconds(400))
        }

        #expect(received == chunks.reduce(into: Data()) { $0.append($1) })
    }

    private func request() -> Data {
        Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
    }

    private func collect(
        _ stream: AsyncThrowingStream<Data, Error>,
        pausingAfterEachChunkFor pause: Duration? = nil
    ) async throws -> Data {
        var result = Data()

        for try await chunk in stream {
            result.append(chunk)

            if let pause {
                try await Task.sleep(for: pause)
            }
        }

        return result
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeoutError.timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw TestTimeoutError.timedOut
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func send(
        chunks: [Data],
        everyMilliseconds intervalMilliseconds: Int,
        finishAfterLastChunk: Bool,
        on connection: NWConnection,
        queue: DispatchQueue
    ) {
        for (index, chunk) in chunks.enumerated() {
            queue.asyncAfter(deadline: .now() + .milliseconds(index * intervalMilliseconds)) {
                let isLast = index == chunks.count - 1
                connection.send(
                    content: chunk,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        guard finishAfterLastChunk && isLast else { return }

                        connection.send(
                            content: nil,
                            contentContext: .finalMessage,
                            isComplete: true,
                            completion: .contentProcessed { _ in }
                        )
                    }
                )
            }
        }
    }
}

private enum TestTimeoutError: Error {
    case timedOut
}

private enum LoopbackByteServerError: Error {
    case missingPort
    case invalidURL
}

private final class LoopbackByteServer: @unchecked Sendable {
    typealias ConnectionHandler = @Sendable (NWConnection, DispatchQueue) -> Void

    private let queue = DispatchQueue(label: "com.danneu.dancam.tests.loopback-byte-server")
    private let listener: NWListener
    private let handler: ConnectionHandler
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(handler: @escaping ConnectionHandler) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let resumeOnce = OneShotContinuation(continuation)

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                switch state {
                case .ready:
                    guard let port = self.listener.port else {
                        resumeOnce.resume(throwing: LoopbackByteServerError.missingPort)
                        return
                    }
                    guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                        resumeOnce.resume(throwing: LoopbackByteServerError.invalidURL)
                        return
                    }
                    resumeOnce.resume(returning: url)
                case .failed(let error):
                    resumeOnce.resume(throwing: error)
                case .cancelled:
                    resumeOnce.resume(throwing: CancellationError())
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }

                self.append(connection)
                self.handler(connection, self.queue)
            }

            listener.start(queue: queue)
        }
    }

    func cancel() {
        listener.cancel()

        lock.lock()
        let connections = connections
        self.connections.removeAll()
        lock.unlock()

        for connection in connections {
            connection.cancel()
        }
    }

    private func append(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }
}

private final class OneShotContinuation<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, Error>?

    init(_ continuation: CheckedContinuation<Success, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Success) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Success, Error>? {
        lock.lock()
        defer { lock.unlock() }

        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}
