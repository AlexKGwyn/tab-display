// Demo scene for README screenshots: a neutral backdrop over the whole Tab Display virtual display
// (so no personal wallpaper or windows show) and a "Sketch" window that draws pen/mouse strokes,
// with width following tablet pressure.
// Build: swiftc -O tools/SketchDemo.swift -o tools/build/sketchdemo
import AppKit

func tabDisplayScreen() -> NSScreen? {
    NSScreen.screens.first { s in
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayVendorNumber($0.uint32Value) == 0x5344 } ?? false
    }
}

final class Backdrop: NSView {
    override func draw(_ r: NSRect) {
        NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.86, alpha: 1),
                            NSColor(calibratedRed: 0.22, green: 0.15, blue: 0.58, alpha: 1),
                            NSColor(calibratedRed: 0.09, green: 0.07, blue: 0.30, alpha: 1)])!
            .draw(in: bounds, angle: -35)
    }
}

final class Canvas: NSView {
    private var strokes: [[(NSPoint, CGFloat)]] = []
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func sample(_ e: NSEvent) -> (NSPoint, CGFloat) {
        let p = convert(e.locationInWindow, from: nil)
        let pressure = e.subtype == .tabletPoint ? CGFloat(e.pressure) : 0.6
        return (p, 2.5 + 9 * pressure)
    }
    override func mouseDown(with e: NSEvent) { strokes.append([sample(e)]); needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { strokes[strokes.count - 1].append(sample(e)); needsDisplay = true }

    override func draw(_ r: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        // Faint dot grid
        NSColor(white: 0.85, alpha: 1).setFill()
        for x in stride(from: 20.0, to: bounds.width, by: 24) {
            for y in stride(from: 20.0, to: bounds.height, by: 24) { NSRect(x: x, y: y, width: 1.6, height: 1.6).fill() }
        }
        let colors: [NSColor] = [.systemIndigo, .systemPink, .systemTeal, .systemOrange]
        for (i, s) in strokes.enumerated() {
            colors[i % colors.count].setStroke()
            for k in 1..<max(1, s.count) {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineWidth = (s[k - 1].1 + s[k].1) / 2
                path.move(to: s[k - 1].0)
                path.line(to: s[k].0)
                path.stroke()
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = tabDisplayScreen() else { print("Tab Display screen not found"); exit(1) }
// Covers the whole display (above normal windows) so only this scene is visible.
let back = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
back.contentView = Backdrop()
back.level = .floating
back.setFrame(screen.frame, display: true)  // absolute coordinates (init's rect is screen-relative)
back.orderFrontRegardless()

let f = screen.visibleFrame
let size = NSSize(width: f.width * 0.78, height: f.height * 0.78)
let win = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
win.title = "Sketch"
win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
win.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
win.contentView = Canvas()
win.makeKeyAndOrderFront(nil)
win.orderFrontRegardless()
app.activate(ignoringOtherApps: true)
print("sketch on \(screen.frame)")
fflush(stdout)
app.run()
