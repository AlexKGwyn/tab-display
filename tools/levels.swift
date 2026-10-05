import Foundation
import CoreGraphics
import ImageIO
for p in CommandLine.arguments.dropFirst() {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var hist = [Int](repeating: 0, count: 256)
    for y in 200..<1400 { for x in 200..<2300 { hist[Int(buf[(y * w + x) * 4 + 1])] += 1 } }
    let total = hist.reduce(0, +)
    func pct(_ q: Double) -> Int { var c = 0; for i in 0..<256 { c += hist[i]; if Double(c) >= q * Double(total) { return i } }; return 255 }
    print(p, "colorspace:", img.colorSpace?.name ?? "nil" as CFString, "G p0.5%:", pct(0.005), "p2%:", pct(0.02), "p50%:", pct(0.5), "max:", pct(1.0))
}
