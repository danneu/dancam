import Foundation
import Testing
@testable import DanCam

struct TSDemuxerTests {
    @Test(.timeLimit(.minutes(1)))
    func demuxesBundledTransportStreamFixture() throws {
        let clip = try TSDemuxer.demuxH264(from: MediaFixtureURLs.seg00000TS())

        #expect(clip.timescale == 90_000)
        #expect(clip.accessUnits.count > 800)
        #expect(clip.sps.isEmpty == false)
        #expect(clip.pps.isEmpty == false)
        #expect(clip.accessUnits.first?.isKeyFrame == true)
        #expect(clip.accessUnits.contains { $0.isKeyFrame })
        #expect(abs(durationSeconds(clip) - 30.0) < 0.2)
    }

    @Test
    func rejectsUnalignedTransportStream() {
        #expect(throws: ClipRemuxError.invalidTransportStream("Transport stream size is not packet-aligned.")) {
            _ = try TSDemuxer.demuxH264(from: Data([0x47, 0x00]))
        }
    }

    private func durationSeconds(_ clip: DemuxedH264Clip) -> Double {
        Double(clip.durationTicks) / Double(clip.timescale)
    }
}
