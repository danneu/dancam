import Testing
@testable import DanCam

struct WiFiOnboardingTests {
    @Test func parsesDanCamWiFiQRAndDerivesUnitIdentity() throws {
        let record = try WiFiQRCode.parse(
            "WIFI:T:WPA;S:dancam-0123456789;P:abcdefghijklmnopqrstuv;;"
        )
        #expect(record == WiFiOnboardingRecord(
            unitID: "0123456789",
            ssid: "dancam-0123456789",
            password: "abcdefghijklmnopqrstuv"
        ))
    }

    @Test func preservesEscapedWiFiCharacters() throws {
        let record = try WiFiQRCode.parse(
            "WIFI:T:WPA;S:dancam-0123456789;P:a\\;b\\:c\\,d\\\\efghijklmnopqr;;"
        )
        #expect(record.password == "a;b:c,d\\efghijklmnopqr")
    }

    @Test(arguments: [
        "https://example.com",
        "WIFI:T:nopass;S:dancam-0123456789;P:abcdefghijklmnopqrstuv;;",
        "WIFI:T:WPA;S:other-0123456789;P:abcdefghijklmnopqrstuv;;",
        "WIFI:T:WPA;S:dancam-xyz;P:abcdefghijklmnopqrstuv;;",
        "WIFI:T:WPA;S:dancam-0123456789;P:abcdefghijklmnopqrstuv\\",
    ])
    func rejectsMismatchedOnboardingData(_ payload: String) {
        #expect(throws: WiFiQRCodeError.self) { try WiFiQRCode.parse(payload) }
    }
}
