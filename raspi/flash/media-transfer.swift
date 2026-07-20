import Darwin
import Foundation
import IOKit
import IOKit.storage

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("media-transfer: \(message)\n".utf8))
    exit(1)
}

func status(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

guard CommandLine.arguments.count == 5 else { exit(64) }
let operation = CommandLine.arguments[1]
let disk = CommandLine.arguments[2]
let expectedIdentity = CommandLine.arguments[3]
guard let byteCount = UInt64(CommandLine.arguments[4]) else { exit(64) }
guard operation == "write" || operation == "read" else { exit(64) }

let path = "/dev/r\(disk)"
let descriptor = open(path, operation == "write" ? O_WRONLY : O_RDONLY)
guard descriptor >= 0 else { fail("cannot open \(path): \(String(cString: strerror(errno)))") }
defer { close(descriptor) }

guard let service = IOServiceGetMatchingService(
    kIOMainPortDefault,
    IOBSDNameMatching(kIOMainPortDefault, 0, disk)
) as io_service_t?, service != 0 else { fail("media disappeared after open") }
defer { IOObjectRelease(service) }

func property(_ key: CFString) -> Any? {
    IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

var registryID: UInt64 = 0
guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
      let size = property(kIOMediaSizeKey as CFString) as? UInt64,
      let whole = property(kIOMediaWholeKey as CFString) as? Bool,
      let writable = property(kIOMediaWritableKey as CFString) as? Bool else {
    fail("cannot validate opened media")
}
let identity = "\(registryID):\(size):\(whole ? 1 : 0):\(writable ? 1 : 0)"
guard identity == expectedIdentity else { fail("opened media does not match approval") }

let chunkSize = 4 * 1024 * 1024
var buffer = [UInt8](repeating: 0, count: chunkSize)
var remaining = byteCount
var transferred: UInt64 = 0
let reportStep = max(byteCount / 100, UInt64(64 * 1024 * 1024))
var nextReport = reportStep
let started = Date()
let label = operation == "write" ? "Writing" : "Verifying"
let totalMiB = Double(byteCount) / 1_048_576
status(String(format: "%@: 0%% (0 / %.0f MiB)", label, totalMiB))

while remaining > 0 {
    let requested = min(chunkSize, Int(remaining))
    let source = operation == "write" ? STDIN_FILENO : descriptor
    let count = Darwin.read(source, &buffer, requested)
    guard count > 0 else {
        if count == 0 { fail("input ended before authenticated byte count") }
        if errno == EINTR { continue }
        fail("read failed: \(String(cString: strerror(errno)))")
    }

    let destination = operation == "write" ? descriptor : STDOUT_FILENO
    var offset = 0
    while offset < count {
        let written = buffer.withUnsafeBytes { bytes in
            Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
        }
        guard written > 0 else {
            if errno == EINTR { continue }
            fail("write failed: \(String(cString: strerror(errno)))")
        }
        offset += written
    }
    let copied = UInt64(count)
    remaining -= copied
    transferred += copied

    if transferred >= nextReport || remaining == 0 {
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        let transferredMiB = Double(transferred) / 1_048_576
        let percent = Double(transferred) * 100 / Double(byteCount)
        let rate = transferredMiB / elapsed
        status(String(
            format: "%@: %.0f%% (%.0f / %.0f MiB, %.1f MiB/s)",
            label,
            percent,
            transferredMiB,
            totalMiB,
            rate
        ))
        nextReport = byteCount - transferred <= reportStep ? byteCount : transferred + reportStep
    }
}

if operation == "write" {
    status("Writing: syncing buffered data")
    guard fsync(descriptor) == 0 else { fail("fsync failed: \(String(cString: strerror(errno)))") }
}
status("\(label): complete")
