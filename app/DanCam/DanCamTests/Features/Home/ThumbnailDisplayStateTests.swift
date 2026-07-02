import Foundation
import Testing
@testable import DanCam

struct ThumbnailDisplayStateTests {
    @Test func acceptsResultForCurrentlyShownIdentity() {
        var state = ThumbnailDisplayState()
        let identity = ClipThumbnailIdentity(id: 7, etag: "7-100")

        #expect(state.show(identity) == true)
        #expect(state.accepts(identity))
    }

    @Test func reshowingTheSameIdentityIsNotANewIdentity() {
        var state = ThumbnailDisplayState()
        let identity = ClipThumbnailIdentity(id: 7, etag: "7-100")

        #expect(state.show(identity) == true)
        #expect(state.show(identity) == false)
        #expect(state.accepts(identity))
    }

    @Test func dropsResultAfterDifferentIdReuse() {
        var state = ThumbnailDisplayState()
        #expect(state.show(ClipThumbnailIdentity(id: 7, etag: "7-100")) == true)
        #expect(state.show(ClipThumbnailIdentity(id: 8, etag: "8-100")) == true)

        #expect(state.accepts(ClipThumbnailIdentity(id: 7, etag: "7-100")) == false)
        #expect(state.accepts(ClipThumbnailIdentity(id: 8, etag: "8-100")))
    }

    @Test func dropsResultAfterSameIdDifferentEtagReconfiguration() {
        var state = ThumbnailDisplayState()
        #expect(state.show(ClipThumbnailIdentity(id: 7, etag: "7-100")) == true)
        #expect(state.show(ClipThumbnailIdentity(id: 7, etag: "7-200")) == true)

        // The guard keys on the whole (id, etag), not id alone.
        #expect(state.accepts(ClipThumbnailIdentity(id: 7, etag: "7-100")) == false)
        #expect(state.accepts(ClipThumbnailIdentity(id: 7, etag: "7-200")))
    }

    @Test func clearRejectsEveryIdentity() {
        var state = ThumbnailDisplayState()
        let identity = ClipThumbnailIdentity(id: 7, etag: "7-100")
        _ = state.show(identity)

        state.clear()

        #expect(state.accepts(identity) == false)
    }
}
