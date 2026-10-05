import Foundation

/// A full-duplex byte pipe to the tablet with one dedicated writer thread and one dedicated
/// reader thread. Subclasses implement raw I/O; framing, batching and the short-packet rule
/// live here.
class Transport {
    let name: String
    var onMessage: ((Message) -> Void)?
    var onClose: ((String) -> Void)?
    /// Called on the writer thread after each video message has been fully written.
    var onVideoWritten: (() -> Void)?

    private let cond = NSCondition()
    private var queue: [(data: Data, isVideo: Bool)] = []
    private(set) var pendingVideo = 0  // guarded by cond
    private var running = false
    private var writing = false
    private(set) var bytesWritten: UInt64 = 0

    init(name: String) { self.name = name }

    // MARK: subclass hooks
    /// Writes all bytes or returns false.
    func rawWrite(_ p: UnsafeRawBufferPointer) -> Bool { fatalError() }
    /// Blocks until some bytes arrive. Returns bytes read, 0 to retry (timeout), or -1 on close/error.
    func rawRead(_ p: UnsafeMutableRawBufferPointer) -> Int { fatalError() }
    /// Unblocks pending I/O (may be called from any thread).
    func rawClose() {}
    /// Releases resources once both I/O threads have exited.
    func rawFinalize() {}
    private var liveThreads = 2

    private func threadExited() {
        cond.lock(); liveThreads -= 1; let last = liveThreads == 0; cond.unlock()
        if last { rawFinalize() }
    }

    func start() {
        running = true
        let w = Thread { [self] in writerLoop() }
        w.stackSize = 1 << 20
        w.start()
        let r = Thread { [self] in readerLoop() }
        r.stackSize = 1 << 20
        r.start()
    }

    func send(_ data: Data, isVideo: Bool = false) {
        cond.lock()
        guard running else { cond.unlock(); return }
        queue.append((data, isVideo))
        if isVideo { pendingVideo += 1 }
        cond.signal()
        cond.unlock()
    }

    var videoQueued: Int { cond.lock(); defer { cond.unlock() }; return pendingVideo }

    /// Flushes `finalMessage` (e.g. BYE) best-effort, then tears down both threads.
    func close(finalMessage: Data? = nil) {
        if let m = finalMessage {
            send(m)
            let deadline = Date().addingTimeInterval(0.3)
            cond.lock()
            while running && (!queue.isEmpty || writing) && cond.wait(until: deadline) {}
            cond.unlock()
        }
        shutdown(reason: "closed locally")
    }

    private func shutdown(reason: String) {
        cond.lock()
        let wasRunning = running
        running = false
        queue.removeAll()
        pendingVideo = 0
        cond.broadcast()
        cond.unlock()
        guard wasRunning else { return }
        rawClose()
        Log.info("\(name): closed (\(reason))")
        onClose?(reason)
    }

    private func writerLoop() {
        defer { threadExited() }
        makeThreadRealtimeish("\(name).write")
        var out = Data()
        out.reserveCapacity(1 << 20)
        while true {
            cond.lock()
            while running && queue.isEmpty { cond.wait() }
            if !running { cond.unlock(); return }
            let batch = queue
            queue.removeAll(keepingCapacity: true)
            writing = true
            cond.unlock()

            out.removeAll(keepingCapacity: true)
            var videos = 0
            for item in batch { out.append(item.data); if item.isVideo { videos += 1 } }
            // A transfer that is an exact multiple of the max packet size has no terminating short
            // packet and would stall the reader; pad with a header-only NOP.
            if out.count % 512 == 0 { out.append(Wire.nop) }
            let ok = out.withUnsafeBytes { rawWrite($0) }
            cond.lock(); writing = false; cond.broadcast(); cond.unlock()
            if !ok { shutdown(reason: "write failed"); return }
            bytesWritten += UInt64(out.count)
            if videos > 0 {
                cond.lock(); pendingVideo = max(0, pendingVideo - videos); cond.unlock()
                for _ in 0..<videos { onVideoWritten?() }
            }
        }
    }

    private func readerLoop() {
        defer { threadExited() }
        makeThreadRealtimeish("\(name).read")
        var parser = Wire.Parser()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buf.deallocate() }
        while true {
            cond.lock(); let r = running; cond.unlock()
            if !r { return }
            let n = rawRead(buf)
            if n < 0 { shutdown(reason: "read ended"); return }
            if n == 0 { continue }
            let t = nowNs()
            do {
                try parser.feed(UnsafeRawBufferPointer(rebasing: buf[0..<n]), recvNs: t) { onMessage?($0) }
            } catch {
                shutdown(reason: "protocol error: \(error.localizedDescription)")
                return
            }
        }
    }
}
