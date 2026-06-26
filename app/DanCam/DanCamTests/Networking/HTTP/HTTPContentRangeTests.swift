import Foundation
import Testing
@testable import DanCam

struct HTTPContentRangeTests {
    @Test(.tags(.networking))
    func httpEntityTagWrapsTheRawValueInLiteralQuotes() {
        // The two quote characters are part of the value -- a bare "\(etag)"
        // interpolation (no quotes) would regress here with no networking.
        #expect(httpEntityTag("1-7") == "\"1-7\"")
    }

    @Test(.tags(.networking))
    func parsesAWellFormedContentRange() {
        let parsed = HTTPContentRange.parse("bytes 0-3/12")
        #expect(parsed?.start == 0)
        #expect(parsed?.end == 3)
        #expect(parsed?.total == 12)
    }

    @Test(.tags(.networking))
    func parsesAResumeTail() {
        let parsed = HTTPContentRange.parse("bytes 5-11/12")
        #expect(parsed?.start == 5)
        #expect(parsed?.end == 11)
        #expect(parsed?.total == 12)
    }

    @Test(.tags(.networking))
    func rejectsAnUnknownTotal() {
        #expect(HTTPContentRange.parse("bytes */12") == nil)
    }

    @Test(.tags(.networking))
    func rejectsMalformedValues() {
        #expect(HTTPContentRange.parse("0-3/12") == nil)
        #expect(HTTPContentRange.parse("bytes 0-3") == nil)
        #expect(HTTPContentRange.parse("bytes 3-0/12") == nil)
        #expect(HTTPContentRange.parse("bytes abc/12") == nil)
        #expect(HTTPContentRange.parse("bytes 0-3/abc") == nil)
        #expect(HTTPContentRange.parse("") == nil)
    }
}
