import Foundation
import CoreGraphics
import AppKit

/// Turns PEN / TOUCH samples from the tablet into macOS events on the virtual display.
/// Pen events are posted on the transport reader thread the moment they arrive.
final class InputInjector {
    /// Global bounds (points) of the virtual display; read on every event so mode changes apply.
    var displayBounds: () -> CGRect = { .zero }
    /// Tablet clock → Mac clock for latency stats. Returns nil until the clock is synced.
    var toLocalNs: (Int64) -> Int64? = { _ in nil }
    let penLatency = SampleWindow(size: 1000)

    private let src = CGEventSource(stateID: .hidSystemState)
    private let deviceID: Int64 = 0x5344

    // MARK: pen

    private var penDown = false
    private var penRightButton = false
    private var penInProximity = false

    struct PenSample {
        var t: Int64; var x: Float; var y: Float; var pressure: Float
        var tiltX: Float; var tiltY: Float; var rotation: Float
        var buttons: UInt8; var phase: UInt8; var tool: UInt8
    }

    func handlePen(_ payload: Data) {
        var r = Reader(payload)
        let n = Int(r.u16())
        for _ in 0..<n {
            let s = PenSample(t: r.i64(), x: r.f32(), y: r.f32(), pressure: r.f32(), tiltX: r.f32(), tiltY: r.f32(), rotation: r.f32(),
                              buttons: r.u8(), phase: r.u8(), tool: r.u8())
            pen(s)
            if let local = toLocalNs(s.t) { penLatency.add(Double(nowNs() - local) / 1e6) }
        }
    }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let b = displayBounds()
        let cx = min(max(CGFloat(x), 0), 0.9999), cy = min(max(CGFloat(y), 0), 0.9999)
        return CGPoint(x: b.minX + cx * b.width, y: b.minY + cy * b.height)
    }

    private func pen(_ s: PenSample) {
        let p = point(s.x, s.y)
        switch s.phase {
        case PenPhase.proximityIn:
            proximity(enter: true, eraser: s.tool == PenTool.eraser)
        case PenPhase.proximityOut:
            if penDown { post(penRightButton ? .rightMouseUp : .leftMouseUp, p, s, pressure: 0); penDown = false }
            proximity(enter: false, eraser: s.tool == PenTool.eraser)
        case PenPhase.hover:
            if !penInProximity { proximity(enter: true, eraser: s.tool == PenTool.eraser) }
            post(.mouseMoved, p, s, pressure: 0)
        case PenPhase.down:
            if !penInProximity { proximity(enter: true, eraser: s.tool == PenTool.eraser) }
            penRightButton = s.buttons & PenButton.primary != 0
            penDown = true
            post(penRightButton ? .rightMouseDown : .leftMouseDown, p, s, pressure: s.pressure)
        case PenPhase.move:
            if !penDown { return }
            post(penRightButton ? .rightMouseDragged : .leftMouseDragged, p, s, pressure: s.pressure)
        case PenPhase.up:
            if !penDown { return }
            penDown = false
            post(penRightButton ? .rightMouseUp : .leftMouseUp, p, s, pressure: 0)
        default:
            break
        }
    }

    private func post(_ type: CGEventType, _ p: CGPoint, _ s: PenSample, pressure: Float) {
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged) ? .right : .left
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventSubtype, value: Int64(NSEvent.EventSubtype.tabletPoint.rawValue))
        e.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
        e.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
        e.setDoubleValueField(.tabletEventTiltX, value: Double(s.tiltX))
        e.setDoubleValueField(.tabletEventTiltY, value: Double(s.tiltY))
        e.setDoubleValueField(.tabletEventRotation, value: Double(s.rotation))
        e.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(p.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(p.y))
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    private func proximity(enter: Bool, eraser: Bool) {
        penInProximity = enter
        guard let e = CGEvent(source: src) else { return }
        e.type = .tabletProximity
        e.setIntegerValueField(.tabletProximityEventVendorID, value: 0x5344)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: eraser ? 0x080A : 0x0802)
        e.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x05C7)  // x, y, buttons, tilt x/y, pressure
        e.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)  // NX_TABLET_POINTER_ERASER / PEN
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        e.post(tap: .cghidEventTap)
    }

    // MARK: touch → scroll / tap

    private let lock = NSLock()
    private var fingers: [UInt8: CGPoint] = [:]
    private var gestureStart: Int64 = 0
    private var startCentroid = CGPoint.zero
    private var lastCentroid = CGPoint.zero
    private var maxFingers = 0
    private var scrolling = false
    private var velocity = CGPoint.zero  // points per second
    private var lastMoveNs: Int64 = 0
    private var momentum: DispatchSourceTimer?
    private let momentumQueue = DispatchQueue(label: "momentum", qos: .userInteractive)
    private static let slop: CGFloat = 8          // points before a touch becomes a scroll
    private static let tapMaxNs: Int64 = 300_000_000

    func handleTouch(_ payload: Data) {
        var r = Reader(payload)
        let n = Int(r.u16())
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<n {
            let t = r.i64(), id = r.u8(), action = r.u8(), x = r.f32(), y = r.f32()
            touch(t: t, id: id, action: action, p: point(x, y))
        }
    }

    private var centroid: CGPoint {
        let c = fingers.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: c.x / CGFloat(max(1, fingers.count)), y: c.y / CGFloat(max(1, fingers.count)))
    }

    private func touch(t: Int64, id: UInt8, action: UInt8, p: CGPoint) {
        if penDown { return }  // palm while drawing
        switch action {
        case TouchAction.down:
            if fingers.isEmpty {
                stopMomentum()
                gestureStart = nowNs()
                maxFingers = 0
                scrolling = false
                velocity = .zero
                // Put the cursor under the finger so scrolls/clicks target that window.
                CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            fingers[id] = p
            maxFingers = max(maxFingers, fingers.count)
            startCentroid = centroid
            lastCentroid = startCentroid
            lastMoveNs = nowNs()
        case TouchAction.move:
            guard fingers[id] != nil else { return }
            fingers[id] = p
            guard maxFingers <= 2 else { return }
            let c = centroid
            if !scrolling && hypot(c.x - startCentroid.x, c.y - startCentroid.y) > InputInjector.slop {
                scrolling = true
                lastCentroid = startCentroid
                scroll(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y, phase: 1, momentum: 0)  // kCGScrollPhaseBegan
            } else if scrolling {
                let dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
                if dx != 0 || dy != 0 { scroll(dx: dx, dy: dy, phase: 2, momentum: 0) }  // kCGScrollPhaseChanged
                let now = nowNs()
                let dt = max(1e-3, Double(now - lastMoveNs) / 1e9)
                let a = 0.35
                velocity = CGPoint(x: velocity.x * (1 - a) + dx / dt * a, y: velocity.y * (1 - a) + dy / dt * a)
                lastMoveNs = now
            }
            lastCentroid = c
        case TouchAction.up, TouchAction.cancel:
            guard fingers[id] != nil else { return }
            let tapPoint = centroid
            fingers[id] = nil
            if !fingers.isEmpty { lastCentroid = centroid; startCentroid = scrolling ? startCentroid : centroid; return }
            if scrolling {
                scroll(dx: 0, dy: 0, phase: 4, momentum: 0)  // kCGScrollPhaseEnded
                if nowNs() - lastMoveNs < 50_000_000 && hypot(velocity.x, velocity.y) > 150 && action == TouchAction.up { startMomentum() }
            } else if action == TouchAction.up && nowNs() - gestureStart < InputInjector.tapMaxNs {
                if maxFingers == 1 { click(at: tapPoint, right: false) } else if maxFingers == 2 { click(at: tapPoint, right: true) }
            }
            scrolling = false
        default:
            break
        }
    }

    private func scroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentum: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.post(tap: .cghidEventTap)
    }

    private func click(at p: CGPoint, right: Bool) {
        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for type in [down, up] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: btn) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
        }
    }

    // Must hold lock.
    private func startMomentum() {
        var v = velocity
        var first = true
        let timer = DispatchSource.makeTimerSource(queue: momentumQueue)
        let interval = 1.0 / 120
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.momentum === timer else { return }
            v = CGPoint(x: v.x * 0.95, y: v.y * 0.95)
            if hypot(v.x, v.y) < 40 {
                self.scroll(dx: 0, dy: 0, phase: 0, momentum: 3)  // kCGMomentumScrollPhaseEnd
                timer.cancel()
                self.momentum = nil
                return
            }
            self.scroll(dx: v.x * interval, dy: v.y * interval, phase: 0, momentum: first ? 1 : 2)  // Begin / Continue
            first = false
        }
        momentum = timer
        timer.resume()
    }

    // Must hold lock.
    private func stopMomentum() {
        guard let m = momentum else { return }
        momentum = nil
        m.cancel()
        scroll(dx: 0, dy: 0, phase: 0, momentum: 3)
    }
}
