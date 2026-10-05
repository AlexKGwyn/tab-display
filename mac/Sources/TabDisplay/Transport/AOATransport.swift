import Foundation
import CLibUSB

/// USB transport using Android Open Accessory. The Mac is the USB host: it switches the
/// tablet into accessory mode, then streams over the accessory interface's bulk endpoints.
final class AOATransport: Transport {
    static let googleVID: UInt16 = 0x18D1
    static let accessoryPIDs: Set<UInt16> = [0x2D00, 0x2D01]
    // Must match android/app/src/main/res/xml/accessory_filter.xml.
    static let identity = ["TabDisplay", "TabDisplayHost", "Tab Display host", "1", "https://alexgwyn.com", "0001"]

    private let handle: OpaquePointer
    private let epIn: UInt8
    private let epOut: UInt8

    private static var ctx: OpaquePointer? { USB.ctx }

    private init(handle: OpaquePointer, epIn: UInt8, epOut: UInt8, maxPacket: Int) {
        self.handle = handle
        self.epIn = epIn
        self.epOut = epOut
        super.init(name: "usb")
        Log.info("usb: accessory open, bulk IN 0x\(String(epIn, radix: 16)) OUT 0x\(String(epOut, radix: 16)), max packet \(maxPacket)")
    }

    static let appleVID: UInt16 = 0x05AC

    /// An Android device on the bus (answers the AOA protocol query), or one already in accessory mode.
    struct Candidate: Hashable {
        let serial: String
        let name: String
        let inAccessoryMode: Bool
    }

    /// Probe results per bus location, so each device is queried once while it stays plugged in.
    private static var probeCache: [String: Candidate?] = [:]
    private static let cacheLock = NSLock()

    /// Android devices currently connected. Cheap after the first call for a given device.
    static func candidates() -> [Candidate] { USB.exclusive { candidatesLocked() } }

    private static func candidatesLocked() -> [Candidate] {
        guard ctx != nil else { return [] }
        var found: [Candidate] = []
        var present = Set<String>()
        forEachDevice { dev, desc in
            let key = "\(libusb_get_bus_number(dev))-\(libusb_get_device_address(dev))-\(desc.idVendor):\(desc.idProduct)"
            present.insert(key)
            let cached = cacheLock.withLock { probeCache[key] }
            if let c = cached { if let c { found.append(c) }; return false }
            let c = probe(dev, desc)
            cacheLock.withLock { probeCache[key] = .some(c) }
            if let c { found.append(c) }
            return false
        }
        cacheLock.withLock { probeCache = probeCache.filter { present.contains($0.key) } }
        return found
    }

    private static func probe(_ dev: OpaquePointer, _ desc: libusb_device_descriptor) -> Candidate? {
        if desc.idVendor == appleVID || desc.bDeviceClass == 9 { return nil }  // Apple devices, hubs
        var h: OpaquePointer?
        guard libusb_open(dev, &h) == 0, let h else { return nil }
        defer { libusb_close(h) }
        func string(_ index: UInt8) -> String { USB.string(h, index) }
        let serial = string(desc.iSerialNumber)
        // "SAMSUNG" + "SAMSUNG_Android" → "SAMSUNG Android"; avoid repeating the manufacturer.
        let maker = string(desc.iManufacturer), product = string(desc.iProduct).replacingOccurrences(of: "_", with: " ")
        let name = product.lowercased().hasPrefix(maker.lowercased()) || maker.isEmpty ? product : "\(maker) \(product)"
        if desc.idVendor == googleVID && accessoryPIDs.contains(desc.idProduct) {
            return Candidate(serial: serial, name: name, inAccessoryMode: true)
        }
        // AOA "get protocol": Android answers with its AOA version; other devices stall.
        var ver = [UInt8](repeating: 0, count: 2)
        guard libusb_control_transfer(h, 0xC0, 51, 0, 0, &ver, 2, 300) >= 2, ver[0] | ver[1] != 0 else { return nil }
        Log.info("usb: found Android device \(name) (serial \(serial), AOA v\(ver[0]))")
        return Candidate(serial: serial, name: name.isEmpty ? "Android device" : name, inAccessoryMode: false)
    }

    /// Switches the device with `serial` into accessory mode if needed, then opens it.
    static func connect(serial: String) throws -> AOATransport { try USB.exclusive { try connectLocked(serial: serial) } }

    private static func connectLocked(serial: String) throws -> AOATransport {
        guard ctx != nil else { throw err("libusb_init failed") }
        func accessory() -> OpaquePointer? {
            var match: OpaquePointer?
            forEachDevice { dev, desc in
                guard desc.idVendor == googleVID && accessoryPIDs.contains(desc.idProduct) else { return false }
                // Android keeps its serial number in accessory mode; accept a blank one as a match too.
                let c = probe(dev, desc)
                if c?.serial == serial || c?.serial.isEmpty == true || serial.isEmpty { match = libusb_ref_device(dev); return true }
                return false
            }
            return match
        }
        if accessory() == nil {
            var switched = false
            forEachDevice { dev, desc in
                guard let c = probe(dev, desc), !c.inAccessoryMode, c.serial == serial else { return false }
                switched = startAccessory(dev)
                return true
            }
            guard switched else { throw err("the device did not accept the accessory handshake") }
            cacheLock.withLock { probeCache.removeAll() }
            // The device drops off the bus and re-enumerates as an accessory.
            let deadline = Date().addingTimeInterval(15)  // macOS occasionally takes many seconds to configure it
            while true {
                if let d = accessory() { libusb_unref_device(d); break }
                if Date() > deadline { throw err("the device did not re-enumerate as an accessory") }
                usleep(100_000)
            }
            usleep(200_000)
        }
        guard let dev = accessory() else { throw err("accessory not found") }
        defer { libusb_unref_device(dev) }
        return try open(dev)
    }

    private static func startAccessory(_ dev: OpaquePointer) -> Bool {
        var h: OpaquePointer?
        guard libusb_open(dev, &h) == 0, let h else { return false }
        defer { libusb_close(h) }
        var ver = [UInt8](repeating: 0, count: 2)
        let r = libusb_control_transfer(h, 0xC0, 51, 0, 0, &ver, 2, 1000)
        guard r >= 2 else { return false }
        let version = Int(ver[0]) | Int(ver[1]) << 8
        Log.info("usb: AOA protocol version \(version)")
        guard version >= 1 else { return false }
        for (i, s) in identity.enumerated() {
            var bytes = Array(s.utf8CString).map { UInt8(bitPattern: $0) }
            guard libusb_control_transfer(h, 0x40, 52, 0, UInt16(i), &bytes, UInt16(bytes.count), 1000) >= 0 else { return false }
        }
        let s = libusb_control_transfer(h, 0x40, 53, 0, 0, nil, 0, 1000)
        Log.info("usb: AOA start sent (\(s))")
        return s >= 0
    }

    private static func open(_ dev: OpaquePointer) throws -> AOATransport {
        var cfgPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &cfgPtr) == 0, let cfg = cfgPtr else { throw err("no config descriptor") }
        defer { libusb_free_config_descriptor(cfg) }
        guard cfg.pointee.bNumInterfaces > 0 else { throw err("no interfaces") }
        let alt = cfg.pointee.interface[0].altsetting[0]
        var epIn: UInt8 = 0, epOut: UInt8 = 0, maxPacket = 512
        for i in 0..<Int(alt.bNumEndpoints) {
            let e = alt.endpoint[i]
            guard e.bmAttributes & 3 == 2 else { continue }  // bulk
            if e.bEndpointAddress & 0x80 != 0 { epIn = e.bEndpointAddress } else { epOut = e.bEndpointAddress; maxPacket = Int(e.wMaxPacketSize) }
        }
        guard epIn != 0, epOut != 0 else { throw err("accessory bulk endpoints not found") }
        var h: OpaquePointer?
        let r = libusb_open(dev, &h)
        guard r == 0, let h else { throw err("libusb_open: \(String(cString: libusb_error_name(r)))") }
        let c = libusb_claim_interface(h, Int32(alt.bInterfaceNumber))
        guard c == 0 else { libusb_close(h); throw err("claim interface: \(String(cString: libusb_error_name(c)))") }
        // Drop any stale bytes and clear halts left from a previous session.
        libusb_clear_halt(h, epIn)
        libusb_clear_halt(h, epOut)
        return AOATransport(handle: h, epIn: epIn, epOut: epOut, maxPacket: maxPacket)
    }

    private static func forEachDevice(_ body: (OpaquePointer, libusb_device_descriptor) -> Bool) { USB.forEachDevice(body) }

    private static func err(_ s: String) -> NSError { NSError(domain: "AOA", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    // MARK: I/O

    private var stopping = false

    override func rawWrite(_ p: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        var stalledSince: Int64?
        while off < p.count {
            if stopping { return false }
            var done: Int32 = 0
            let r = libusb_bulk_transfer(handle, epOut, UnsafeMutablePointer(mutating: p.baseAddress!.assumingMemoryBound(to: UInt8.self)) + off,
                                         Int32(p.count - off), &done, 500)
            off += Int(done)
            if r == LIBUSB_ERROR_TIMEOUT.rawValue {
                // Nobody reading on the tablet (app closed or restarting): give up after 3 s so the
                // session can be re-established instead of hanging.
                if done > 0 { stalledSince = nil; continue }
                let now = nowNs()
                if let s = stalledSince, now - s > 3_000_000_000 { Log.info("usb: tablet stopped reading"); return false }
                if stalledSince == nil { stalledSince = now }
                continue
            }
            if r != 0 { Log.info("usb: write error \(String(cString: libusb_error_name(r)))"); return false }
        }
        return true
    }

    override func rawRead(_ p: UnsafeMutableRawBufferPointer) -> Int {
        if stopping { return -1 }
        var done: Int32 = 0
        let r = libusb_bulk_transfer(handle, epIn, p.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(p.count), &done, 250)
        if r == 0 || r == LIBUSB_ERROR_TIMEOUT.rawValue { return Int(done) }
        Log.info("usb: read error \(String(cString: libusb_error_name(r)))")
        return -1
    }

    override func rawClose() { stopping = true }

    override func rawFinalize() {
        libusb_release_interface(handle, 0)
        libusb_close(handle)
    }
}
