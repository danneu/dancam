import Foundation
import NetworkExtension

nonisolated struct WiFiOnboardingRecord: Codable, Equatable, Sendable {
    var unitID: String
    var ssid: String
    var password: String
}

nonisolated enum WiFiQRCodeError: Error, Equatable {
    case unsupported
    case malformed
}

nonisolated enum WiFiQRCode {
    static func parse(_ payload: String) throws -> WiFiOnboardingRecord {
        guard payload.hasPrefix("WIFI:") else { throw WiFiQRCodeError.unsupported }
        guard let fields = parseFields(String(payload.dropFirst(5))) else {
            throw WiFiQRCodeError.malformed
        }
        guard fields["T"] == "WPA",
              let ssid = fields["S"],
              let password = fields["P"],
              ssid.hasPrefix("dancam-") else {
            throw WiFiQRCodeError.malformed
        }
        let unitID = String(ssid.dropFirst("dancam-".count))
        guard unitID.count == 10,
              unitID.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              password.utf8.count >= 22 else {
            throw WiFiQRCodeError.malformed
        }
        return WiFiOnboardingRecord(unitID: unitID, ssid: ssid, password: password)
    }

    private static func parseFields(_ body: String) -> [String: String]? {
        var fields: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var escaped = false

        func commit() {
            if key.isEmpty == false { fields[key] = value }
            key = ""
            value = ""
            readingValue = false
        }

        func append(_ character: Character) {
            if readingValue { value.append(character) } else { key.append(character) }
        }

        for character in body {
            if escaped {
                append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ":", readingValue == false {
                readingValue = true
            } else if character == ";" {
                commit()
            } else {
                append(character)
            }
        }
        commit()
        guard escaped == false, key.isEmpty || readingValue else { return nil }
        return fields
    }
}

struct OnboardingClient: Sendable {
    var join: @Sendable (WiFiOnboardingRecord) async throws -> Void

    static let noop = OnboardingClient { _ in }

    static func live(recordsDirectory: URL) -> Self {
        Self { record in
            let configuration = NEHotspotConfiguration(
                ssid: record.ssid,
                passphrase: record.password,
                isWEP: false
            )
            configuration.joinOnce = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                NEHotspotConfigurationManager.shared.apply(configuration) { error in
                    if let error,
                       (error as NSError).code != NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

            try FileManager.default.createDirectory(
                at: recordsDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(
                to: recordsDirectory.appending(path: "\(record.unitID).json"),
                options: [.atomic, .completeFileProtection]
            )
        }
    }
}
