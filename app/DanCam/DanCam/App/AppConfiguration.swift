import Foundation

nonisolated struct AppConfiguration: Equatable {
    static let cameraAPIBaseURLEnvironmentKey = "DANCAM_CAMERA_API_BASE_URL"
    static let cameraAPIBaseURLInfoKey = "DANCAMCameraAPIBaseURL"
    static let defaultCameraAPIBaseURL = URL(string: "http://10.42.0.1:8080")!

    var cameraAPIBaseURL: URL

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> AppConfiguration {
        AppConfiguration(
            cameraAPIBaseURL: configuredCameraAPIBaseURL(
                environment: environment,
                infoDictionary: infoDictionary
            )
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
}
