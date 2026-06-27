import AVFoundation
import Foundation
import os
import UniformTypeIdentifiers

nonisolated protocol FMP4SegmentSink: AnyObject, Sendable {
    func appendInitializationSegment(_ data: Data)
    func appendMediaSegment(_ data: Data, duration: CMTime)
    func finish()
}

nonisolated final class FMP4Segmenter: NSObject, AVAssetWriterDelegate {
    private let timescale: Int32
    private let sink: FMP4SegmentSink
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    init(
        timescale: Int32 = 90_000,
        sink: FMP4SegmentSink
    ) {
        self.timescale = timescale
        self.sink = sink
    }

    func start(sps: Data, pps: Data) throws {
        try throwPendingErrorIfNeeded()
        try state.withLockUnchecked { state in
            guard state.writer == nil else {
                throw ClipRemuxError.writer("FMP4 segmenter already started.")
            }
        }

        let formatDescription = try H264CoreMediaSamples.makeFormatDescription(
            sps: sps,
            pps: pps
        )
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = .indefinite
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            throw ClipRemuxError.writer("Could not add fMP4 video input.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw ClipRemuxError.writer(writer.error?.localizedDescription ?? "Could not start fMP4 writer.")
        }
        writer.startSession(atSourceTime: .zero)

        try state.withLockUnchecked { state in
            guard state.writer == nil else {
                writer.cancelWriting()
                throw ClipRemuxError.writer("FMP4 segmenter already started.")
            }
            state.writer = writer
            state.input = input
            state.formatDescription = formatDescription
        }
    }

    func append(_ accessUnit: H264AccessUnit) throws {
        try throwPendingErrorIfNeeded()
        let context = try requireContext()
        guard context.writer.status == .writing else {
            throw ClipRemuxError.writer(context.writer.error?.localizedDescription ?? "fMP4 writer is not writing.")
        }

        if accessUnit.isKeyFrame, context.sampleCount > 0 {
            context.writer.flushSegment()
            try throwPendingErrorIfNeeded()
        }

        while context.input.isReadyForMoreMediaData == false {
            Thread.sleep(forTimeInterval: 0.002)
            try throwPendingErrorIfNeeded()
            guard context.writer.status == .writing else {
                throw ClipRemuxError.writer(context.writer.error?.localizedDescription ?? "fMP4 writer stopped writing.")
            }
        }

        let rebasedAccessUnit = state.withLockUnchecked { state in
            state.rebased(accessUnit)
        }
        let sampleBuffer = try H264CoreMediaSamples.makeSampleBuffer(
            accessUnit: rebasedAccessUnit,
            formatDescription: context.formatDescription,
            timescale: timescale
        )
        guard context.input.append(sampleBuffer) else {
            throw ClipRemuxError.writer(context.writer.error?.localizedDescription ?? "Could not append fMP4 sample.")
        }

        state.withLockUnchecked { state in
            state.sampleCount += 1
        }
        try throwPendingErrorIfNeeded()
    }

    func finishWriting() throws {
        try throwPendingErrorIfNeeded()
        let context = try requireContext()

        if context.sampleCount > 0 {
            context.writer.flushSegment()
            try throwPendingErrorIfNeeded()
        }

        context.input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        context.writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        try throwPendingErrorIfNeeded()
        guard context.writer.status == .completed else {
            throw ClipRemuxError.writer(context.writer.error?.localizedDescription ?? "Could not finish fMP4 writer.")
        }

        sink.finish()
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        handleSegmentOutput(
            data: Data(segmentData),
            segmentType: segmentType,
            reportedDuration: segmentReport?.trackReports.first?.duration
        )
    }

    func handleSegmentOutput(
        data: Data,
        segmentType: AVAssetSegmentType,
        reportedDuration: CMTime?
    ) {
        switch segmentType {
        case .initialization:
            sink.appendInitializationSegment(data)
        case .separable:
            guard let duration = reportedDuration,
                  duration.isNumeric,
                  duration.seconds > 0 else {
                failProgressive(ClipRemuxError.writer("Missing or invalid fMP4 segment report."))
                return
            }
            sink.appendMediaSegment(data, duration: duration)
        @unknown default:
            break
        }
    }

    private func requireContext() throws -> WriterContext {
        try state.withLockUnchecked { state in
            guard let writer = state.writer,
                  let input = state.input,
                  let formatDescription = state.formatDescription else {
                throw ClipRemuxError.writer("FMP4 segmenter was not started.")
            }

            return WriterContext(
                writer: writer,
                input: input,
                formatDescription: formatDescription,
                sampleCount: state.sampleCount
            )
        }
    }

    private func failProgressive(_ error: ClipRemuxError) {
        state.withLockUnchecked { state in
            if state.pendingError == nil {
                state.pendingError = error
            }
        }
    }

    private func throwPendingErrorIfNeeded() throws {
        if let error = state.withLockUnchecked({ $0.pendingError }) {
            throw error
        }
    }

    private struct WriterContext {
        var writer: AVAssetWriter
        var input: AVAssetWriterInput
        var formatDescription: CMFormatDescription
        var sampleCount: Int
    }

    private struct State {
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var formatDescription: CMFormatDescription?
        var firstDecodeTicks: Int64?
        var sampleCount = 0
        var pendingError: ClipRemuxError?

        mutating func rebased(_ accessUnit: H264AccessUnit) -> H264AccessUnit {
            let firstDecodeTicks = firstDecodeTicks ?? accessUnit.dtsTicks
            self.firstDecodeTicks = firstDecodeTicks

            return H264AccessUnit(
                sampleData: accessUnit.sampleData,
                ptsTicks: accessUnit.ptsTicks - firstDecodeTicks,
                dtsTicks: accessUnit.dtsTicks - firstDecodeTicks,
                durationTicks: accessUnit.durationTicks,
                isKeyFrame: accessUnit.isKeyFrame,
                nalTypes: accessUnit.nalTypes
            )
        }
    }
}
