#!/usr/bin/env swift
import Foundation
import IOKit
import IOKit.storage

guard CommandLine.arguments.count == 2 else { exit(64) }
let name = CommandLine.arguments[1]
guard let service = IOServiceGetMatchingService(
    kIOMainPortDefault,
    IOBSDNameMatching(kIOMainPortDefault, 0, name)
) as io_service_t?, service != 0 else { exit(66) }
defer { IOObjectRelease(service) }

var registryID: UInt64 = 0
guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { exit(70) }
func property(_ key: CFString) -> Any? {
    IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
guard let size = property(kIOMediaSizeKey as CFString) as? UInt64,
      let whole = property(kIOMediaWholeKey as CFString) as? Bool,
      let writable = property(kIOMediaWritableKey as CFString) as? Bool else { exit(70) }

print("\(registryID):\(size):\(whole ? 1 : 0):\(writable ? 1 : 0)")
