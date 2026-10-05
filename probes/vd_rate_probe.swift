// Feasibility probe: does WindowServer composite a CGVirtualDisplay faster than 60 Hz?
// Creates a display with only <rate> Hz modes and measures CADisplayLink on a window there.
import AppKit
import QuartzCore
let rate = Double(CommandLine.arguments.dropFirst().first ?? "120")!
let d = CGVirtualDisplayDescriptor()
d.queue = .main; d.name = "RateProbe"; d.maxPixelsWide = 2560; d.maxPixelsHigh = 1600
d.sizeInMillimeters = CGSize(width: 239, height: 150); d.vendorID = 0x5344; d.productID = 0x0099; d.serialNum = 9
let vd = CGVirtualDisplay(descriptor: d)!
let s = CGVirtualDisplaySettings(); s.hiDPI = 1
s.modes = [CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: rate)]
print("apply", vd.apply(s))
final class V: NSView {
    var n = 0; var t0 = 0.0
    @objc func tick(_ l: CADisplayLink) {
        if t0 == 0 { t0 = l.timestamp }
        n += 1; layer?.backgroundColor = NSColor(white: CGFloat(n % 2), alpha: 1).cgColor
        if l.timestamp - t0 > 3 { print(String(format: "requested %.0f Hz: displaylink %.1f Hz, mode %.0f Hz", rate, Double(n) / (l.timestamp - t0), CGDisplayCopyDisplayMode(vd.displayID)!.refreshRate)); exit(0) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    let scr = NSScreen.screens.first { $0.localizedName == "RateProbe" }!
    let w = NSWindow(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: scr)
    let v = V(frame: NSRect(origin: .zero, size: scr.frame.size)); v.wantsLayer = true
    w.contentView = v; w.setFrame(scr.frame, display: true); w.orderFrontRegardless()
    let l = v.displayLink(target: v, selector: #selector(V.tick(_:))); l.add(to: .main, forMode: .common)
}
app.run()
