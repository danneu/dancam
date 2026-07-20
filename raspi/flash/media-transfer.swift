import CryptoKit
import Darwin
import DiskArbitration
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

func hexDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

func update(_ hasher: inout SHA256, from bytes: [UInt8], count: Int) {
    bytes.withUnsafeBytes { buffer in
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer.prefix(count)))
    }
}

func readExact(_ descriptor: Int32, into buffer: inout [UInt8], count: Int, offset: Int64) {
    var completed = 0
    while completed < count {
        let result = buffer.withUnsafeMutableBytes { bytes in
            pread(
                descriptor,
                bytes.baseAddress!.advanced(by: completed),
                count - completed,
                offset + Int64(completed)
            )
        }
        guard result > 0 else {
            if result < 0, errno == EINTR { continue }
            if result == 0 { fail("device ended before authenticated byte count") }
            fail("read failed: \(String(cString: strerror(errno)))")
        }
        completed += result
    }
}

func writeExact(_ descriptor: Int32, bytes: Data, offset: Int64) {
    var completed = 0
    bytes.withUnsafeBytes { buffer in
        while completed < buffer.count {
            let result = pwrite(
                descriptor,
                buffer.baseAddress!.advanced(by: completed),
                buffer.count - completed,
                offset + Int64(completed)
            )
            guard result > 0 else {
                if errno == EINTR { continue }
                fail("write failed: \(String(cString: strerror(errno)))")
            }
            completed += result
        }
    }
}

func readInput(into buffer: inout [UInt8], count: Int) -> Int {
    while true {
        let result = Darwin.read(STDIN_FILENO, &buffer, count)
        if result >= 0 { return result }
        if errno == EINTR { continue }
        fail("input read failed: \(String(cString: strerror(errno)))")
    }
}

func ensureInputEnded(_ buffer: inout [UInt8]) {
    let result = readInput(into: &buffer, count: 1)
    guard result == 0 else { fail("input exceeds authenticated byte count") }
}

final class ClaimState {
    var completed = false
    var error: String?
}

func claimReleaseCallback(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<DADissenter>? {
    Unmanaged.passRetained(
        DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy), nil)
    )
}

func claimCallback(
    _ disk: DADisk,
    _ dissenter: DADissenter?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let state = Unmanaged<ClaimState>.fromOpaque(context).takeUnretainedValue()
    if let dissenter {
        state.error = "cannot claim media exclusively (status \(DADissenterGetStatus(dissenter)))"
    }
    state.completed = true
    CFRunLoopStop(CFRunLoopGetCurrent())
}

func claimDisk(_ diskName: String) -> (DASession, DADisk) {
    guard let session = DASessionCreate(kCFAllocatorDefault) else {
        fail("cannot create Disk Arbitration session")
    }
    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, diskName) else {
        fail("cannot create Disk Arbitration media reference")
    }
    let mode = CFRunLoopMode.defaultMode.rawValue
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), mode)
    let state = ClaimState()
    let context = Unmanaged.passUnretained(state).toOpaque()
    DADiskClaim(
        disk,
        DADiskClaimOptions(kDADiskClaimOptionDefault),
        claimReleaseCallback,
        context,
        claimCallback,
        context
    )
    while !state.completed {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1, true)
    }
    if let error = state.error { fail(error) }
    return (session, disk)
}

func report(
    label: String,
    transferred: UInt64,
    byteCount: UInt64,
    started: Date
) {
    let elapsed = max(Date().timeIntervalSince(started), 0.001)
    let transferredMiB = Double(transferred) / 1_048_576
    let totalMiB = Double(byteCount) / 1_048_576
    let percent = Double(transferred) * 100 / Double(byteCount)
    status(String(
        format: "%@: %.0f%% (%.0f / %.0f MiB, %.1f MiB/s)",
        label,
        percent,
        transferredMiB,
        totalMiB,
        transferredMiB / elapsed
    ))
}

func shouldReport(transferred: UInt64, nextReport: UInt64, remaining: UInt64) -> Bool {
    transferred >= nextReport || remaining == 0
}

func nextReport(after transferred: UInt64, remaining: UInt64, step: UInt64, total: UInt64) -> UInt64 {
    remaining <= step ? total : transferred + step
}

guard CommandLine.arguments.count == 6 else { exit(64) }
let operation = CommandLine.arguments[1]
let diskName = CommandLine.arguments[2]
let expectedIdentity = CommandLine.arguments[3]
guard let byteCount = UInt64(CommandLine.arguments[4]) else { exit(64) }
let expectedRawSHA = CommandLine.arguments[5]
guard operation == "write-verify" || operation == "repair-verify" else { exit(64) }

let (session, claimedDisk) = claimDisk(diskName)
defer {
    DADiskUnclaim(claimedDisk)
    DASessionUnscheduleFromRunLoop(
        session,
        CFRunLoopGetCurrent(),
        CFRunLoopMode.defaultMode.rawValue
    )
}

let path = "/dev/r\(diskName)"
let descriptor = open(path, O_RDWR)
guard descriptor >= 0 else { fail("cannot open \(path): \(String(cString: strerror(errno)))") }
defer { close(descriptor) }

guard let service = IOServiceGetMatchingService(
    kIOMainPortDefault,
    IOBSDNameMatching(kIOMainPortDefault, 0, diskName)
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
let reportStep = max(byteCount / 100, UInt64(64 * 1024 * 1024))
let totalMiB = Double(byteCount) / 1_048_576
var source = [UInt8](repeating: 0, count: chunkSize)
var device = [UInt8](repeating: 0, count: chunkSize)

if operation == "write-verify" {
    var remaining = byteCount
    var transferred: UInt64 = 0
    var next = reportStep
    var sourceHasher = SHA256()
    let writeStarted = Date()
    status(String(format: "Writing: 0%% (0 / %.0f MiB)", totalMiB))
    while remaining > 0 {
        let requested = min(chunkSize, Int(remaining))
        let count = readInput(into: &source, count: requested)
        guard count > 0 else { fail("input ended before authenticated byte count") }
        update(&sourceHasher, from: source, count: count)
        writeExact(
            descriptor,
            bytes: Data(bytes: source, count: count),
            offset: Int64(transferred)
        )
        let copied = UInt64(count)
        remaining -= copied
        transferred += copied
        if shouldReport(transferred: transferred, nextReport: next, remaining: remaining) {
            report(label: "Writing", transferred: transferred, byteCount: byteCount, started: writeStarted)
            next = nextReport(after: transferred, remaining: remaining, step: reportStep, total: byteCount)
        }
    }
    ensureInputEnded(&source)
    guard hexDigest(sourceHasher.finalize()) == expectedRawSHA else {
        fail("decompressed image does not match authenticated raw digest")
    }
    status("Writing: syncing buffered data")
    guard fsync(descriptor) == 0 else { fail("fsync failed: \(String(cString: strerror(errno)))") }
    status("Writing: complete")

    remaining = byteCount
    transferred = 0
    next = reportStep
    var readbackHasher = SHA256()
    let verifyStarted = Date()
    status(String(format: "Verifying: 0%% (0 / %.0f MiB)", totalMiB))
    while remaining > 0 {
        let requested = min(chunkSize, Int(remaining))
        readExact(descriptor, into: &device, count: requested, offset: Int64(transferred))
        update(&readbackHasher, from: device, count: requested)
        let copied = UInt64(requested)
        remaining -= copied
        transferred += copied
        if shouldReport(transferred: transferred, nextReport: next, remaining: remaining) {
            report(label: "Verifying", transferred: transferred, byteCount: byteCount, started: verifyStarted)
            next = nextReport(after: transferred, remaining: remaining, step: reportStep, total: byteCount)
        }
    }
    let observed = hexDigest(readbackHasher.finalize())
    guard observed == expectedRawSHA else {
        fail("raw image readback mismatch: expected \(expectedRawSHA), observed \(observed)")
    }
    status("Verifying: complete")
} else {
    struct Repair {
        let offset: Int64
        let bytes: Data
    }
    let repairLimit = 64 * 1024 * 1024
    var repairs: [Repair] = []
    var repairBytes = 0
    var remaining = byteCount
    var compared: UInt64 = 0
    var next = reportStep
    var sourceHasher = SHA256()
    let compareStarted = Date()
    status(String(format: "Comparing: 0%% (0 / %.0f MiB)", totalMiB))
    while remaining > 0 {
        let requested = min(chunkSize, Int(remaining))
        let count = readInput(into: &source, count: requested)
        guard count > 0 else { fail("input ended before authenticated byte count") }
        update(&sourceHasher, from: source, count: count)
        readExact(descriptor, into: &device, count: count, offset: Int64(compared))
        if !source[0..<count].elementsEqual(device[0..<count]) {
            guard repairBytes + count <= repairLimit else {
                fail("card differs by more than the 64 MiB recovery limit; run a full flash")
            }
            repairs.append(Repair(
                offset: Int64(compared),
                bytes: Data(bytes: source, count: count)
            ))
            repairBytes += count
        }
        let copied = UInt64(count)
        remaining -= copied
        compared += copied
        if shouldReport(transferred: compared, nextReport: next, remaining: remaining) {
            report(label: "Comparing", transferred: compared, byteCount: byteCount, started: compareStarted)
            next = nextReport(after: compared, remaining: remaining, step: reportStep, total: byteCount)
        }
    }
    ensureInputEnded(&source)
    guard hexDigest(sourceHasher.finalize()) == expectedRawSHA else {
        fail("decompressed image does not match authenticated raw digest")
    }

    if repairs.isEmpty {
        status("Repairing: card already matches the authenticated image")
    } else {
        status(String(format: "Repairing: %d changed chunks (%.0f MiB)", repairs.count, Double(repairBytes) / 1_048_576))
        for repair in repairs {
            writeExact(descriptor, bytes: repair.bytes, offset: repair.offset)
        }
        guard fsync(descriptor) == 0 else { fail("fsync failed: \(String(cString: strerror(errno)))") }
        for repair in repairs {
            readExact(descriptor, into: &device, count: repair.bytes.count, offset: repair.offset)
            guard repair.bytes.elementsEqual(device[0..<repair.bytes.count]) else {
                fail("repaired chunk readback failed at byte \(repair.offset)")
            }
        }
        status("Repairing: changed chunks verified")
    }
    status("Verifying: complete")
}
