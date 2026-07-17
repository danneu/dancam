import AVFoundation
import Foundation
import OSLog

nonisolated enum ClipRemuxerEngine {
    @concurrent
    static func remux(
        sourceURL: URL,
        outputURL: URL,
        clipID: Int
    ) async throws -> ClipRemuxResult {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let sourceBytes = try fileSize(sourceURL)
        Log.remux.notice(
            "clip_id=\(clipID, privacy: .public) phase=remux_start source_bytes=\(sourceBytes, privacy: .public)"
        )

        let clip = try TSDemuxer.demuxH264(from: sourceURL, clipID: clipID)
        Log.remux.debug(
            "clip_id=\(clipID, privacy: .public) first_decode_ticks=\(clip.firstDecodeTicks, privacy: .public)"
        )

        let result = try await write(clip: clip, to: outputURL)
        Log.remux.notice(
            "clip_id=\(clipID, privacy: .public) phase=remux_finish out_bytes=\(result.bytes, privacy: .public) duration_s=\(seconds(in: result.duration), privacy: .public)"
        )
        return result
    }

    static func write(
        clip: DemuxedH264Clip,
        to outputURL: URL
    ) async throws -> ClipRemuxResult {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let formatDescription = try H264CoreMediaSamples.makeFormatDescription(
            sps: clip.sps,
            pps: clip.pps
        )
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            throw ClipRemuxError.writer("Could not add video input.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw ClipRemuxError.writer(writer.error?.localizedDescription ?? "Could not start MP4 writer.")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            for accessUnit in clip.accessUnits {
                try Task.checkCancellation()
                while input.isReadyForMoreMediaData == false {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(2))
                }

                let sampleBuffer = try H264CoreMediaSamples.makeSampleBuffer(
                    accessUnit: accessUnit.rebased(bySubtracting: clip.firstDecodeTicks),
                    formatDescription: formatDescription,
                    timescale: clip.timescale
                )
                guard input.append(sampleBuffer) else {
                    throw ClipRemuxError.writer(writer.error?.localizedDescription ?? "Could not append sample.")
                }
            }

            input.markAsFinished()
            try await finish(writer)
        } catch {
            writer.cancelWriting()
            try? fileManager.removeItem(at: outputURL)
            throw error
        }

        guard writer.status == .completed else {
            try? fileManager.removeItem(at: outputURL)
            throw ClipRemuxError.writer(writer.error?.localizedDescription ?? "MP4 writer did not complete.")
        }

        let bytes = try fileSize(outputURL)
        return ClipRemuxResult(
            fileURL: outputURL,
            duration: duration(fromTicks: clip.durationTicks, timescale: clip.timescale),
            bytes: bytes
        )
    }

    private static func finish(_ writer: AVAssetWriter) async throws {
        await writer.finishWriting()
        try Task.checkCancellation()

        guard writer.status == .completed else {
            throw ClipRemuxError.writer(writer.error?.localizedDescription ?? "Could not finish MP4 writer.")
        }
    }

    private static func duration(fromTicks ticks: Int64, timescale: Int32) -> Duration {
        .nanoseconds(Int64(Double(ticks) * 1_000_000_000.0 / Double(timescale)))
    }

    private static func seconds(in duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ClipRemuxError.file("Could not read output size.")
        }
        return size.uint64Value
    }
}

nonisolated enum H264CoreMediaSamples {
    static func makeFormatDescription(
        sps: Data,
        pps: Data
    ) throws -> CMFormatDescription {
        var formatDescription: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                var parameterSetPointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                var parameterSetSizes = [sps.count, pps.count]

                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSetPointers.count,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }

        guard status == noErr, let formatDescription else {
            throw ClipRemuxError.invalidH264("Could not create H.264 format description (\(status)).")
        }

        return formatDescription
    }

    static func makeSampleBuffer(
        accessUnit: H264AccessUnit,
        formatDescription: CMFormatDescription,
        timescale: Int32
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: accessUnit.sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: accessUnit.sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw ClipRemuxError.writer("Could not create sample block buffer (\(status)).")
        }

        status = accessUnit.sampleData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: accessUnit.sampleData.count
            )
        }
        guard status == noErr else {
            throw ClipRemuxError.writer("Could not copy sample bytes (\(status)).")
        }

        var timing = CMSampleTimingInfo(
            duration: cmTime(accessUnit.durationTicks, timescale: timescale),
            presentationTimeStamp: cmTime(accessUnit.ptsTicks, timescale: timescale),
            decodeTimeStamp: cmTime(accessUnit.dtsTicks, timescale: timescale)
        )
        var sampleSize = accessUnit.sampleData.count
        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw ClipRemuxError.writer("Could not create sample buffer (\(status)).")
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
           ) as? [NSMutableDictionary],
           let attachment = attachments.first {
            attachment[kCMSampleAttachmentKey_DependsOnOthers as String] = accessUnit.isKeyFrame == false
            if accessUnit.isKeyFrame == false {
                attachment[kCMSampleAttachmentKey_NotSync as String] = true
            }
        }

        return sampleBuffer
    }

    static func cmTime(_ ticks: Int64, timescale: Int32) -> CMTime {
        CMTime(value: ticks, timescale: timescale)
    }
}

private extension H264AccessUnit {
    nonisolated func rebased(bySubtracting firstDecodeTicks: Int64) -> H264AccessUnit {
        H264AccessUnit(
            sampleData: sampleData,
            ptsTicks: ptsTicks - firstDecodeTicks,
            dtsTicks: dtsTicks - firstDecodeTicks,
            durationTicks: durationTicks,
            isKeyFrame: isKeyFrame,
            nalTypes: nalTypes
        )
    }
}
