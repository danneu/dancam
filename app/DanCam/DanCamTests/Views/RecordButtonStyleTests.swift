import Testing
@testable import DanCam

struct RecordButtonStyleTests {
    @Test func mapsRecordingStatesToButtonPresentation() {
        let cases: [
            (
                state: RecordingFeature.State,
                title: String,
                image: String?,
                enabled: Bool,
                busy: Bool
            )
        ] = [
            (.unknown, "Record", "record.circle", false, false),
            (.idle, "Record", "record.circle", true, false),
            (.failed("lost"), "Record", "record.circle", true, false),
            (.starting, "Starting", nil, false, true),
            (.recording, "Stop", "stop.fill", true, false),
            (.stopping, "Stopping", nil, false, true),
        ]

        for testCase in cases {
            let style = RecordButtonStyle.from(testCase.state)

            #expect(style.title == testCase.title)
            #expect(style.systemImage == testCase.image)
            #expect(style.isEnabled == testCase.enabled)
            #expect(style.showsActivityIndicator == testCase.busy)
        }
    }
}
