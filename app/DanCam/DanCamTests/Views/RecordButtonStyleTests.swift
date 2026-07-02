import Testing
@testable import DanCam

struct RecordButtonStyleTests {
    @Test func mapsRecordingStatesToButtonPresentation() {
        let cases: [
            (
                state: RecordingFeature.State,
                title: String,
                image: String,
                enabled: Bool,
                treatment: RecordButtonTreatment,
                accessibilityLabel: String
            )
        ] = [
            (.unknown, "Record", "record.circle", false, .record, "Start recording"),
            (.idle, "Record", "record.circle", true, .record, "Start recording"),
            (.failed("lost"), "Record", "record.circle", true, .record, "Start recording"),
            (.starting, "Starting", "record.circle", false, .record, "Starting recording"),
            (.recording, "Stop", "stop.fill", true, .neutral, "Stop recording"),
            (.stopping, "Stopping", "stop.fill", false, .neutral, "Stopping recording"),
        ]

        for testCase in cases {
            let style = RecordButtonStyle.from(testCase.state)

            #expect(style.title == testCase.title)
            #expect(style.systemImage == testCase.image)
            #expect(style.isEnabled == testCase.enabled)
            #expect(style.treatment == testCase.treatment)
            #expect(style.accessibilityLabel == testCase.accessibilityLabel)
        }
    }
}
