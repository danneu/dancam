import Foundation

nonisolated enum HLSPlaylist {
    static func singleSegmentVOD(
        segmentURI: String,
        targetDuration: Int? = nil,
        durationSeconds: Double
    ) -> String {
        let roundedTargetDuration = max(Int(ceil(durationSeconds)), targetDuration ?? 0)
        let duration = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            durationSeconds
        )

        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(roundedTargetDuration)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(duration),
        \(segmentURI)
        #EXT-X-ENDLIST

        """
    }
}
