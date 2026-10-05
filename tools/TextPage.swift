// Scrollable page of 12 pt text on the Tab Display virtual display. After 2 s it scrolls 400 pt
// over ~0.4 s and stops, printing the stop time. Used to check that text sharpens after motion.
// Build: swiftc -O TextPage.swift -o build/textpage
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
let scroll = NSScrollView(frame: NSRect(origin: .zero, size: screen.frame.size))
let text = NSTextView(frame: NSRect(x: 0, y: 0, width: screen.frame.width, height: 20000))
text.font = NSFont.systemFont(ofSize: 12)
text.textContainerInset = NSSize(width: 40, height: 30)
let para = "The quick brown fox jumps over the lazy dog. Sphinx of black quartz, judge my vow — 0123456789 (){}[] <>/\\|. "
text.string = (0..<400).map { i in "\(i): " + String(repeating: para, count: 3) }.joined(separator: "\n")
text.textColor = .black
text.backgroundColor = .white
scroll.documentView = text
scroll.hasVerticalScroller = false
win.contentView = scroll
win.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    var step = 0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { t in
        step += 1
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 16.5))
        scroll.reflectScrolledClipView(scroll.contentView)
        if step == 24 { t.invalidate(); print("stopped"); fflush(stdout) }
    }
}
app.run()
