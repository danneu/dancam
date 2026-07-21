#!/usr/bin/env swift
import Foundation
import Security

guard CommandLine.arguments.count == 3 else { exit(64) }
let imageID = CommandLine.arguments[1]
let boot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

struct Credentials: Decodable {
    let loginUser: String
    let authorizedKey: String
    let homeWiFiSSID: String
    let homeWiFiPSK: String
    let accessPointPSK: String

    enum CodingKeys: String, CodingKey {
        case loginUser = "login_user"
        case authorizedKey = "authorized_key"
        case homeWiFiSSID = "home_wifi_ssid"
        case homeWiFiPSK = "home_wifi_psk"
        case accessPointPSK = "access_point_psk"
    }
}

struct Envelope: Codable {
    let schema: String
    let imageID: String
    let profile: String
    let loginUser: String
    let authorizedKey: String
    let homeWiFiSSID: String
    let homeWiFiPSK: String
    let accessPointPSK: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case schema
        case imageID = "image_id"
        case profile
        case loginUser = "login_user"
        case authorizedKey = "authorized_key"
        case homeWiFiSSID = "home_wifi_ssid"
        case homeWiFiPSK = "home_wifi_psk"
        case accessPointPSK = "access_point_psk"
        case nonce
    }
}

func fail() -> Never {
    FileHandle.standardError.write(Data("invalid development personalization\n".utf8))
    exit(65)
}

func isSingleLinePrintable(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7f
    }
}

func isValidPSK(_ value: String) -> Bool {
    let bytes = value.utf8.count
    if bytes >= 8 && bytes <= 63 && isSingleLinePrintable(value) {
        return true
    }
    return bytes == 64 && value.allSatisfy { $0.isHexDigit }
}

func random(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw CocoaError(.fileWriteUnknown)
    }
    return Data(bytes)
}

let decoder = JSONDecoder()
guard
    let credentials = try? decoder.decode(
        Credentials.self,
        from: FileHandle.standardInput.readDataToEndOfFile()
    ),
    isSingleLinePrintable(imageID),
    isSingleLinePrintable(credentials.loginUser),
    credentials.loginUser.range(
        of: #"^[a-z_][a-z0-9_-]{0,31}$"#,
        options: .regularExpression
    ) != nil,
    isSingleLinePrintable(credentials.authorizedKey),
    credentials.authorizedKey.utf8.count <= 16_384,
    credentials.authorizedKey.range(
        of: #"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/]+={0,3}( .*)?$"#,
        options: .regularExpression
    ) != nil,
    (1...32).contains(credentials.homeWiFiSSID.utf8.count),
    isSingleLinePrintable(credentials.homeWiFiSSID),
    isValidPSK(credentials.homeWiFiPSK),
    isValidPSK(credentials.accessPointPSK)
else {
    fail()
}

let envelope = Envelope(
    schema: "dancam-development-commissioning-v1",
    imageID: imageID,
    profile: "development",
    loginUser: credentials.loginUser,
    authorizedKey: credentials.authorizedKey,
    homeWiFiSSID: credentials.homeWiFiSSID,
    homeWiFiPSK: credentials.homeWiFiPSK,
    accessPointPSK: credentials.accessPointPSK,
    nonce: try random(24).base64EncodedString()
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let directory = boot.appending(path: "dancam", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try encoder.encode(envelope).write(
    to: directory.appending(path: "commissioning.json"),
    options: [.atomic]
)
