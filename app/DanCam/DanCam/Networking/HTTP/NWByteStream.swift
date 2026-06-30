import Foundation
import Network

nonisolated enum NWByteStreamError: Error, Equatable {
    case missingHost
    case invalidPort
    case connectTimedOut
    case receiveIdleTimedOut
}

nonisolated enum NWByteStream {
    static func open(
        url: URL,
        request: Data,
        pinning: InterfacePinning,
        connectTimeout: Duration,
        receiveIdleTimeout: Duration
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard let host = url.host else {
            throw NWByteStreamError.missingHost
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? defaultPort(for: url.scheme))) else {
            throw NWByteStreamError.invalidPort
        }

        let parameters = NWParameters.tcp
        if pinning == .wifi {
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaceTypes = [.cellular]
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: parameters
        )
        let lifecycle = NWConnectionLifecycle(connection)
        let queue = DispatchQueue(label: "com.danneu.dancam.nw-byte-stream")
        let queueKey = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: queueKey, value: true)

        try await start(
            connection: connection,
            lifecycle: lifecycle,
            queue: queue,
            connectTimeout: connectTimeout
        )
        try await send(request, on: connection, lifecycle: lifecycle)

        return AsyncThrowingStream { continuation in
            let receiveResolution = receive(
                from: connection,
                lifecycle: lifecycle,
                queue: queue,
                queueKey: queueKey,
                receiveIdleTimeout: receiveIdleTimeout,
                continuation: continuation
            )

            continuation.onTermination = { _ in
                lifecycle.cancel()
                receiveResolution.terminate()
            }
        }
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https":
            443
        default:
            80
        }
    }

    private static func start(
        connection: NWConnection,
        lifecycle: NWConnectionLifecycle,
        queue: DispatchQueue,
        connectTimeout: Duration
    ) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resolution = NWConnectionStartResolution(
                    connection: connection,
                    continuation: continuation
                )

                let deadline = DispatchWorkItem {
                    lifecycle.cancel()
                    resolution.finish(.failure(NWByteStreamError.connectTimedOut))
                }
                resolution.setDeadline(deadline)
                queue.asyncAfter(
                    deadline: .now() + dispatchInterval(for: connectTimeout),
                    execute: deadline
                )

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resolution.finish(.success(()))
                    case .failed(let error):
                        resolution.finish(.failure(error))
                    case .cancelled:
                        resolution.finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }

                do {
                    try lifecycle.start(on: queue)
                } catch {
                    queue.async {
                        resolution.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            lifecycle.cancel()
        }
    }

    fileprivate static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let attosecondMilliseconds = components.attoseconds / attosecondsPerMillisecond
        let roundedRemainder: Int64 = components.attoseconds % attosecondsPerMillisecond == 0 ? 0 : 1
        let totalMilliseconds = components.seconds * 1_000 + attosecondMilliseconds + roundedRemainder
        let cappedMilliseconds = min(max(totalMilliseconds, 1), Int64(Int.max))
        return .milliseconds(Int(cappedMilliseconds))
    }

    private static func send(
        _ data: Data,
        on connection: NWConnection,
        lifecycle: NWConnectionLifecycle
    ) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            lifecycle.cancel()
            throw error
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            lifecycle.cancel()
        }
    }

    private static func receive(
        from connection: NWConnection,
        lifecycle: NWConnectionLifecycle,
        queue: DispatchQueue,
        queueKey: DispatchSpecificKey<Bool>,
        receiveIdleTimeout: Duration,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) -> NWConnectionReceiveResolution {
        let resolution = NWConnectionReceiveResolution(
            connection: connection,
            lifecycle: lifecycle,
            queue: queue,
            queueKey: queueKey,
            receiveIdleTimeout: receiveIdleTimeout,
            continuation: continuation
        )
        queue.async {
            resolution.start()
        }
        return resolution
    }
}

// Swift cannot express this queue affinity: setDeadline runs before start, and
// finish is called only on the connection queue.
nonisolated private final class NWConnectionStartResolution: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, Error>
    private var didResume = false
    private var deadlineWorkItem: DispatchWorkItem?

    init(connection: NWConnection, continuation: CheckedContinuation<Void, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func setDeadline(_ deadlineWorkItem: DispatchWorkItem) {
        self.deadlineWorkItem = deadlineWorkItem
    }

    func finish(_ result: Result<Void, Error>) {
        guard didResume == false else { return }
        didResume = true
        connection.stateUpdateHandler = nil
        deadlineWorkItem?.cancel()

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

// Swift cannot express this queue affinity: start, receive callbacks, deadline
// rearming, and termination all serialize through the connection queue.
nonisolated private final class NWConnectionReceiveResolution: @unchecked Sendable {
    private let connection: NWConnection
    private let lifecycle: NWConnectionLifecycle
    private let queue: DispatchQueue
    private let queueKey: DispatchSpecificKey<Bool>
    private let receiveIdleTimeout: Duration
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var didFinish = false
    private var idleWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        lifecycle: NWConnectionLifecycle,
        queue: DispatchQueue,
        queueKey: DispatchSpecificKey<Bool>,
        receiveIdleTimeout: Duration,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        self.connection = connection
        self.lifecycle = lifecycle
        self.queue = queue
        self.queueKey = queueKey
        self.receiveIdleTimeout = receiveIdleTimeout
        self.continuation = continuation
    }

    func start() {
        guard didFinish == false else { return }

        armDeadline()
        receiveNext()
    }

    func terminate() {
        runOnQueue {
            guard self.didFinish == false else { return }

            self.didFinish = true
            self.idleWorkItem?.cancel()
            self.idleWorkItem = nil
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            guard self.didFinish == false else { return }

            self.idleWorkItem?.cancel()
            self.idleWorkItem = nil

            if let data, data.isEmpty == false {
                self.continuation.yield(data)
            }

            if let error {
                self.finish(.failure(error), cancelConnection: false)
            } else if isComplete {
                self.finish(.success(()), cancelConnection: false)
            } else {
                self.armDeadline()
                self.receiveNext()
            }
        }
    }

    private func armDeadline() {
        idleWorkItem?.cancel()

        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(.failure(NWByteStreamError.receiveIdleTimedOut), cancelConnection: true)
        }
        idleWorkItem = deadline
        queue.asyncAfter(
            deadline: .now() + NWByteStream.dispatchInterval(for: receiveIdleTimeout),
            execute: deadline
        )
    }

    private func finish(_ result: Result<Void, Error>, cancelConnection: Bool) {
        guard didFinish == false else { return }

        didFinish = true
        idleWorkItem?.cancel()
        idleWorkItem = nil

        if cancelConnection {
            lifecycle.cancel()
        }

        switch result {
        case .success:
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
    }

    private func runOnQueue(_ operation: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }
}

nonisolated private final class NWConnectionLifecycle: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var isStarted = false
    private var isCancelled = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(on queue: DispatchQueue) throws {
        lock.lock()
        defer { lock.unlock() }

        if isCancelled {
            throw CancellationError()
        }

        isStarted = true
        connection.start(queue: queue)
    }

    func cancel() {
        let shouldCancel: Bool

        lock.lock()
        if isCancelled {
            shouldCancel = false
        } else {
            isCancelled = true
            shouldCancel = isStarted
        }
        lock.unlock()

        if shouldCancel {
            connection.cancel()
        }
    }
}
