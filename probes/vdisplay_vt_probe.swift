// Feasibility probe: CGVirtualDisplay at 2560x1600 HiDPI 120 Hz, VideoToolbox low-latency
// HEVC/H.264 encode timing at 2560x1600, and ScreenCaptureKit access.
// Build: swiftc -O -import-objc-header ../mac/Sources/CPrivate/include/CGVirtualDisplay.h vdisplay_vt_probe.swift -o build/vdisplay_vt_probe
import Foundation
import CoreGraphics
import VideoToolbox
import ScreenCaptureKit
import CoreMedia

func log(_ s: String) { print(s); fflush(stdout) }

// MARK: virtual display
let desc = CGVirtualDisplayDescriptor()
desc.queue = DispatchQueue.main
desc.name = "Probe Tab S9"
desc.maxPixelsWide = 3200
desc.maxPixelsHigh = 2000
desc.sizeInMillimeters = CGSize(width: 239, height: 150)
desc.vendorID = 0x5344; desc.productID = 0x0009; desc.serialNum = 0x0001
desc.terminationHandler = { _, _ in log("virtual display terminated") }
guard let vd = CGVirtualDisplay(descriptor: desc) else { log("FAIL: CGVirtualDisplay init"); exit(1) }
let settings = CGVirtualDisplaySettings()
settings.hiDPI = 1
settings.modes = [
    CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 120),
    CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60),
    CGVirtualDisplayMode(width: 1440, height: 900, refreshRate: 120),
    CGVirtualDisplayMode(width: 1600, height: 1000, refreshRate: 120),
]
log("applySettings: \(vd.apply(settings)) displayID=\(vd.displayID)")
RunLoop.main.run(until: Date().addingTimeInterval(1.5))
if let cur = CGDisplayCopyDisplayMode(vd.displayID) {
    log("current mode: \(cur.width)x\(cur.height) pts, \(cur.pixelWidth)x\(cur.pixelHeight) px @ \(cur.refreshRate) Hz")
}
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
if let modes = CGDisplayCopyAllDisplayModes(vd.displayID, opts) as? [CGDisplayMode] {
    for m in modes { log("  mode: \(m.width)x\(m.height) pts, \(m.pixelWidth)x\(m.pixelHeight) px @ \(m.refreshRate)") }
}
log("bounds: \(CGDisplayBounds(vd.displayID))")

// MARK: VideoToolbox
func probeEncoder(_ codec: CMVideoCodecType, name: String) {
    let spec: [CFString: Any] = [
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    var session: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: 2560, height: 1600, codecType: codec,
        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard st == noErr, let s = session else { log("\(name): create failed \(st)"); return }
    func set(_ k: CFString, _ v: Any) { let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef); if r != noErr { log("  \(name) set \(k) -> \(r)") } }
    set(kVTCompressionPropertyKey_RealTime, true)
    set(kVTCompressionPropertyKey_AllowFrameReordering, false)
    set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, 120)
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max)
    set(kVTCompressionPropertyKey_MaximizePowerEfficiency, false)
    set(kVTCompressionPropertyKey_AverageBitRate, 80_000_000)
    set(kVTCompressionPropertyKey_DataRateLimits, [250_000, 0.002] as CFArray)
    if codec == kCMVideoCodecType_HEVC { set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel) }
    var usingHW: CFBoolean?
    VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &usingHW)
    log("\(name): created, hw=\(String(describing: usingHW))")

    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    CVPixelBufferCreate(nil, 2560, 1600, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pb)
    var times: [Double] = []
    var sizes: [Int] = []
    for i in 0..<240 {
        // Move some content so each frame differs.
        CVPixelBufferLockBaseAddress(pb!, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0)
        for row in 0..<1600 { let p = y + row * stride; for col in stride_from(i) { p[col] = UInt8((row ^ col &+ i) & 0xff) } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        let sem = DispatchSemaphore(value: 0)
        let t0 = DispatchTime.now().uptimeNanoseconds
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(i), timescale: 120),
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sbuf in
            let t1 = DispatchTime.now().uptimeNanoseconds
            times.append(Double(t1 - t0) / 1e6)
            if let sb = sbuf { sizes.append(CMSampleBufferGetTotalSampleSize(sb)) }
            sem.signal()
        }
        sem.wait()
    }
    VTCompressionSessionInvalidate(s)
    let sorted = times.dropFirst(10).sorted()
    log(String(format: "\(name): encode ms p50=%.2f p95=%.2f max=%.2f, avg size=%d B", sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, sizes.reduce(0, +) / max(1, sizes.count)))
}
func stride_from(_ i: Int) -> StrideTo<Int> { Swift.stride(from: (i * 7) % 2560, to: 2560, by: 3) }

probeEncoder(kCMVideoCodecType_HEVC, name: "HEVC")
probeEncoder(kCMVideoCodecType_H264, name: "H264")

// MARK: ScreenCaptureKit
log("CGPreflightScreenCaptureAccess=\(CGPreflightScreenCaptureAccess())")
let done = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        log("SCK displays: \(content.displays.map { "\($0.displayID) \($0.width)x\($0.height)" })")
    } catch { log("SCK error: \(error)") }
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
_ = vd
log("done")
