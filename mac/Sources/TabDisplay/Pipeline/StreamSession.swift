import Foundation
import CoreGraphics
import CoreVideo

struct SessionConfig {
    var mode: DisplayMode
    var refresh: Int          // 120 or 60
    var bitrate: Int          // bits per second
    var codec: CodecChoice
    var frameCapBytes: Int    // largest single frame; sized to transmit in ≤ 2 ms
    var idleRefinement: Bool
}

/// One connected tablet: virtual display → capture → encode → transport, plus input and stats.
///
/// Threads: capture callbacks (capture queue), encoder output (VideoToolbox), transport writer
/// and reader. Frames never queue: while the encoder or link is busy, only the newest captured
/// frame is kept (mailbox) and older ones are dropped before encoding, so the reference chain
/// stays intact.
/// What the tablet told us about itself in HELLO.
struct Peer {
    var name = "Tablet"
    var panel = (w: 2560, h: 1600)
    var sizeMm = (w: 0, h: 0)
    var refresh = 60.0
    var codecMask: UInt8 = CodecMask.hevc | CodecMask.h264
    var appVersion = ""
    var protocolVersion: UInt32 = Proto.version
}

final class StreamSession {
    let transport: Transport
    private(set) var config: SessionConfig
    let stats = Stats()
    let injector = InputInjector()
    let clock = ClockSync()  // offset = tablet − mac
    var onEnded: ((String) -> Void)?
    var onPeer: ((String) -> Void)?

    private var display: VirtualDisplay?
    private let capture = Capture()
    private(set) var encoder: Encoder?
    private var pingTimer: DispatchSourceTimer?
    private var ended = false

    // Pipeline state, guarded by `lock`.
    private let lock = NSLock()
    private var inFlight = 0  // frames submitted to VideoToolbox, not yet output
    /// VideoToolbox waits on the capture's GPU fence before encoding; two frames in flight let
    /// that wait overlap the previous encode so the pipeline sustains 120 fps.
    private let maxInFlight = Int(ProcessInfo.processInfo.environment["TD_INFLIGHT"] ?? "") ?? 2
    private var encoderBusy: Bool { inFlight >= maxInFlight }
    private var mailbox: CapturedFrame?
    private var lastFrame: CapturedFrame?
    private var encoderGeneration = 0
    private var captureSize = (w: 0, h: 0)
    private var forceKeyframe = true
    private var refinementsLeft = 0
    private var refineGeneration = 0
    private var videoSeq: UInt32 = 0
    private var ctrlSeq: UInt32 = 0
    private var displayID: CGDirectDisplayID = 0

    init(transport: Transport, config: SessionConfig) {
        self.transport = transport
        self.config = config
    }

    var displayBounds: CGRect { displayID == 0 ? .zero : CGDisplayBounds(displayID) }

    private var helloContinuation: CheckedContinuation<Void, Never>?
    private var peerSeen = false
    private let peerLock = NSLock()
    private var _peer = Peer()
    var peer: Peer { peerLock.withLock { _peer } }

    @MainActor
    func start() async throws {
        transport.onMessage = { [weak self] in self?.handle($0) }
        transport.onVideoWritten = { [weak self] in self?.pump() }
        transport.onClose = { [weak self] reason in
            DispatchQueue.main.async { self?.stop(reason: reason, sendBye: false) }
        }
        transport.start()
        sendHello()  // the tablet answers with HELLO, and we send CONFIG then

        // Only bring up the virtual display once the tablet app is actually there, so retries
        // against a closed app don't make a display flicker in and out.
        let answered = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in await withCheckedContinuation { c in
                if self.peerSeen { c.resume() } else { self.helloContinuation = c }
            }; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !answered {
            helloContinuation?.resume()
            helloContinuation = nil
            throw NSError(domain: "Session", code: 2, userInfo: [NSLocalizedDescriptionKey: "tablet app not responding"])
        }
        if ended { throw NSError(domain: "Session", code: 3, userInfo: [NSLocalizedDescriptionKey: "connection closed"]) }
        if let mb = ProcessInfo.processInfo.environment["TD_THROUGHPUT_MB"].flatMap(Int.init) { await throughputTest(mb) }

        let p = peer
        let refresh = min(Double(config.refresh), max(60, p.refresh.rounded()))
        guard let vd = VirtualDisplay(name: p.name, panel: p.panel, sizeMm: p.sizeMm, mode: config.mode, refresh: refresh) else {
            throw NSError(domain: "Session", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not create the virtual display"])
        }
        display = vd
        displayID = vd.displayID
        try installEncoder(for: p.panel)

        let id = vd.displayID
        injector.displayBounds = { CGDisplayBounds(id) }
        injector.toLocalNs = { [clock] t in clock.valid ? t - clock.offset : nil }

        capture.onFrame = { [weak self] in self?.captured($0) }
        capture.onIdle = { [weak self] in self?.idle() }
        capture.onStop = { [weak self] err in DispatchQueue.main.async { self?.stop(reason: "capture stopped: \(err.localizedDescription)", sendBye: true) } }
        try await capture.start(displayID: vd.displayID, width: p.panel.w, height: p.panel.h, fps: config.refresh)
        startPings()
    }

    /// Replaces the encoder (start-up or resize). Output from a replaced encoder is ignored.
    @MainActor
    private func installEncoder(for panel: (w: Int, h: Int)) throws {
        let enc = try Encoder(codec: config.codec, width: panel.w, height: panel.h, fps: config.refresh, bitrate: config.bitrate,
                              lowLatencyRC: ProcessInfo.processInfo.environment["TD_LLRC"] == "1")
        enc.setFrameCap(config.frameCapBytes)
        let old: Encoder? = lock.withLock {
            encoderGeneration += 1
            let gen = encoderGeneration
            enc.onOutput = { [weak self] in self?.encoded($0, generation: gen) }
            let old = encoder
            encoder = enc
            captureSize = panel
            inFlight = 0
            mailbox = nil
            lastFrame = nil
            forceKeyframe = true
            return old
        }
        old?.invalidate()
    }

    private var pendingResize: (w: Int, h: Int, mm: (w: Int, h: Int))?
    private var resizing = false

    /// The tablet's video area changed (rotation, split screen, free-form resize): reshape the
    /// virtual display in place and restart capture/encode at the new size.
    @MainActor
    private func resize(width: Int, height: Int, mm: (w: Int, h: Int)) async {
        guard width >= 200, height >= 200 else { return }
        if resizing { pendingResize = (width, height, mm); return }
        let panel = (w: width & ~1, h: height & ~1)
        guard !ended, let display, panel != peer.panel else { return }
        resizing = true
        defer {
            resizing = false
            if let next = pendingResize {
                pendingResize = nil
                Task { @MainActor in await self.resize(width: next.w, height: next.h, mm: next.mm) }
            }
        }
        Log.info("tablet video area changed to \(panel.w)×\(panel.h)")
        peerLock.withLock { _peer.panel = panel; _peer.sizeMm = mm }
        capture.stop()
        do {
            try installEncoder(for: panel)
            display.reshape(panel: panel, mode: config.mode, refresh: min(Double(config.refresh), max(60, peer.refresh.rounded())))
            sendConfig()
            try await capture.start(displayID: display.displayID, width: panel.w, height: panel.h, fps: config.refresh)
        } catch {
            stop(reason: "resize failed: \(error.localizedDescription)")
        }
    }

    /// Link probe: pushes `mb` × 1 MiB NOP messages and logs the sustained link rate.
    @MainActor
    private func throughputTest(_ mb: Int) async {
        let chunk = Wire.message(type: MsgType.nop, seq: 0, payload: Data(count: 1 << 20))
        try? await Task.sleep(nanoseconds: 500_000_000)
        let b0 = transport.bytesWritten, t0 = nowNs()
        for _ in 0..<mb { transport.send(chunk) }
        while transport.bytesWritten - b0 < UInt64(mb) * UInt64(chunk.count) && nowNs() - t0 < 20_000_000_000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let secs = Double(nowNs() - t0) / 1e9
        Log.info(String(format: "throughput: %d MiB in %.2f s = %.0f MB/s (%.0f Mbps)", mb, secs, Double(transport.bytesWritten - b0) / secs / 1e6, Double(transport.bytesWritten - b0) * 8 / secs / 1e6))
    }

    @MainActor
    func stop(reason: String, sendBye: Bool = true) {
        guard !ended else { return }
        ended = true
        Log.info("session ending: \(reason)")
        helloContinuation?.resume()
        helloContinuation = nil
        pingTimer?.cancel()
        capture.stop()
        lock.lock()
        mailbox = nil
        lastFrame = nil
        lock.unlock()
        encoder?.invalidate()
        if sendBye {
            var w = Writer(); w.u32(UInt32(ByeReason.normal))
            transport.close(finalMessage: control(MsgType.bye, w.data))
        } else {
            transport.close()
        }
        display = nil  // removes the virtual display
        displayID = 0
        onEnded?(reason)
    }

    @MainActor
    func update(mode: DisplayMode, refresh: Int) {
        guard mode != config.mode || refresh != config.refresh else { return }
        config.mode = mode
        config.refresh = refresh
        Log.info("display mode → \(mode.rawValue), \(refresh) Hz")
        display?.apply(mode: mode, refresh: min(Double(refresh), max(60, peer.refresh.rounded())))
    }

    func updateBitrate(_ bps: Int) {
        config.bitrate = bps
        encoder?.setBitrate(bps)
    }

    // MARK: control messages

    private func control(_ type: UInt8, _ payload: Data) -> Data {
        lock.lock(); let s = ctrlSeq; ctrlSeq &+= 1; lock.unlock()
        return Wire.message(type: type, seq: s, payload: payload)
    }

    private func sendHello() {
        var w = Writer()
        w.u32(Proto.version); w.u32(0); w.u32(0); w.f32(Float(config.refresh))
        w.u32(UInt32(CodecMask.hevc | CodecMask.h264)); w.u32(0)
        let name = Data((Host.current().localizedName ?? "Mac").utf8.prefix(200))
        w.u16(UInt16(name.count)); w.bytes(name)
        w.u32(0); w.u32(0)  // physical size: n/a for the Mac
        let version = Data(AppInfo.version.utf8)
        w.u16(UInt16(version.count)); w.bytes(version)
        transport.send(control(MsgType.hello, w.data))
    }

    private func sendConfig() {
        var w = Writer()
        let p = peer
        w.u32(UInt32(config.codec.rawValue)); w.u32(UInt32(p.panel.w)); w.u32(UInt32(p.panel.h))
        w.u32(UInt32(config.refresh)); w.u32(Capture.fullRange ? 1 : 0); w.u32(UInt32(truncatingIfNeeded: ObjectIdentifier(self).hashValue))
        transport.send(control(MsgType.config, w.data))
    }

    private func startPings() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        var quick = 8
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var w = Writer(); let t1 = nowNs(); w.i64(t1)
            self.transport.send(self.control(MsgType.ping, w.data))
            if quick > 0 { quick -= 1; if quick == 0 { t.schedule(deadline: .now() + 2, repeating: 2) } }
        }
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.resume()
        pingTimer = t
    }

    private func handle(_ m: Message) {
        switch m.type {
        case MsgType.pen:
            injector.handlePen(m.payload)
        case MsgType.touch:
            injector.handleTouch(m.payload)
        case MsgType.frameStats:
            var r = Reader(m.payload)
            let seq = r.u32(), recv = r.i64(), decoded = r.i64(), rendered = r.i64()
            stats.frameStats(seq: seq, recv: recv, decoded: decoded, rendered: rendered, offset: clock.valid ? clock.offset : nil)
        case MsgType.ping:
            var r = Reader(m.payload)
            var w = Writer(); w.i64(r.i64()); w.i64(m.recvNs); w.i64(nowNs())
            transport.send(control(MsgType.pong, w.data))
        case MsgType.pong:
            var r = Reader(m.payload)
            clock.add(t1: r.i64(), t2: r.i64(), t3: r.i64(), t4: m.recvNs)
        case MsgType.keyframeRequest:
            var r = Reader(m.payload)
            Log.info("keyframe requested by tablet (reason \(r.u32()))")
            requestKeyframe()
        case MsgType.hello:
            var r = Reader(m.payload)
            let version = r.u32(), w = r.u32(), h = r.u32(), hz = r.f32(), codecs = r.u32(), flags = r.u32()
            let name = String(decoding: r.bytes(Int(r.u16())), as: UTF8.self)
            let mm = r.remaining >= 8 ? (w: Int(r.u32()), h: Int(r.u32())) : (w: 0, h: 0)
            let appVersion = r.remaining >= 2 ? String(decoding: r.bytes(Int(r.u16())), as: UTF8.self) : ""
            Log.info("tablet HELLO: \(name) protocol \(version) app \(appVersion.isEmpty ? "?" : appVersion) \(w)x\(h)@\(Int(hz)) \(mm.w)x\(mm.h) mm codecs=\(codecs) flags=\(flags)")
            if version != Proto.version {
                // Different wire protocol: don't try to stream; tell the user which side to update.
                peerLock.withLock { _peer.name = name; _peer.appVersion = appVersion; _peer.protocolVersion = version }
                DispatchQueue.main.async { self.stop(reason: version > Proto.version ? "incompatible: update Tab Display on this Mac" : "incompatible: update Tab Display on the tablet") }
                return
            }
            if !peerSeen && w >= 320 && h >= 200 {
                // Even dimensions for 4:2:0; cap at what hardware encoders/decoders commonly handle.
                let scale = min(1, 4096 / Double(max(w, h)))
                let pw = Int(Double(w) * scale) & ~1, ph = Int(Double(h) * scale) & ~1
                peerLock.withLock { _peer = Peer(name: name.isEmpty ? "Tablet" : name, panel: (pw, ph), sizeMm: mm, refresh: Double(hz), codecMask: UInt8(truncatingIfNeeded: codecs), appVersion: appVersion) }
                config.codec = codecs & UInt32(CodecMask.hevc) != 0 ? .hevc : .h264
            }
            onPeer?(name)
            DispatchQueue.main.async {
                self.peerSeen = true
                self.helloContinuation?.resume()
                self.helloContinuation = nil
            }
            sendConfig()
            requestKeyframe()
        case MsgType.displaySize:
            var r = Reader(m.payload)
            let w = Int(r.u32()), h = Int(r.u32()), mm = (w: Int(r.u32()), h: Int(r.u32()))
            DispatchQueue.main.async { Task { @MainActor in await self.resize(width: w, height: h, mm: mm) } }
        case MsgType.bye:
            DispatchQueue.main.async { self.stop(reason: "tablet said goodbye", sendBye: false) }
        default:
            break
        }
    }

    // MARK: video pipeline

    /// Counters for the stats log: frames delivered by ScreenCaptureKit / replaced in the mailbox.
    private(set) var capturedCount = 0, supersededCount = 0, refinedCount = 0

    private func captured(_ f: CapturedFrame) {
        lock.lock()
        // Frames from the stream being replaced during a resize.
        if CVPixelBufferGetWidth(f.pixelBuffer) != captureSize.w || CVPixelBufferGetHeight(f.pixelBuffer) != captureSize.h {
            lock.unlock()
            return
        }
        capturedCount += 1
        if mailbox != nil { supersededCount += 1 }
        refineGeneration += 1
        refinementsLeft = config.idleRefinement ? 2 : 0
        if encoderBusy || transport.videoQueued > 0 {
            mailbox = f
            lock.unlock()
            return
        }
        startEncodeLocked(f, refinement: false)
    }

    /// Must hold `lock`; releases it.
    private func startEncodeLocked(_ f: CapturedFrame, refinement: Bool) {
        inFlight += 1
        lastFrame = f
        let key = forceKeyframe
        forceKeyframe = false
        let enc = encoder
        lock.unlock()
        if !refinement {
            enc?.setFrameCap(config.frameCapBytes)
            enc?.setMaxQP(nil)
        }
        enc?.encode(f.pixelBuffer, displayNs: f.displayNs, callbackNs: f.callbackNs, keyframe: key, refinement: refinement)
    }

    /// Starts the next encode if the encoder and link are free.
    private func pump() {
        lock.lock()
        guard !encoderBusy, transport.videoQueued == 0, let f = mailbox else { lock.unlock(); return }
        mailbox = nil
        startEncodeLocked(f, refinement: false)
    }

    private func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        // On a static desktop no new frame may arrive; re-encode the last one now.
        if inFlight == 0 && mailbox == nil, let f = lastFrame {
            let now = nowNs()
            startEncodeLocked(CapturedFrame(pixelBuffer: f.pixelBuffer, displayNs: now, callbackNs: now, dirtyFraction: 1), refinement: false)
            return
        }
        lock.unlock()
    }

    private func encoded(_ f: EncodedFrame, generation: Int) {
        if lock.withLock({ generation != encoderGeneration }) { return }
        if !f.annexB.isEmpty {
            lock.lock(); let seq = videoSeq; videoSeq &+= 1; lock.unlock()
            var flags: UInt8 = 0
            if f.keyframe { flags |= VideoFlag.keyframe }
            if f.refinement { flags |= VideoFlag.refinement }
            var msg = Wire.header(type: MsgType.video, flags: flags, seq: seq, timestamp: f.displayNs, length: f.annexB.count + Proto.videoTrailerSize)
            msg.append(f.annexB)
            var w = Writer(capacity: 16); w.i64(f.callbackNs); w.i64(f.encodedNs)
            msg.append(w.data)
            stats.sent(seq: seq, frame: f, bytes: msg.count)
            transport.send(msg, isVideo: true)
        } else {
            lock.lock(); forceKeyframe = true; lock.unlock()
        }
        lock.lock()
        inFlight -= 1
        lock.unlock()
        pump()
        scheduleRefinement()
    }

    // MARK: idle refinement

    /// ScreenCaptureKit reports an idle frame when nothing changed at a composite: motion has
    /// stopped, so refine now.
    private func idle() {
        lock.lock()
        let gen = refineGeneration
        // Idle samples also arrive between composites (capture polls faster than a 60 Hz
        // virtual display composites), so require a real gap since the last change.
        let quiet = lastFrame.map { nowNs() - $0.callbackNs > 20_000_000 } ?? false
        lock.unlock()
        if quiet { refine(generation: gen) }
    }

    /// Fallback if no idle frame arrives: refine once no new frame came for 40 ms.
    private func scheduleRefinement() {
        lock.lock()
        guard config.idleRefinement, refinementsLeft > 0 else { lock.unlock(); return }
        let gen = refineGeneration
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            self?.refine(generation: gen)
        }
    }

    /// Re-encodes the last frame with a bigger size cap so text converges to near-lossless,
    /// at most twice per motion burst, then goes quiet.
    private func refine(generation gen: Int) {
        lock.lock()
        guard config.idleRefinement, gen == refineGeneration, inFlight == 0, mailbox == nil, refinementsLeft > 0, let f = lastFrame else {
            lock.unlock(); return
        }
        refinementsLeft -= 1
        refinedCount += 1
        let now = nowNs()
        encoder?.setFrameCap(config.frameCapBytes * 3)
        // First pass brings text close to the source, second nearly lossless.
        encoder?.setMaxQP(refinementsLeft == 1 ? Int(ProcessInfo.processInfo.environment["TD_REFINE_QP1"] ?? "") ?? 24 : Int(ProcessInfo.processInfo.environment["TD_REFINE_QP2"] ?? "") ?? 16)
        startEncodeLocked(CapturedFrame(pixelBuffer: f.pixelBuffer, displayNs: now, callbackNs: now, dirtyFraction: 0), refinement: true)
    }
}
