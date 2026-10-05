import AppKit

/// Menu bar glyph matching the app icon: a landscape tablet with a stylus. Template image, so it
/// follows the menu bar's light/dark appearance. Slightly larger than a stock SF Symbol.
enum MenuBarIcon {
    static func image(connected: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // Tablet body
            let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 3.5, width: 19, height: 13), xRadius: 2.6, yRadius: 2.6)
            body.lineWidth = 1.6
            body.stroke()
            // Screen: filled when connected
            let screen = NSBezierPath(roundedRect: NSRect(x: 3.6, y: 6.1, width: 13.8, height: 7.8), xRadius: 1, yRadius: 1)
            if connected { screen.fill() } else { screen.lineWidth = 1; screen.stroke() }
            // Stylus across the lower right corner, with a gap cut out of the tablet behind it
            let t = NSAffineTransform()
            t.translateX(by: 17.2, yBy: 4.2)
            t.rotate(byDegrees: 32)
            let pen = NSBezierPath()
            pen.move(to: NSPoint(x: -8, y: 0))
            pen.line(to: NSPoint(x: -5.6, y: -1.25))
            pen.line(to: NSPoint(x: 5.6, y: -1.25))
            pen.appendArc(withCenter: NSPoint(x: 5.6, y: 0), radius: 1.25, startAngle: 270, endAngle: 90)
            pen.line(to: NSPoint(x: -5.6, y: 1.25))
            pen.close()
            pen.transform(using: t as AffineTransform)
            NSGraphicsContext.current?.compositingOperation = .clear
            let halo = pen.copy() as! NSBezierPath
            halo.lineWidth = 2.6
            halo.stroke()
            halo.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            pen.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = connected ? "Tab Display (connected)" : "Tab Display"
        return img
    }
}
