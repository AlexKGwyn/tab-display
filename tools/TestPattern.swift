// Full-screen moving test pattern on the Tab Display virtual display (or the screen given by --screen <name>).
// A white bar sweeps horizontally once per second, a frame counter and a millisecond clock update every
// vsync. Use it to drive the pipeline at the full refresh rate and for the 240 fps camera test
// (run a second copy with --screen <main display name> to compare side by side).
// Build: swiftc -O TestPattern.swift -o build/testpattern
import AppKit

/// The Tab Display virtual display (found by its fixed vendor ID; its name is the tablet's).
func tabDisplayScreen() -> NSScreen? {
    NSScreen.screens.first { s in
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayVendorNumber($0.uint32Value) == 0x5344 } ?? false
    }
}
import QuartzCore

let args = CommandLine.arguments
let screenName = args.firstIndex(of: "--screen").map { args[$0 + 1] }

final class PatternView: NSView {
    let bar = CALayer()
    let label = CATextLayer()
    var frameCount = 0
    var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        bar.backgroundColor = NSColor.white.cgColor
        bar.actions = ["position": NSNull(), "bounds": NSNull()]
        layer!.addSublayer(bar)
        label.fontSize = 64
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        label.foregroundColor = NSColor.systemGreen.cgColor
        label.actions = ["contents": NSNull()]
        layer!.addSublayer(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        label.contentsScale = window!.backingScaleFactor
        link = displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    var lastReport = CACurrentMediaTime(), reportCount = 0
    @objc func tick(_ l: CADisplayLink) {
        frameCount += 1
        reportCount += 1
        if l.timestamp - lastReport >= 2 {
            print(String(format: "displaylink %.1f Hz (duration %.2f ms)", Double(reportCount) / (l.timestamp - lastReport), l.duration * 1000))
            fflush(stdout)
            lastReport = l.timestamp; reportCount = 0
        }
        let b = bounds
        let t = CACurrentMediaTime()
        let x = (t.truncatingRemainder(dividingBy: 1.0)) * b.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = CGRect(x: x, y: 0, width: 24, height: b.height * 0.6)
        label.frame = CGRect(x: 40, y: b.height - 120, width: b.width - 80, height: 90)
        label.string = String(format: "%06d   %.3f s", frameCount, t)
        CATransaction.commit()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = screenName.map({ n in NSScreen.screens.first { $0.localizedName == n } }) ?? tabDisplayScreen() else {
    print("screen not found; screens: \(NSScreen.screens.map { $0.localizedName })")
    exit(1)
}
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.setFrame(screen.frame, display: true)
win.level = .floating
win.contentView = PatternView(frame: NSRect(origin: .zero, size: screen.frame.size))
win.orderFrontRegardless()
print("test pattern on \(screen.localizedName) \(screen.frame)")
app.run()
