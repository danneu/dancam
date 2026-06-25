import Foundation
import Testing
@testable import DanCam

struct MultipartMJPEGParserTests {
    @Test(.tags(.networking))
    func parsesSingleContentLengthFrame() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary)
        let frame = Data([0xff, 0xd8, 0x01, 0xff, 0xd9])

        let frames = try parser.append(MJPEGWireBuilder.part(frame))

        #expect(frames == [frame])
    }

    @Test(.tags(.networking))
    func parsesBoundaryScannedFrameWithoutContentLength() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary)
        let f0 = Data("jpeg-zero".utf8)
        let f1 = Data("jpeg-one".utf8)
        var wire = MJPEGWireBuilder.part(f0, includeContentLength: false)
        wire.append(MJPEGWireBuilder.part(f1, includeContentLength: false))

        let frames = try parser.append(wire)

        #expect(frames == [f0])
        #expect(try parser.append(Data()) == [])
    }

    @Test(.tags(.networking))
    func parsesMultipleFramesPerChunk() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary)
        let f0 = Data("zero".utf8)
        let f1 = Data("one".utf8)
        var wire = MJPEGWireBuilder.part(f0)
        wire.append(MJPEGWireBuilder.part(f1))

        #expect(try parser.append(wire) == [f0, f1])
    }

    @Test(.tags(.networking))
    func frameCanBeSplitAcrossChunks() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary)
        let frame = Data("split-frame".utf8)
        let wire = MJPEGWireBuilder.part(frame)

        #expect(try parser.append(Data(wire.prefix(12))).isEmpty)
        #expect(try parser.append(Data(wire.dropFirst(12))) == [frame])
    }

    @Test(.tags(.networking))
    func boundaryDelimiterCanBeSplitAcrossChunks() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary)
        let frame = Data("jpeg".utf8)
        let wire = MJPEGWireBuilder.part(frame)
        let split = 4

        #expect(try parser.append(Data(wire.prefix(split))).isEmpty)
        #expect(try parser.append(Data(wire.dropFirst(split))) == [frame])
    }

    @Test(.tags(.networking))
    func preambleIsIgnoredAndHeaderNamesAreCaseInsensitive() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary)
        let frame = Data("jpeg".utf8)
        var wire = Data("preamble".utf8)
        wire.append(Data("--\(MJPEGWireBuilder.boundary)\r\ncontent-type: image/jpeg\r\nCONTENT-LENGTH: \(frame.count)\r\n\r\n".utf8))
        wire.append(frame)
        wire.append(Data("\r\n".utf8))

        #expect(try parser.append(wire) == [frame])
    }

    @Test(.tags(.networking))
    func contentLengthBodyCanContainBoundaryBytes() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary)
        let frame = Data("before\r\n--dancamframe\r\nafter".utf8)

        #expect(try parser.append(MJPEGWireBuilder.part(frame)) == [frame])
    }

    @Test(.tags(.networking))
    func oversizedUnterminatedPartThrows() throws {
        var parser = MultipartMJPEGParser(boundary: MJPEGWireBuilder.boundary, maxPartBytes: 4)
        let wire = Data("--dancamframe\r\nContent-Type: image/jpeg\r\n\r\n12345".utf8)

        do {
            _ = try parser.append(wire)
            Issue.record("Expected oversized part to throw.")
        } catch PreviewError.malformedResponse {
        } catch {
            Issue.record("Expected PreviewError.malformedResponse, got \(error).")
        }
    }
}
