import Testing
@testable import DanCam

struct ContentTypeTests {
    @Test(.tags(.networking))
    func parsesMediaTypeCaseInsensitively() {
        #expect(ContentType.mediaType(from: "Multipart/X-Mixed-Replace; boundary=x") == "multipart/x-mixed-replace")
    }

    @Test(.tags(.networking))
    func parsesQuotedBoundaryWithExtraParameters() {
        let header = "multipart/x-mixed-replace; charset=utf-8; Boundary=\"dancamframe\""

        #expect(ContentType.boundary(from: header) == "dancamframe")
    }
}
