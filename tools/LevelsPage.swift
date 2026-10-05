// Solid black left half, solid white right half on the Tab Display virtual display: black/white level check.
// Build: swiftc -O LevelsPage.swift -o build/levelspage
import AppKit

/// The Tab Display virtual display (found by its fixed vendor ID; its name is the tablet's).
func tabDisplayScreen() -> NSScreen? {
    NSScreen.screens.first { s in
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayVendorNumber($0.uint32Value) == 0x5344 } ?? false
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = tabDisplayScreen() else { print("Tab Display screen not found"); exit(1) }
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.setFrame(screen.frame, display: true)
win.level = .floating
let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
v.wantsLayer = true
v.layer!.backgroundColor = NSColor.white.cgColor
let black = CALayer()
black.frame = CGRect(x: 0, y: 0, width: screen.frame.width / 2, height: screen.frame.height)
black.backgroundColor = NSColor.black.cgColor
v.layer!.addSublayer(black)
win.contentView = v
win.orderFrontRegardless()
app.run()
