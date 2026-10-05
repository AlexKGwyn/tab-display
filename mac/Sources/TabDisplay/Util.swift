import Foundation
import Darwin

/// Monotonic nanoseconds on the same base as `mach_absolute_time` (CLOCK_UPTIME_RAW).
@inline(__always) func nowNs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

private let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

/// Converts mach absolute time units (e.g. `SCStreamFrameInfo.displayTime`) to nanoseconds.
@inline(__always) func machToNs(_ t: UInt64) -> Int64 { Int64(t * UInt64(timebase.numer) / UInt64(timebase.denom)) }

enum Log {
    private static let queue = DispatchQueue(label: "log")
    private static let file: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TabDisplay.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ s: @autoclosure () -> String) {
        let line = "\(fmt.string(from: Date())) \(s())\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            file?.write(line.data(using: .utf8)!)
        }
    }
}

/// Raises the calling thread to a fixed high priority (time-constraint scheduling is overkill here).
func makeThreadRealtimeish(_ name: String) {
    Thread.current.name = name
    Thread.current.qualityOfService = .userInteractive
    var param = sched_param()
    param.sched_priority = 47
    pthread_setschedparam(pthread_self(), SCHED_RR, &param)
}

/// NTP-style clock offset (remote − local), lowest-RTT sample of the last 8.
final class ClockSync {
    private var samples: [(offset: Int64, rtt: Int64)] = []
    private let lock = NSLock()

    func add(t1: Int64, t2: Int64, t3: Int64, t4: Int64) {
        lock.lock(); defer { lock.unlock() }
        samples.append((((t2 - t1) + (t3 - t4)) / 2, (t4 - t1) - (t3 - t2)))
        if samples.count > 8 { samples.removeFirst() }
    }
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return !samples.isEmpty }
    private var best: (offset: Int64, rtt: Int64) {
        lock.lock(); defer { lock.unlock() }
        return samples.min { $0.rtt < $1.rtt } ?? (0, 0)
    }
    var offset: Int64 { best.offset }
    var rtt: Int64 { best.rtt }
}

/// Fixed-size ring of recent samples with percentile queries.
final class SampleWindow {
    private var v: [Double]
    private var n = 0
    private let lock = NSLock()
    init(size: Int = 240) { v = Array(repeating: 0, count: size) }
    func add(_ x: Double) { lock.lock(); v[n % v.count] = x; n += 1; lock.unlock() }
    func percentile(_ p: Double) -> Double? {
        lock.lock(); let c = min(n, v.count); let s = Array(v.prefix(c)).sorted(); lock.unlock()
        guard c > 0 else { return nil }
        return s[min(c - 1, Int(p * Double(c)))]
    }
    func clear() { lock.lock(); n = 0; lock.unlock() }
}
