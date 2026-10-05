import Foundation
import CLibUSB

/// Minimal ADB host over USB (used when no adb server is running). Implements the documented
/// adb wire protocol (AOSP packages/modules/adb/protocol.txt): CNXN/AUTH handshake, then one
/// stream at a time via OPEN/WRTE/OKAY/CLSE.
final class ADBUSBConnection {
    private enum Cmd {
        static let cnxn: UInt32 = 0x4e584e43, auth: UInt32 = 0x48545541, open: UInt32 = 0x4e45504f
        static let okay: UInt32 = 0x59414b4f, clse: UInt32 = 0x45534c43, wrte: UInt32 = 0x45545257
    }
    private static let version: UInt32 = 0x01000001
    private static let hostMaxData: UInt32 = 256 * 1024

    private let handle: OpaquePointer
    private let iface: Int32
    private let epIn: UInt8, epOut: UInt8
    private var maxData = 4096
    private var nextLocalID: UInt32 = 1

    struct Info: Hashable { let serial: String; let product: String }

    /// Devices exposing an adb interface (USB debugging on). Doesn't connect to them.
    static func list() -> [Info] {
        var out: [Info] = []
        USB.forEachDevice { dev, desc in
            guard findInterface(dev) != nil else { return false }
            var h: OpaquePointer?
            guard libusb_open(dev, &h) == 0, let h else { return false }
            defer { libusb_close(h) }
            out.append(Info(serial: USB.string(h, desc.iSerialNumber), product: USB.string(h, desc.iProduct)))
            return false
        }
        return out
    }

    private static func findInterface(_ dev: OpaquePointer) -> (iface: Int32, epIn: UInt8, epOut: UInt8)? {
        var cfgPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &cfgPtr) == 0, let cfg = cfgPtr else { return nil }
        defer { libusb_free_config_descriptor(cfg) }
        for i in 0..<Int(cfg.pointee.bNumInterfaces) {
            let alt = cfg.pointee.interface[i].altsetting[0]
            guard alt.bInterfaceClass == 0xff, alt.bInterfaceSubClass == 0x42, alt.bInterfaceProtocol == 0x01 else { continue }
            var epIn: UInt8 = 0, epOut: UInt8 = 0
            for e in 0..<Int(alt.bNumEndpoints) {
                let ep = alt.endpoint[e]
                guard ep.bmAttributes & 3 == 2 else { continue }
                if ep.bEndpointAddress & 0x80 != 0 { epIn = ep.bEndpointAddress } else { epOut = ep.bEndpointAddress }
            }
            if epIn != 0 && epOut != 0 { return (Int32(alt.bInterfaceNumber), epIn, epOut) }
        }
        return nil
    }

    /// Opens the adb interface of the device with `serial` and authenticates. With
    /// `allowPrompt`, a key the tablet doesn't know yet is offered, which makes it show
    /// "Allow USB debugging?" (waits up to 3 min for the user); otherwise throws `.unauthorized`.
    init(serial: String, allowPrompt: Bool) throws {
        var found: (OpaquePointer, Int32, UInt8, UInt8)?
        USB.forEachDevice { dev, desc in
            guard let i = ADBUSBConnection.findInterface(dev) else { return false }
            var h: OpaquePointer?
            guard libusb_open(dev, &h) == 0, let h else { return false }
            if USB.string(h, desc.iSerialNumber) == serial { found = (h, i.iface, i.epIn, i.epOut); return true }
            libusb_close(h)
            return false
        }
        guard let (h, iface, epIn, epOut) = found else { throw ADBError.noDevice }
        let r = libusb_claim_interface(h, iface)
        guard r == 0 else {
            libusb_close(h)
            throw ADBError.failed("Couldn't access the tablet's debugging interface (\(String(cString: libusb_error_name(r)))). Quit other adb tools and try again.")
        }
        handle = h
        self.iface = iface
        self.epIn = epIn
        self.epOut = epOut
        do {
            try handshake(allowPrompt: allowPrompt)
        } catch ADBError.awaitingApproval {
            // Prompt is showing. Wait for the CNXN on this connection for a bit; the caller
            // reconnects if it doesn't come (an approved key is accepted by a fresh handshake).
            do { try awaitApproval(until: Date().addingTimeInterval(10)) } catch { close(); throw ADBError.awaitingApproval }
        } catch { close(); throw error }
    }

    deinit { close() }

    private var closed = false
    func close() {
        guard !closed else { return }
        closed = true
        libusb_release_interface(handle, iface)
        libusb_close(handle)
    }

    // MARK: handshake

    private func handshake(allowPrompt: Bool) throws {
        try send(Cmd.cnxn, ADBUSBConnection.version, ADBUSBConnection.hostMaxData, Data("host::\0".utf8))
        var signed = false
        let deadline = Date().addingTimeInterval(5)
        while true {
            let m = try receive(until: deadline)
            Log.info("adb usb: received \(ADBUSBConnection.name(m.cmd)) arg0=\(m.arg0) arg1=\(m.arg1) len=\(m.payload.count)")
            switch m.cmd {
            case Cmd.cnxn:
                maxData = Int(min(m.arg1, ADBUSBConnection.hostMaxData))
                return
            case Cmd.auth where m.arg0 == 1:  // TOKEN
                guard let key = ADBKey.shared else { throw ADBError.key("unavailable") }
                if !signed {
                    signed = true
                    try send(Cmd.auth, 2, 0, try key.sign(token: m.payload))  // SIGNATURE
                } else {
                    // Our key isn't trusted yet: offer it, which shows "Allow USB debugging?".
                    guard allowPrompt else { throw ADBError.unauthorized }
                    try send(Cmd.auth, 3, 0, try key.adbPublicKey(name: "Tab Display@\(Host.current().localizedName ?? "Mac")"))
                    throw ADBError.awaitingApproval
                }
            default:
                continue
            }
        }
    }

    /// Waits for the CNXN that follows the user tapping Allow (used right after offering the key).
    func awaitApproval(until deadline: Date) throws {
        while Date() < deadline {
            guard let m = try? receive(until: min(deadline, Date().addingTimeInterval(10))) else { throw ADBError.protocolError("no reply") }
            Log.info("adb usb: received \(ADBUSBConnection.name(m.cmd)) arg0=\(m.arg0) while waiting for approval")
            if m.cmd == Cmd.cnxn { maxData = Int(min(m.arg1, ADBUSBConnection.hostMaxData)); return }
        }
        throw ADBError.protocolError("timed out")
    }

    private static func name(_ c: UInt32) -> String {
        withUnsafeBytes(of: c.littleEndian) { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: streams

    /// Runs `service` (e.g. "exec:cmd package list packages"), optionally uploading `upload`
    /// after it opens, and returns everything it printed.
    func run(_ service: String, upload: Data? = nil, progress: ((Double) -> Void)? = nil) throws -> Data {
        let local = nextLocalID
        nextLocalID += 1
        try send(Cmd.open, local, 0, Data((service + "\0").utf8))
        var remote: UInt32 = 0
        var output = Data()
        let deadline = Date().addingTimeInterval(10)
        // Wait for the stream to open.
        while remote == 0 {
            let m = try receive(until: deadline)
            if m.cmd == Cmd.okay && m.arg1 == local { remote = m.arg0 }
            else if m.cmd == Cmd.clse && m.arg1 == local { throw ADBError.failed("The tablet refused \(service)") }
        }
        if let upload {
            var off = 0
            while off < upload.count {
                var n = min(maxData, upload.count - off)
                if n % 512 == 0 && n > 1 { n -= 1 }  // never end a payload on a packet boundary
                try send(Cmd.wrte, local, remote, upload.subdata(in: off..<off + n))
                off += n
                // One write in flight: wait for OKAY (answering any output that arrives meanwhile).
                var acked = false
                while !acked {
                    let m = try receive(until: Date().addingTimeInterval(30))
                    if m.cmd == Cmd.okay && m.arg1 == local { acked = true }
                    else if m.cmd == Cmd.wrte && m.arg1 == local { output.append(m.payload); try send(Cmd.okay, local, remote, Data()) }
                    else if m.cmd == Cmd.clse && m.arg1 == local { return output }
                }
                progress?(Double(off) / Double(upload.count))
            }
        }
        while true {
            let m = try receive(until: Date().addingTimeInterval(60))
            guard m.arg1 == local else { continue }
            if m.cmd == Cmd.wrte {
                output.append(m.payload)
                try send(Cmd.okay, local, remote, Data())
            } else if m.cmd == Cmd.clse {
                try? send(Cmd.clse, local, remote, Data())
                return output
            }
        }
    }

    // MARK: messages

    private struct Message { let cmd, arg0, arg1: UInt32; let payload: Data }

    private func send(_ cmd: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data) throws {
        var h = Data(capacity: 24)
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        put(cmd); put(arg0); put(arg1); put(UInt32(payload.count))
        put(payload.reduce(UInt32(0)) { $0 &+ UInt32($1) })  // checksum (only checked by old devices)
        put(cmd ^ 0xffffffff)
        try write(h)
        if !payload.isEmpty { try write(payload) }
    }

    private func write(_ d: Data) throws {
        var off = 0
        while off < d.count {
            var done: Int32 = 0
            let r = d.withUnsafeBytes { p in
                libusb_bulk_transfer(handle, epOut, UnsafeMutablePointer(mutating: p.baseAddress!.assumingMemoryBound(to: UInt8.self)) + off, Int32(d.count - off), &done, 5000)
            }
            off += Int(done)
            if r != 0 { throw ADBError.protocolError("write failed (\(String(cString: libusb_error_name(r))))") }
        }
    }

    private func read(_ n: Int, until deadline: Date) throws -> Data {
        var buf = Data(count: n)
        var off = 0
        while off < n {
            if Date() > deadline { throw ADBError.protocolError("timed out") }
            var done: Int32 = 0
            let r = buf.withUnsafeMutableBytes { p in
                libusb_bulk_transfer(handle, epIn, p.baseAddress!.assumingMemoryBound(to: UInt8.self) + off, Int32(n - off), &done, 500)
            }
            off += Int(done)
            if r != 0 && r != LIBUSB_ERROR_TIMEOUT.rawValue { throw ADBError.protocolError("read failed (\(String(cString: libusb_error_name(r))))") }
        }
        return buf
    }

    private func receive(until deadline: Date) throws -> Message {
        let h = try read(24, until: deadline)
        var r = Reader(h)
        let cmd = r.u32(), a0 = r.u32(), a1 = r.u32(), len = Int(r.u32())
        _ = r.u32()
        guard r.u32() == cmd ^ 0xffffffff else { throw ADBError.protocolError("bad message") }
        let payload = len > 0 ? try read(len, until: deadline.addingTimeInterval(10)) : Data()
        return Message(cmd: cmd, arg0: a0, arg1: a1, payload: payload)
    }
}
