import Foundation
import CLibUSB

/// Shared libusb context and helpers for the accessory transport and the ADB client.
enum USB {
    static let ctx: OpaquePointer? = {
        var c: OpaquePointer?
        guard libusb_init(&c) == 0 else { return nil }
        return c
    }()

    /// Serializes control-level USB work (device probing, the accessory handshake, adb
    /// commands): interleaving them on one device breaks the adb stream or re-enumerates the
    /// device mid-operation. Streaming over an open accessory connection doesn't take it.
    private static let lock = NSRecursiveLock()
    static func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// Calls `body` for each USB device until it returns true.
    static func forEachDevice(_ body: (OpaquePointer, libusb_device_descriptor) -> Bool) {
        guard let ctx else { return }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        guard n > 0, let list else { return }
        defer { libusb_free_device_list(list, 1) }
        for i in 0..<n {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            if body(dev, desc) { return }
        }
    }

    /// ASCII string descriptor, or "" if absent.
    static func string(_ h: OpaquePointer, _ index: UInt8) -> String {
        guard index != 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = libusb_get_string_descriptor_ascii(h, index, &buf, Int32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : ""
    }
}
