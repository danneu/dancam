import Foundation
import Testing
@testable import DanCam

struct HLSPlaylistTests {
    @Test(.tags(.networking))
    func singleSegmentVODUsesCeiledTargetDurationAndRelativeSegment() {
        let playlist = HLSPlaylist.singleSegmentVOD(
            segmentURI: "segment.ts",
            durationSeconds: 29.2
        )

        #expect(playlist == """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:30
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:29.200,
        segment.ts
        #EXT-X-ENDLIST

        """)
    }
}
