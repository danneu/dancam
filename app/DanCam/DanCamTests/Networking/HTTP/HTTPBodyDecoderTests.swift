import Foundation
import Testing
@testable import DanCam

struct HTTPBodyDecoderTests {
    @Test(.tags(.networking))
    func chunkedBodyReassemblesMultipartBoundarySplitByChunk() throws {
        let body = Data("abc\r\n--dancamframe\r\nheaders\r\n\r\njpeg".utf8)
        let head = head(headers: ["transfer-encoding": ["chunked"]])
        var decoder = HTTPBodyDecoder(head: head)
        let wire = MJPEGWireBuilder.chunked(body, chunkSizes: [5, 2, 7])

        let decoded = try decoder.append(wire).reduce(into: Data()) { $0.append($1) }

        #expect(decoded == body)
        #expect(decoder.isComplete)
    }

    @Test(.tags(.networking))
    func chunkSizeLineCanBeSplitAcrossAppends() throws {
        var decoder = HTTPBodyDecoder(head: head(headers: ["transfer-encoding": ["chunked"]]))

        #expect(try decoder.append(Data("a".utf8)).isEmpty)
        let decoded = try decoder.append(Data("\r\n0123456789\r\n0\r\n\r\n".utf8))

        #expect(decoded == [Data("0123456789".utf8)])
        #expect(decoder.isComplete)
    }

    @Test(.tags(.networking))
    func chunkPayloadCanBeReadAfterRemovingSizeLine() throws {
        var decoder = HTTPBodyDecoder(head: head(headers: ["transfer-encoding": ["chunked"]]))

        let decoded = try decoder.append(Data("3\r\nabc\r\n0\r\n\r\n".utf8))

        #expect(decoded == [Data("abc".utf8)])
        #expect(decoder.isComplete)
    }

    @Test(.tags(.networking))
    func chunkExtensionsAndTrailersAreIgnored() throws {
        var decoder = HTTPBodyDecoder(head: head(headers: ["transfer-encoding": ["chunked"]]))
        let wire = Data("5;foo=bar\r\nhello\r\n0\r\nX-Ignored: yes\r\n\r\n".utf8)

        let decoded = try decoder.append(wire)

        #expect(decoded == [Data("hello".utf8)])
        #expect(decoder.isComplete)
    }

    @Test(.tags(.networking))
    func contentLengthModePassesThroughOnlyDeclaredBytes() throws {
        var decoder = HTTPBodyDecoder(head: head(headers: ["content-length": ["5"]]))

        let decoded = try decoder.append(Data("helloignored".utf8))

        #expect(decoded == [Data("hello".utf8)])
        #expect(decoder.isComplete)
    }

    @Test(.tags(.networking))
    func closeDelimitedModePassesThroughUntilEOF() throws {
        var decoder = HTTPBodyDecoder(head: head(headers: [:]))

        #expect(try decoder.append(Data("hello".utf8)) == [Data("hello".utf8)])
        #expect(decoder.isComplete == false)
    }

    private func head(headers: [String: [String]]) -> HTTPResponseHead {
        HTTPResponseHead(statusCode: 200, reasonPhrase: "OK", headers: headers)
    }
}
