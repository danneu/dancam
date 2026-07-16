import AVFoundation
import CoreVideo
import Foundation
import Testing

@MainActor
func makeTemporaryPlayableVideoFile(
    at outputURL: URL? = nil,
    frameCount: Int = 1,
    frameDuration: CMTime = CMTime(value: 1, timescale: 30)
) async throws -> URL {
    let url = outputURL ?? FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ]
    )
    try #require(frameCount > 0)
    try #require(writer.canAdd(input))
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let pool = try #require(adaptor.pixelBufferPool)
    for index in 0..<frameCount {
        while input.isReadyForMoreMediaData == false {
            await Task.yield()
        }
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        try #require(result == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
        try #require(adaptor.append(buffer, withPresentationTime: presentationTime))
    }

    let endTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
    writer.endSession(atSourceTime: endTime)
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return url
}
