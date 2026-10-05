// Renders the Tab Display app icon artwork.
//   swiftc -O tools/MakeIcons.swift -o tools/build/makeicons && tools/build/makeicons <outdir>
// Writes <outdir>/icon_1024.png (macOS: squircle tile with margin, per Apple's grid) and
// <outdir>/android_foreground.png / android_full.png (Android adaptive-icon layers, 432 px).
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    draw(ctx, CGFloat(size))
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("wrote \(name)")
}

/// Background: deep blue → indigo diagonal gradient with a soft top highlight.
func background(_ c: CGContext, _ rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x2F6BFF), rgb(0x3B2FB8), rgb(0x1B1460)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(hl, startCenter: CGPoint(x: rect.midX - rect.width * 0.2, y: rect.maxY), startRadius: 0,
                         endCenter: CGPoint(x: rect.midX - rect.width * 0.2, y: rect.maxY), endRadius: rect.width * 0.75, options: [])
}

/// The glyph: a landscape tablet showing a slice of a desktop, with a stylus across it.
/// `u` is the glyph's unit (its width); origin at the glyph's center.
func glyph(_ c: CGContext, center: CGPoint, width u: CGFloat) {
    let tw = u, th = u * 0.66
    let tablet = CGRect(x: center.x - tw / 2, y: center.y - th / 2 + u * 0.03, width: tw, height: th)
    // Shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -u * 0.025), blur: u * 0.06, color: rgb(0x000000, 0.35))
    c.addPath(CGPath(roundedRect: tablet, cornerWidth: u * 0.075, cornerHeight: u * 0.075, transform: nil))
    c.setFillColor(rgb(0x14161C))
    c.fillPath()
    c.restoreGState()
    // Bezel edge highlight
    c.addPath(CGPath(roundedRect: tablet.insetBy(dx: u * 0.004, dy: u * 0.004), cornerWidth: u * 0.072, cornerHeight: u * 0.072, transform: nil))
    c.setStrokeColor(rgb(0xFFFFFF, 0.18))
    c.setLineWidth(u * 0.008)
    c.strokePath()
    // Screen
    let screen = tablet.insetBy(dx: u * 0.045, dy: u * 0.045)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: u * 0.035, cornerHeight: u * 0.035, transform: nil)
    c.saveGState()
    c.addPath(screenPath)
    c.clip()
    let sg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x7FD3FF), rgb(0x4B7BFF), rgb(0x8A5CFF)] as CFArray, locations: [0, 0.5, 1])!
    c.drawLinearGradient(sg, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    // Menu bar
    c.setFillColor(rgb(0xFFFFFF, 0.55))
    c.fill(CGRect(x: screen.minX, y: screen.maxY - u * 0.035, width: screen.width, height: u * 0.035))
    // Two windows
    func window(_ r: CGRect, _ alpha: CGFloat) {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -u * 0.006), blur: u * 0.02, color: rgb(0x000000, 0.25))
        c.addPath(CGPath(roundedRect: r, cornerWidth: u * 0.018, cornerHeight: u * 0.018, transform: nil))
        c.setFillColor(rgb(0xFFFFFF, alpha))
        c.fillPath()
        c.restoreGState()
        // title bar dots
        for (i, col) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            c.setFillColor(rgb(UInt32(col)))
            let d = u * 0.016
            c.fillEllipse(in: CGRect(x: r.minX + u * 0.02 + CGFloat(i) * d * 1.6, y: r.maxY - u * 0.03, width: d, height: d))
        }
        // text lines
        c.setFillColor(rgb(0x1B1F2A, 0.18))
        for k in 0..<3 {
            c.fill(CGRect(x: r.minX + u * 0.025, y: r.maxY - u * 0.07 - CGFloat(k) * u * 0.03, width: r.width * (k == 2 ? 0.45 : 0.75), height: u * 0.012))
        }
    }
    window(CGRect(x: screen.minX + screen.width * 0.08, y: screen.minY + screen.height * 0.18, width: screen.width * 0.48, height: screen.height * 0.6), 0.92)
    window(CGRect(x: screen.minX + screen.width * 0.44, y: screen.minY + screen.height * 0.08, width: screen.width * 0.46, height: screen.height * 0.5), 0.97)
    c.restoreGState()

    // Stylus, lying diagonally across the lower right
    c.saveGState()
    c.translateBy(x: center.x + u * 0.2, y: center.y - u * 0.26)
    c.rotate(by: .pi * 0.17)
    let pl = u * 0.78, pw = u * 0.062
    let body = CGRect(x: -pl / 2, y: -pw / 2, width: pl, height: pw)
    c.setShadow(offset: CGSize(width: 0, height: -u * 0.02), blur: u * 0.05, color: rgb(0x000000, 0.4))
    let tip = CGMutablePath()
    tip.move(to: CGPoint(x: body.minX, y: body.minY))
    tip.addLine(to: CGPoint(x: body.minX - pw * 1.6, y: 0))
    tip.addLine(to: CGPoint(x: body.minX, y: body.maxY))
    tip.closeSubpath()
    c.addPath(tip)
    c.addPath(CGPath(roundedRect: body, cornerWidth: pw / 2, cornerHeight: pw / 2, transform: nil))
    c.setFillColor(rgb(0xE9ECF3))
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    // shading along the barrel
    c.addPath(CGPath(roundedRect: body, cornerWidth: pw / 2, cornerHeight: pw / 2, transform: nil))
    c.clip()
    let pg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFFFFF, 0.9), rgb(0xB9C0CF, 0.9)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(pg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    c.resetClip()
    // nib and side button
    c.setFillColor(rgb(0x2B2F3A))
    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: body.minX - pw * 1.1, y: -pw * 0.17))
    nib.addLine(to: CGPoint(x: body.minX - pw * 1.6, y: 0))
    nib.addLine(to: CGPoint(x: body.minX - pw * 1.1, y: pw * 0.17))
    nib.closeSubpath()
    c.addPath(nib)
    c.fillPath()
    c.addPath(CGPath(roundedRect: CGRect(x: body.minX + pl * 0.16, y: body.maxY - pw * 0.32, width: pl * 0.12, height: pw * 0.2), cornerWidth: pw * 0.1, cornerHeight: pw * 0.1, transform: nil))
    c.fillPath()
    c.restoreGState()
}

// macOS icon: 1024 canvas, 824×824 rounded tile (radius ≈ 185) centered, per Apple's icon grid.
let mac = render(1024) { c, s in
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.3))
    c.addPath(path)
    c.setFillColor(rgb(0x1B1460))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(path)
    c.clip()
    background(c, tile)
    glyph(c, center: CGPoint(x: tile.midX, y: tile.midY + 20), width: 600)
    c.restoreGState()
}
save(mac, "icon_1024.png")

// Android adaptive icon (108 dp; safe zone = inner 66 dp). Rendered at 432 px = 4× (xxxhdpi).
let fg = render(432) { c, s in
    glyph(c, center: CGPoint(x: s / 2, y: s / 2 + 6), width: s * 0.56)
}
save(fg, "android_foreground.png")
let bg = render(432) { c, s in background(c, CGRect(x: 0, y: 0, width: s, height: s)) }
save(bg, "android_background.png")
// Flattened preview / legacy icon / Play Store icon (512).
let play = render(512) { c, s in
    background(c, CGRect(x: 0, y: 0, width: s, height: s))
    glyph(c, center: CGPoint(x: s / 2, y: s / 2 + 8), width: s * 0.66)
}
save(play, "play_store_512.png")
