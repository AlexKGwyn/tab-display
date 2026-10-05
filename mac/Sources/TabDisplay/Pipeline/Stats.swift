import Foundation

/// Per-frame stage timing on the Mac clock, from VIDEO send + FRAME_STATS from the tablet.
final class Stats {
    struct Row {
        var seq: UInt32
        var t: Int64            // displayNs (Mac clock)
        var bytes: Int
        var keyframe: Bool
        var capture: Double, encode: Double
        var transfer: Double = .nan, decode: Double = .nan, present: Double = .nan, total: Double = .nan
        var dropped = false
    }

    struct Snapshot {
        var stages: [(name: String, p50: Double?, p95: Double?)] = []
        var totalP50: Double?
        var totalP95: Double?
        var penP50: Double?
        var penP95: Double?
        var fps: Double = 0
        var mbps: Double = 0
        var dropped = 0
        var keyframes = 0
    }

    static let stageNames = ["capture", "encode", "transfer", "decode", "present", "total"]
    private let windows = Dictionary(uniqueKeysWithValues: stageNames.map { ($0, SampleWindow()) })
    private let lock = NSLock()
    private var pending = [UInt32: Row]()
    private var history: [Row] = []           // completed rows, last 60 s
    private var renderTimes: [Int64] = []     // for fps
    private var sentBytes: [(Int64, Int)] = []
    private var dropped = 0
    private var keyframes = 0

    func sent(seq: UInt32, frame: EncodedFrame, bytes: Int) {
        let row = Row(seq: seq, t: frame.displayNs, bytes: bytes, keyframe: frame.keyframe,
                      capture: Double(frame.callbackNs - frame.displayNs) / 1e6, encode: Double(frame.encodedNs - frame.callbackNs) / 1e6)
        lock.lock(); defer { lock.unlock() }
        if !frame.refinement {
            windows["capture"]!.add(row.capture)
            windows["encode"]!.add(row.encode)
        }
        if frame.keyframe { keyframes += 1 }
        pending[seq] = row
        if pending.count > 512, let k = pending.keys.min() { pending[k] = nil }
        let now = nowNs()
        sentBytes.append((now, bytes))
        sentBytes.removeAll { now - $0.0 > 1_000_000_000 }
    }

    /// Tablet timestamps converted with `offset` = tablet − mac (nil if the clock is not synced yet).
    func frameStats(seq: UInt32, recv: Int64, decoded: Int64, rendered: Int64, offset: Int64?, encodedNs: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard var row = pending.removeValue(forKey: seq) else { return }
        row.decode = Double(decoded - recv) / 1e6
        windows["decode"]!.add(row.decode)
        if rendered == 0 {
            row.dropped = true
            dropped += 1
        } else {
            row.present = Double(rendered - decoded) / 1e6
            windows["present"]!.add(row.present)
            let now = nowNs()
            renderTimes.append(now)
            renderTimes.removeAll { now - $0 > 1_000_000_000 }
        }
        if let off = offset {
            let encodedAt = row.t + Int64((row.capture + row.encode) * 1e6)
            row.transfer = Double(recv - off - encodedAt) / 1e6
            windows["transfer"]!.add(row.transfer)
            if rendered != 0 {
                row.total = Double(rendered - off - row.t) / 1e6
                windows["total"]!.add(row.total)
            }
        }
        history.append(row)
        if let first = history.first, row.t - first.t > 60_000_000_000 {
            history.removeFirst(min(history.count, 120))
        }
    }

    func snapshot(pen: SampleWindow?) -> Snapshot {
        var s = Snapshot()
        for n in Stats.stageNames {
            s.stages.append((n, windows[n]!.percentile(0.5), windows[n]!.percentile(0.95)))
        }
        s.totalP50 = windows["total"]!.percentile(0.5)
        s.totalP95 = windows["total"]!.percentile(0.95)
        s.penP50 = pen?.percentile(0.5)
        s.penP95 = pen?.percentile(0.95)
        lock.lock()
        let now = nowNs()
        s.fps = Double(renderTimes.filter { now - $0 <= 1_000_000_000 }.count)
        s.mbps = Double(sentBytes.filter { now - $0.0 <= 1_000_000_000 }.reduce(0) { $0 + $1.1 }) * 8 / 1e6
        s.dropped = dropped
        s.keyframes = keyframes
        lock.unlock()
        return s
    }

    func recent(_ n: Int) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        return Array(history.suffix(n))
    }

    func csv() -> String {
        lock.lock(); let rows = history; lock.unlock()
        var out = "seq,display_ns,bytes,keyframe,dropped,capture_ms,encode_ms,transfer_ms,decode_ms,present_ms,total_ms\n"
        func f(_ d: Double) -> String { d.isNaN ? "" : String(format: "%.3f", d) }
        for r in rows {
            out += "\(r.seq),\(r.t),\(r.bytes),\(r.keyframe ? 1 : 0),\(r.dropped ? 1 : 0),\(f(r.capture)),\(f(r.encode)),\(f(r.transfer)),\(f(r.decode)),\(f(r.present)),\(f(r.total))\n"
        }
        return out
    }
}
