#!/usr/bin/env swift
import CoreGraphics
import CoreImage
import Foundation
import Security
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4 else { exit(64) }
let imageID = CommandLine.arguments[1]
let boot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let recovery = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

func random(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw CocoaError(.fileWriteUnknown)
    }
    return Data(bytes)
}

let unitID = try random(5).map { String(format: "%02x", $0) }.joined()
let ssid = "dancam-\(unitID)"
let psk = try random(24).base64EncodedString()
let nonce = try random(24).base64EncodedString()

struct Envelope: Codable {
    let schema: String
    let imageID: String
    let unitID: String
    let ssid: String
    let psk: String
    let nonce: String
}

let encoder = JSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let envelope = Envelope(
    schema: "dancam-commissioning-v1",
    imageID: imageID,
    unitID: unitID,
    ssid: ssid,
    psk: psk,
    nonce: nonce
)
let directory = boot.appending(path: "dancam", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try encoder.encode(envelope).write(
    to: directory.appending(path: "commissioning.json"),
    options: [.atomic]
)

try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
let record = recovery.appending(path: "dancam-\(unitID).txt")
try "DanCam \(unitID)\nSSID: \(ssid)\nPassword: \(psk)\n"
    .data(using: .utf8)!.write(to: record, options: [.atomic])
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)

func escapedWiFiField(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: ";", with: "\\;")
        .replacingOccurrences(of: ",", with: "\\,")
        .replacingOccurrences(of: ":", with: "\\:")
}
let payload = "WIFI:T:WPA;S:\(escapedWiFiField(ssid));P:\(escapedWiFiField(psk));;"
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(payload.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let context = CIContext(options: [.useSoftwareRenderer: true])
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let png = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace) else {
    throw CocoaError(.fileWriteUnknown)
}
let qr = recovery.appending(path: "dancam-\(unitID)-setup.png")
try png.write(to: qr, options: [.atomic])
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: qr.path)

print(unitID)
