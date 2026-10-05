// PSNR (luma) between two images over a region. Usage: imagediff a.png b.png [x y w h]
import Foundation
import CoreGraphics
import ImageIO
func load(_ p: String) -> (Int, Int, [UInt8]) {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}
let a = load(CommandLine.arguments[1]), b = load(CommandLine.arguments[2])
precondition(a.0 == b.0 && a.1 == b.1, "size mismatch \(a.0)x\(a.1) vs \(b.0)x\(b.1)")
let r = CommandLine.arguments.count >= 7 ? CommandLine.arguments[3...6].map { Int($0)! } : [0, 0, a.0, a.1]
// Luma pairs over the region, then raw PSNR and PSNR after a least-squares level fit (a·x + b),
// which removes a constant black-level/contrast difference and leaves compression error.
var xs: [Double] = [], ys: [Double] = []
for y in r[1]..<(r[1] + r[3]) { for x in r[0]..<(r[0] + r[2]) {
    let i = (y * a.0 + x) * 4
    func luma(_ p: [UInt8]) -> Double { 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2]) }
    xs.append(luma(a.2)); ys.append(luma(b.2))
} }
let n = Double(xs.count)
func psnr(_ f: (Double) -> Double) -> Double {
    var se = 0.0
    for k in 0..<xs.count { let d = f(xs[k]) - ys[k]; se += d * d }
    return 10 * log10(255 * 255 / max(se / n, 1e-9))
}
let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
var sxy = 0.0, sxx = 0.0
for k in 0..<xs.count { sxy += (xs[k] - mx) * (ys[k] - my); sxx += (xs[k] - mx) * (xs[k] - mx) }
let slope = sxy / max(sxx, 1e-9), icpt = my - slope * mx
print(String(format: "PSNR %.2f dB raw, %.2f dB level-fitted (b = %.3f·a %+.1f)", psnr { $0 }, psnr { slope * $0 + icpt }, slope, icpt))
