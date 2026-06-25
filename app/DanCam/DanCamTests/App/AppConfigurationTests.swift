import Foundation
import Testing
@testable import DanCam

struct AppConfigurationTests {
    @Test func defaultConfigurationUsesAPGatewayFallback() throws {
        let expected = try #require(URL(string: "http://10.42.0.1:8080"))
        let url = AppConfiguration.configuredCameraAPIBaseURL(
            environment: [:],
            infoDictionary: [:]
        )

        #expect(url == expected)
    }

    @Test func environmentOverrideWinsOverInfoPlistOverride() throws {
        let expected = try #require(URL(string: "http://127.0.0.1:8080"))
        let url = AppConfiguration.configuredCameraAPIBaseURL(
            environment: [
                AppConfiguration.cameraAPIBaseURLEnvironmentKey: "http://127.0.0.1:8080",
            ],
            infoDictionary: [
                AppConfiguration.cameraAPIBaseURLInfoKey: "http://dancam.local:8080",
            ]
        )

        #expect(url == expected)
    }

    @Test func infoPlistOverrideIsUsedWhenEnvironmentOverrideIsMissing() throws {
        let expected = try #require(URL(string: "http://dancam.local:8080"))
        let url = AppConfiguration.configuredCameraAPIBaseURL(
            environment: [:],
            infoDictionary: [
                AppConfiguration.cameraAPIBaseURLInfoKey: "http://dancam.local:8080",
            ]
        )

        #expect(url == expected)
    }

    @Test func invalidOverridesFallBackToAPGateway() throws {
        let expected = try #require(URL(string: "http://10.42.0.1:8080"))
        let url = AppConfiguration.configuredCameraAPIBaseURL(
            environment: [
                AppConfiguration.cameraAPIBaseURLEnvironmentKey: "not a url",
            ],
            infoDictionary: [
                AppConfiguration.cameraAPIBaseURLInfoKey: "",
            ]
        )

        #expect(url == expected)
    }
}
