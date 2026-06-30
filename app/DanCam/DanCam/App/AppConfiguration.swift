import Foundation

nonisolated struct AppConfiguration: Equatable {
    static let cameraAPIBaseURLEnvironmentKey = "DANCAM_CAMERA_API_BASE_URL"
    static let cameraAPIBaseURLInfoKey = "DANCAMCameraAPIBaseURL"
    static let cameraAPIPinWiFiEnvironmentKey = "DANCAM_PIN_WIFI"
    static let cameraAPIPinWiFiInfoKey = "DANCAMPinWiFi"
    static let cameraAPIConnectTimeoutEnvironmentKey = "DANCAM_CONNECT_TIMEOUT_MS"
    static let defaultCameraAPIBaseURL = URL(string: "http://10.42.0.1:8080")!
    static let defaultCameraAPIConnectTimeout = Duration.seconds(2)

    var cameraAPIBaseURL: URL
    var cameraAPIInterfacePinning: InterfacePinning
    var cameraAPIConnectTimeout: Duration
    var heartbeatTimeout: Duration {
        .seconds(6)
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> AppConfiguration {
        let baseURL = configuredCameraAPIBaseURL(
            environment: environment,
            infoDictionary: infoDictionary
        )

        return AppConfiguration(
            cameraAPIBaseURL: baseURL,
            cameraAPIInterfacePinning: configuredCameraAPIInterfacePinning(
                environment: environment,
                infoDictionary: infoDictionary,
                baseURL: baseURL
            ),
            cameraAPIConnectTimeout: configuredCameraAPIConnectTimeout(environment: environment)
        )
    }

    static func configuredCameraAPIBaseURL(
        environment: [String: String],
        infoDictionary: [String: Any]
    ) -> URL {
        configuredURL(from: environment[cameraAPIBaseURLEnvironmentKey])
            ?? configuredURL(from: infoDictionary[cameraAPIBaseURLInfoKey] as? String)
            ?? defaultCameraAPIBaseURL
    }

    static func configuredCameraAPIInterfacePinning(
        environment: [String: String],
        infoDictionary: [String: Any],
        baseURL: URL
    ) -> InterfacePinning {
        configuredPinning(from: environment[cameraAPIPinWiFiEnvironmentKey])
            ?? configuredPinning(from: infoDictionary[cameraAPIPinWiFiInfoKey])
            ?? defaultPinning(for: baseURL)
    }

    static func configuredCameraAPIConnectTimeout(environment: [String: String]) -> Duration {
        configuredDuration(fromMilliseconds: environment[cameraAPIConnectTimeoutEnvironmentKey])
            ?? defaultCameraAPIConnectTimeout
    }

    private static func configuredURL(from value: String?) -> URL? {
        guard
            let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            rawValue.isEmpty == false,
            let url = URL(string: rawValue),
            url.scheme != nil,
            url.host != nil
        else {
            return nil
        }

        return url
    }

    private static func configuredDuration(fromMilliseconds value: String?) -> Duration? {
        guard
            let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            rawValue.isEmpty == false,
            let milliseconds = Int(rawValue),
            milliseconds > 0
        else {
            return nil
        }

        return .milliseconds(milliseconds)
    }

    private static func configuredPinning(from value: Any?) -> InterfacePinning? {
        if let value = value as? Bool {
            return value ? .wifi : .disabled
        }

        guard let rawValue = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes", "on", "wifi":
            return .wifi
        case "0", "false", "no", "off", "disabled":
            return .disabled
        default:
            return nil
        }
    }

    private static func defaultPinning(for baseURL: URL) -> InterfacePinning {
        guard let host = baseURL.host?.lowercased() else {
            return .wifi
        }

        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return .disabled
        }

        return .wifi
    }
}
