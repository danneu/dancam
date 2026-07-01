import Foundation

nonisolated enum ProgressiveSegmenterEvent: Equatable, Sendable {
    case opened(workDirectory: URL)
    case firstPlayableReady(url: URL)
    /// Emitted once a finalized `#EXT-X-ENDLIST` playlist is being served, i.e. the whole clip is
    /// segmented and the loopback server now reports a finite duration. Intentionally not emitted
    /// for inputs that produced no media segment (no SPS/PPS, or SPS/PPS with zero access units):
    /// there is no finalized playlist, so a consumer waiting on `.finished` must not treat its
    /// absence as a hang on such inputs.
    case finished
}

nonisolated struct ProgressiveSegmenter: Sendable {
    var start: @Sendable (
        _ sourceURL: URL,
        _ clipID: Int,
        _ availability: AsyncStream<UInt64>
    ) -> AsyncThrowingStream<ProgressiveSegmenterEvent, Error>

    static let live = ProgressiveSegmenter { sourceURL, clipID, availability in
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ProgressiveSegmenterEvent.self,
            throwing: Error.self
        )
        let queue = DispatchQueue(
            label: "com.danneu.dancam.progressive-segmenter.\(clipID)",
            qos: .userInitiated
        )
        let pipeline = ProgressiveSegmenterPipeline(
            sourceURL: sourceURL,
            continuation: continuation
        )

        let feederTask = Task {
            for await bytesAvailable in availability {
                if Task.isCancelled { return }
                queue.async {
                    pipeline.advance(to: bytesAvailable)
                }
            }

            guard Task.isCancelled == false else { return }
            queue.async {
                pipeline.finishInput()
            }
        }

        continuation.onTermination = { @Sendable _ in
            feederTask.cancel()
            queue.async {
                pipeline.cancel()
            }
        }

        return stream
    }

    static let noop = ProgressiveSegmenter { _, _, availability in
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ProgressiveSegmenterEvent.self,
            throwing: Error.self
        )

        let drainTask = Task {
            for await _ in availability {
                if Task.isCancelled { return }
            }
            guard Task.isCancelled == false else { return }
            continuation.finish()
        }

        continuation.onTermination = { @Sendable _ in
            drainTask.cancel()
        }

        return stream
    }
}

nonisolated private final class ProgressiveSegmenterPipeline: @unchecked Sendable {
    private let sourceURL: URL
    /// Confined to the segmenter's serial demux `DispatchQueue`; never read or written from
    /// another domain (e.g. the loopback server's callback queue -- capture this Sendable
    /// continuation by value instead of reaching through the property).
    private var continuation: AsyncThrowingStream<ProgressiveSegmenterEvent, Error>.Continuation?

    private var fileHandle: FileHandle?
    private var demuxer = IncrementalTSDemuxer()
    private var assembler = StreamingH264AccessUnitAssembler()
    private var server: LoopbackMediaServer?
    private var segmenter: FMP4Segmenter?
    private var sps: Data?
    private var pps: Data?
    private var lastReadOffset: UInt64 = 0
    private var isCancelled = false
    private var didFinishInput = false
    private var didFail = false

    init(
        sourceURL: URL,
        continuation: AsyncThrowingStream<ProgressiveSegmenterEvent, Error>.Continuation
    ) {
        self.sourceURL = sourceURL
        self.continuation = continuation
    }

    deinit {
        cancel()
    }

    func advance(to bytesAvailable: UInt64) {
        guard canRun else { return }

        do {
            try startIfNeeded()
            guard bytesAvailable >= lastReadOffset else {
                throw ClipRemuxError.file("Progressive availability moved backwards.")
            }
            guard bytesAvailable > lastReadOffset else { return }

            let byteCount = bytesAvailable - lastReadOffset
            guard byteCount <= UInt64(Int.max) else {
                throw ClipRemuxError.file("Progressive read chunk is too large.")
            }
            guard let fileHandle else {
                throw ClipRemuxError.file("Progressive source was not opened.")
            }

            try fileHandle.seek(toOffset: lastReadOffset)
            let chunk = try fileHandle.read(upToCount: Int(byteCount)) ?? Data()
            guard UInt64(chunk.count) == byteCount else {
                throw ClipRemuxError.file("Progressive source did not contain advertised bytes.")
            }

            lastReadOffset = bytesAvailable
            try consume(packets: demuxer.append(chunk))
        } catch {
            fail(error)
        }
    }

    func finishInput() {
        guard canRun, didFinishInput == false else { return }
        didFinishInput = true

        do {
            try startIfNeeded()
            try consume(packets: demuxer.finish())
            try consume(output: assembler.finish())
            try segmenter?.finishWriting()
            try server?.checkForFailure()
            if server?.hasFinalizedPlaylist() == true {
                continuation?.yield(.finished)
            }
        } catch {
            fail(error)
        }
    }

    func cancel() {
        guard isCancelled == false else { return }

        isCancelled = true
        try? fileHandle?.close()
        fileHandle = nil
        server?.shutdown()
        server = nil
        continuation?.finish()
        continuation = nil
    }

    private var canRun: Bool {
        isCancelled == false && didFail == false
    }

    private func startIfNeeded() throws {
        guard fileHandle == nil else { return }

        // The server invokes this callback on its OWN serial queue. Capture the
        // continuation by value (it is Sendable and stable for the pipeline's life)
        // so the callback never reads this pipeline's demux-queue-confined
        // `continuation` across serial domains. A yield that races teardown is harmless:
        // dropped (`.terminated`) after finish(), else ignored by the consumer's state gate.
        let server = try LoopbackMediaServer { [continuation = self.continuation] url in
            continuation?.yield(.firstPlayableReady(url: url))
        }
        self.server = server
        continuation?.yield(.opened(workDirectory: server.workDirectory))
        fileHandle = try FileHandle(forReadingFrom: sourceURL)
    }

    private func consume(packets: [H264PESPacket]) throws {
        guard packets.isEmpty == false else { return }

        let output = assembler.append(packets)
        try consume(output: output)
    }

    private func consume(output: StreamingH264AccessUnitAssembler.Output) throws {
        if let outputSPS = output.sps {
            sps = outputSPS
        }
        if let outputPPS = output.pps {
            pps = outputPPS
        }

        if segmenter == nil, let sps, let pps {
            guard let server else {
                throw ClipRemuxError.writer("Progressive server was not started.")
            }
            let segmenter = FMP4Segmenter(sink: server)
            try segmenter.start(sps: sps, pps: pps)
            self.segmenter = segmenter
        }

        guard let segmenter else { return }
        for accessUnit in output.accessUnits {
            try segmenter.append(accessUnit)
            try server?.checkForFailure()
        }
    }

    private func fail(_ error: Error) {
        guard didFail == false else { return }

        didFail = true
        try? fileHandle?.close()
        fileHandle = nil
        server?.shutdown()
        server = nil
        continuation?.finish(throwing: error)
        continuation = nil
    }
}
