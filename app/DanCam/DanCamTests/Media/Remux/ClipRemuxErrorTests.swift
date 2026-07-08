import Foundation
import Testing
@testable import DanCam

struct ClipRemuxErrorTests {
    @Test(arguments: [
        (
            ClipRemuxError.invalidTransportStream("No H.264 PES packets found."),
            "Clip contains no playable video: No H.264 PES packets found."
        ),
        (
            ClipRemuxError.invalidH264("Missing SPS/PPS parameter sets."),
            "Clip video data is damaged: Missing SPS/PPS parameter sets."
        ),
        (
            ClipRemuxError.writer("Could not append sample."),
            "Could not prepare clip for playback: Could not append sample."
        ),
        (
            ClipRemuxError.file("Could not read output size."),
            "Could not read clip data: Could not read output size."
        ),
    ])
    func localizedDescriptionUsesHumanReadableRecoveryContext(
        error: ClipRemuxError,
        expected: String
    ) {
        #expect(error.localizedDescription == expected)
    }
}
