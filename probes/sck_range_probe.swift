// Feasibility probe: what Y range does ScreenCaptureKit actually produce for 420f (full-range) output?
import Foundation
import ScreenCaptureKit
import CoreMedia
final class Out: NSObject, SCStreamOutput {
    var done = false
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !done, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        done = true
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var lo = 255, hi = 0
        for r in 200..<1400 { for c in 200..<2300 { let v = Int(y[r * bpr + c]); lo = min(lo, v); hi = max(hi, v) } }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        print("format \(String(format: "%08x", CVPixelBufferGetPixelFormatType(pb))) Y min \(lo) max \(hi)")
        exit(0)
    }
}
let out = Out()
Task {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let d = content.displays.first { $0.width == 1280 && $0.height == 800 }!
    let cfg = SCStreamConfiguration()
    cfg.width = 2560; cfg.height = 1600
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    cfg.colorSpaceName = CGColorSpace.sRGB
    cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
    cfg.showsCursor = false
    let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
    try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)
    try await s.startCapture()
}
RunLoop.main.run(until: Date().addingTimeInterval(5))
print("timeout")
