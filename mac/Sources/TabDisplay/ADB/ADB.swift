import Foundation

/// A tablet with USB debugging on, as seen by the ADB client.
struct ADBDevice: Hashable, Identifiable {
    enum State: Hashable { case ready, unauthorized, offline, unknown }
    enum Path: Hashable { case server, usb }
    let serial: String
    let name: String
    let state: State
    let path: Path
    var id: String { serial }
}

/// Just enough adb to find debuggable tablets and install the bundled Android app. Uses a
/// running adb server when there is one (it already owns the USB interface and the user's
/// authorization), otherwise speaks the adb protocol over USB itself.
enum ADB {
    static let packageName = "com.alexgwyn.tabdisplay"

    /// The Android app bundled in this Mac app, if the build included it.
    static var bundledAPK: URL? { Bundle.main.url(forResource: "TabDisplay", withExtension: "apk") }

    // MARK: devices

    static func devices() -> [ADBDevice] { USB.exclusive { devicesLocked() } }

    private static func devicesLocked() -> [ADBDevice] {
        if let list = try? ADBServer.devices() { return list }
        return ADBUSBConnection.list().map { ADBDevice(serial: $0.serial, name: $0.product.replacingOccurrences(of: "_", with: " "), state: .unknown, path: .usb) }
    }

    // MARK: commands

    /// Runs `exec:<command>` and returns its output. Over USB, `allowPrompt` lets the tablet ask
    /// "Allow USB debugging?" if this Mac's key isn't trusted yet.
    static func exec(_ device: ADBDevice, _ command: String, upload: Data? = nil, allowPrompt: Bool = false,
                     progress: ((Double) -> Void)? = nil) throws -> String {
        try USB.exclusive { try execLocked(device, command, upload: upload, allowPrompt: allowPrompt, progress: progress) }
    }

    private static func execLocked(_ device: ADBDevice, _ command: String, upload: Data?, allowPrompt: Bool,
                                   progress: ((Double) -> Void)?) throws -> String {
        let out: Data
        switch device.path {
        case .server:
            out = try ADBServer.run(serial: device.serial, service: "exec:" + command, upload: upload)
        case .usb:
            let c = try connectUSB(device.serial, allowPrompt: allowPrompt)
            defer { c.close() }
            out = try c.run("exec:" + command, upload: upload, progress: progress)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Opens a USB adb connection. If the tablet is showing "Allow USB debugging?", keeps
    /// retrying (fresh handshakes) for up to 3 minutes until the user approves.
    private static func connectUSB(_ serial: String, allowPrompt: Bool) throws -> ADBUSBConnection {
        let deadline = Date().addingTimeInterval(180)
        var offer = allowPrompt
        while true {
            do {
                return try ADBUSBConnection(serial: serial, allowPrompt: offer)
            } catch ADBError.awaitingApproval {
                offer = false  // the prompt is up; don't stack another one
            } catch ADBError.unauthorized where allowPrompt && Date() < deadline {
                Thread.sleep(forTimeInterval: 2)  // still waiting for the user to tap Allow
            }
            if Date() > deadline { throw ADBError.unauthorized }
        }
    }

    /// Installed Tab Display versionCode on the device, or nil if not installed.
    static func installedVersionCode(_ device: ADBDevice, allowPrompt: Bool = false) throws -> Int? {
        let out = try exec(device, "cmd package list packages --show-versioncode \(packageName)", allowPrompt: allowPrompt)
        for line in out.split(separator: "\n") where line.hasPrefix("package:\(packageName) ") {
            if let r = line.range(of: "versionCode:") { return Int(line[r.upperBound...].trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }

    /// The tablet's own name (Settings › About › Device name), else its model; nil if unreachable.
    static func deviceName(_ device: ADBDevice) -> String? {
        for cmd in ["settings get global device_name", "getprop ro.product.model"] {
            if let s = (try? exec(device, cmd))?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != "null" { return s }
        }
        return nil
    }

    /// Streams the APK into `cmd package install` (no temp file on the tablet).
    static func install(_ device: ADBDevice, apk: URL, progress: ((Double) -> Void)? = nil) throws {
        let data = try Data(contentsOf: apk)
        let out = try exec(device, "cmd package install -r -S \(data.count)", upload: data, allowPrompt: true, progress: progress)
        guard out.contains("Success") else {
            let msg = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
                throw ADBError.failed("A differently signed Tab Display is installed on the tablet. Uninstall it there, then try again.")
            }
            throw ADBError.failed(msg.isEmpty ? "Install failed" : msg)
        }
    }
}

/// Client for a local adb server (`adb start-server`), speaking its documented smart-socket
/// protocol on 127.0.0.1:5037.
enum ADBServer {
    private static func connect() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBError.failed("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(5037).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { Darwin.close(fd); throw ADBError.noDevice }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ d: Data) throws {
        try d.withUnsafeBytes { p in
            var off = 0
            while off < d.count {
                let n = Darwin.write(fd, p.baseAddress! + off, d.count - off)
                if n <= 0 { throw ADBError.protocolError("adb server write failed") }
                off += n
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ n: Int) throws -> Data {
        var d = Data(count: n)
        var off = 0
        try d.withUnsafeMutableBytes { p in
            while off < n {
                let r = Darwin.read(fd, p.baseAddress! + off, n - off)
                if r <= 0 { throw ADBError.protocolError("adb server closed the connection") }
                off += r
            }
        }
        return d
    }

    private static func readToEnd(_ fd: Int32) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let r = Darwin.read(fd, &buf, buf.count)
            if r <= 0 { break }
            out.append(buf, count: r)
        }
        return out
    }

    /// Sends a request and checks for OKAY.
    private static func request(_ fd: Int32, _ s: String) throws {
        try writeAll(fd, Data(String(format: "%04x%@", s.utf8.count, s).utf8))
        let status = String(decoding: try readExactly(fd, 4), as: UTF8.self)
        if status == "OKAY" { return }
        let len = Int(String(decoding: try readExactly(fd, 4), as: UTF8.self), radix: 16) ?? 0
        let msg = String(decoding: try readExactly(fd, len), as: UTF8.self)
        if msg.contains("unauthorized") { throw ADBError.unauthorized }
        throw ADBError.failed(msg)
    }

    static func devices() throws -> [ADBDevice] {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try request(fd, "host:devices-l")
        let len = Int(String(decoding: try readExactly(fd, 4), as: UTF8.self), radix: 16) ?? 0
        let text = String(decoding: try readExactly(fd, len), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }
            let fields = Dictionary(parts.dropFirst(2).compactMap { p -> (String, String)? in
                let kv = p.split(separator: ":", maxSplits: 1); return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            }, uniquingKeysWith: { a, _ in a })
            let state: ADBDevice.State = parts[1] == "device" ? .ready : parts[1] == "unauthorized" ? .unauthorized : .offline
            let name = fields["model"].map { $0.replacingOccurrences(of: "_", with: " ") } ?? String(parts[0])
            return ADBDevice(serial: String(parts[0]), name: name, state: state, path: .server)
        }
    }

    static func run(serial: String, service: String, upload: Data?) throws -> Data {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try request(fd, "host:transport:\(serial)")
        try request(fd, service)
        if let upload {
            try writeAll(fd, upload)
        }
        return readToEnd(fd)
    }
}
