import Foundation
import CoreGraphics
import CPrivate

/// How much space the tablet's display offers. All options are HiDPI; capture is always at the
/// tablet's native resolution, so "Sharpest" (exactly 2×) maps pixels 1:1.
enum DisplayMode: String, CaseIterable, Identifiable {
    case sharpest = "Sharpest"
    case moreSpace = "More space"
    case mostSpace = "Most space"
    var id: String { rawValue }

    var scale: Double {
        switch self {
        case .sharpest: return 1
        case .moreSpace: return 1.125
        case .mostSpace: return 1.25
        }
    }

    /// "Looks like" size in points for a panel of `px` pixels.
    func points(panel px: (w: Int, h: Int)) -> (w: Int, h: Int) {
        func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
        return (even(Double(px.w) / 2 * scale), even(Double(px.h) / 2 * scale))
    }
}

/// Owns a CGVirtualDisplay for the session. Releasing this object removes the display.
final class VirtualDisplay {
    /// Fixed vendor ID so macOS remembers the arrangement, and tools can find the display.
    static let vendorID: UInt32 = 0x5344

    private let display: CGVirtualDisplay
    private var panel: (w: Int, h: Int)
    var displayID: CGDirectDisplayID { display.displayID }

    init?(name: String, panel: (w: Int, h: Int), sizeMm: (w: Int, h: Int), mode: DisplayMode, refresh: Double) {
        self.panel = panel
        // Room for either orientation, so rotating the tablet only switches modes.
        let longest = DisplayMode.mostSpace.points(panel: (max(panel.w, panel.h), max(panel.w, panel.h)))
        let d = CGVirtualDisplayDescriptor()
        d.queue = DispatchQueue.main
        d.name = name
        d.maxPixelsWide = UInt32(longest.w * 2)
        d.maxPixelsHigh = UInt32(longest.h * 2)
        // Physical size from the tablet so text has the right physical size and DPI.
        d.sizeInMillimeters = sizeMm.w > 0 ? CGSize(width: sizeMm.w, height: sizeMm.h)
                                            : CGSize(width: Double(panel.w) / 10.8, height: Double(panel.h) / 10.8)  // ~275 dpi guess
        d.vendorID = VirtualDisplay.vendorID
        // Per-tablet product ID (orientation-independent) so each tablet keeps its own arrangement.
        d.productID = UInt32((max(panel.w, panel.h) &* 31 &+ min(panel.w, panel.h)) & 0xFFFF)
        d.serialNum = 0x0001
        d.terminationHandler = { _, _ in Log.info("virtual display terminated by the system") }
        guard let vd = CGVirtualDisplay(descriptor: d) else { return nil }
        display = vd
        guard apply(mode: mode, refresh: refresh) else { return nil }
        let pts = mode.points(panel: panel)
        Log.info("virtual display \(displayID) created: \(pts.w)×\(pts.h) pt HiDPI for a \(panel.w)×\(panel.h) panel @ \(Int(refresh)) Hz")
    }

    /// The tablet rotated or its window resized: switch to modes of the new shape in place, so
    /// the display (and the windows on it) survive.
    @discardableResult
    func reshape(panel: (w: Int, h: Int), mode: DisplayMode, refresh: Double) -> Bool {
        self.panel = panel
        let ok = apply(mode: mode, refresh: refresh)
        let pts = mode.points(panel: panel)
        Log.info("virtual display \(displayID) reshaped: \(pts.w)×\(pts.h) pt for a \(panel.w)×\(panel.h) area (\(ok ? "ok" : "failed"))")
        return ok
    }

    /// Publishes the mode list for the current shape and switches to `mode`. Re-publishing the
    /// list alone doesn't change an existing display's mode, so switch explicitly once macOS has
    /// picked up the new list.
    @discardableResult
    func apply(mode: DisplayMode, refresh: Double) -> Bool {
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1
        let ordered = [mode] + DisplayMode.allCases.filter { $0 != mode }  // first = initial mode
        let rates = refresh > 60 ? [refresh, 60.0] : [60.0]
        s.modes = ordered.flatMap { m in
            let p = m.points(panel: panel)
            return rates.map { CGVirtualDisplayMode(width: UInt(p.w), height: UInt(p.h), refreshRate: $0) }
        }
        guard display.apply(s) else { return false }
        switchTo(mode, refresh: refresh, attempts: 20)
        return true
    }

    private func switchTo(_ mode: DisplayMode, refresh: Double, attempts: Int) {
        let pts = mode.points(panel: panel)
        let id = displayID
        if let cur = CGDisplayCopyDisplayMode(id), cur.width == pts.w, cur.height == pts.h, cur.pixelWidth == pts.w * 2 { return }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        // The HiDPI variant (2 px per point), preferring the requested refresh rate.
        let candidates = modes.filter { $0.width == pts.w && $0.height == pts.h && $0.pixelWidth == pts.w * 2 }
        if let target = candidates.min(by: { abs($0.refreshRate - refresh) < abs($1.refreshRate - refresh) }) {
            let err = CGDisplaySetDisplayMode(id, target, nil)
            Log.info("display \(id): switched to \(pts.w)×\(pts.h) pt (\(target.pixelWidth)×\(target.pixelHeight) px @ \(Int(target.refreshRate)) Hz) → \(err == .success ? "ok" : "error \(err.rawValue)")")
        } else if attempts > 0 {
            // The new mode list takes a moment to show up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.switchTo(mode, refresh: refresh, attempts: attempts - 1) }
        } else {
            Log.info("display \(id): mode \(pts.w)×\(pts.h) HiDPI not available")
        }
    }

    var bounds: CGRect { CGDisplayBounds(displayID) }
}
