import Foundation
import IOKit
import IOKit.usb

/// IOKit plug/unplug notifications for USB devices (Android detection happens in AOATransport).
final class USBMonitor {
    var onChange: (() -> Void)?
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []

    init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            let monitor = Unmanaged<USBMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            USBMonitor.drain(iterator)
            monitor.onChange?()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, match, callback, me, &it)
            USBMonitor.drain(it)  // arms the notification
            iterators.append(it)
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }

    private static func drain(_ it: io_iterator_t) {
        while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
    }
}
