import Foundation

/// Dev fallback: TCP to the tablet through `adb forward tcp:7878 tcp:7878`.
final class TCPTransport: Transport {
    private var fd: Int32 = -1

    static let port: UInt16 = 7878

    /// Sets up the adb port forward (best effort) and connects.
    static func connect() -> TCPTransport? {
        if let adb = adbPath() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["forward", "tcp:\(port)", "tcp:\(port)"]
            try? p.run()
            p.waitUntilExit()
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { Darwin.close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var sz: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, socklen_t(MemoryLayout<Int32>.size))
        let t = TCPTransport(name: "tcp")
        t.fd = fd
        return t
    }

    static func adbPath() -> String? {
        let candidates = [ProcessInfo.processInfo.environment["ANDROID_HOME"].map { "\($0)/platform-tools/adb" },
                          "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    override func rawWrite(_ p: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < p.count {
            let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    override func rawRead(_ p: UnsafeMutableRawBufferPointer) -> Int {
        let n = Darwin.read(fd, p.baseAddress!, p.count)
        if n < 0 && errno == EINTR { return 0 }
        return n > 0 ? n : -1
    }

    override func rawClose() { Darwin.shutdown(fd, SHUT_RDWR) }
    override func rawFinalize() { Darwin.close(fd) }
}
