// Window on the Tab Display virtual display that logs every mouse, tablet and scroll event it receives:
// verifies pen pressure/tilt/proximity and touch scroll phases/momentum end to end.
// Build: swiftc -O InputInspector.swift -o build/inputinspector
import AppKit

/// The Tab Display virtual display (found by its fixed vendor ID; its name is the tablet's).
func tabDisplayScreen() -> NSScreen? {
    NSScreen.screens.first { s in
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayVendorNumber($0.uint32Value) == 0x5344 } ?? false
    }
}

final class InspectorView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func log(_ s: String) { print(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + s); fflush(stdout) }
    private func pen(_ e: NSEvent) -> String {
        e.subtype == .tabletPoint ? String(format: " pressure=%.3f tilt=(%.2f,%.2f) rot=%.1f", e.pressure, e.tilt.x, e.tilt.y, e.rotation) : " (no tablet data)"
    }
    override func mouseDown(with e: NSEvent) { log("leftDown \(e.locationInWindow) clicks=\(e.clickCount)" + pen(e)) }
    override func mouseDragged(with e: NSEvent) { log("leftDragged \(e.locationInWindow)" + pen(e)) }
    override func mouseUp(with e: NSEvent) { log("leftUp \(e.locationInWindow)" + pen(e)) }
    override func rightMouseDown(with e: NSEvent) { log("rightDown \(e.locationInWindow)" + pen(e)) }
    override func rightMouseUp(with e: NSEvent) { log("rightUp \(e.locationInWindow)") }
    override func mouseMoved(with e: NSEvent) { log("moved \(e.locationInWindow)" + pen(e)) }
    override func tabletProximity(with e: NSEvent) { log("proximity enter=\(e.isEnteringProximity) type=\(e.pointingDeviceType.rawValue)") }
    override func scrollWheel(with e: NSEvent) {
        log(String(format: "scroll dy=%.1f dx=%.1f precise=%d phase=%lu momentum=%lu", e.scrollingDeltaY, e.scrollingDeltaX, e.hasPreciseScrollingDeltas ? 1 : 0, e.phase.rawValue, e.momentumPhase.rawValue))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = tabDisplayScreen() else { print("Tab Display screen not found"); exit(1) }
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.setFrame(screen.frame, display: true)
win.level = .floating
win.acceptsMouseMovedEvents = true
let v = InspectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
v.wantsLayer = true
v.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.15, blue: 0.25, alpha: 1).cgColor
win.contentView = v
win.makeFirstResponder(v)
win.orderFrontRegardless()
app.activate(ignoringOtherApps: true)
win.makeKey()
print("inspector on \(screen.frame)"); fflush(stdout)
app.run()
