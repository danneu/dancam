import Foundation
import Testing
@testable import DanCam

struct AppConfigurationTests {
    @Test func defaultConfigurationUsesAPGatewayFallback() throws {
        let expected = try #require(URL(string: "http://10.42.0.1:8080"))
        let configuration = AppConfiguration.live(
            environment: [:],
            infoDictionary: [:]
        )

        #expect(configuration.cameraAPIBaseURL == expected)
        #expect(configuration.cameraAPIInterfacePinning == .wifi)
        #expect(configuration.cameraAPIConnectTimeout == .seconds(2))
        #expect(configuration.heartbeatTimeout == .seconds(6))
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

    @Test func loopbackBaseURLDefaultsToDisabledPinning() throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let pinning = AppConfiguration.configuredCameraAPIInterfacePinning(
            environment: [:],
            infoDictionary: [:],
            baseURL: baseURL
        )

        #expect(pinning == .disabled)
    }

    @Test func explicitEnvironmentPinningOverrideWinsOverInfoPlist() throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let pinning = AppConfiguration.configuredCameraAPIInterfacePinning(
            environment: [AppConfiguration.cameraAPIPinWiFiEnvironmentKey: "1"],
            infoDictionary: [AppConfiguration.cameraAPIPinWiFiInfoKey: false],
            baseURL: baseURL
        )

        #expect(pinning == .wifi)
    }

    @Test func explicitInfoPlistPinningOverrideIsUsedWhenEnvironmentIsMissing() throws {
        let baseURL = try #require(URL(string: "http://10.42.0.1:8080"))
        let pinning = AppConfiguration.configuredCameraAPIInterfacePinning(
            environment: [:],
            infoDictionary: [AppConfiguration.cameraAPIPinWiFiInfoKey: false],
            baseURL: baseURL
        )

        #expect(pinning == .disabled)
    }

    @Test func validConnectTimeoutOverrideDoesNotChangeHeartbeatTimeout() {
        let configuration = AppConfiguration.live(
            environment: [
                AppConfiguration.cameraAPIConnectTimeoutEnvironmentKey: "5000",
            ],
            infoDictionary: [:]
        )

        #expect(configuration.cameraAPIConnectTimeout == .seconds(5))
        #expect(configuration.heartbeatTimeout == .seconds(6))
    }

    @Test func invalidConnectTimeoutOverridesFallBackToDefault() {
        for rawValue in ["abc", "0", "-1"] {
            let configuration = AppConfiguration.live(
                environment: [
                    AppConfiguration.cameraAPIConnectTimeoutEnvironmentKey: rawValue,
                ],
                infoDictionary: [:]
            )

            #expect(configuration.cameraAPIConnectTimeout == .seconds(2))
            #expect(configuration.heartbeatTimeout == .seconds(6))
        }
    }
}
