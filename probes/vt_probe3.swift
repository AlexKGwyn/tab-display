import Foundation
import VideoToolbox
import CoreMedia
func log(_ s: String) { print(s); fflush(stdout) }
func run(_ label: String, codec: CMVideoCodecType = kCMVideoCodecType_HEVC, ll: Bool = true, w: Int = 2560, h: Int = 1600, complete: Bool = false, props: [CFString: Any]) {
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if ll { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec, encoderSpecification: spec as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let s = session else { log("create fail"); return }
    for (k, v) in props { let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef); if r != 0 { log("  \(k) -> \(r)") } }
    VTCompressionSessionPrepareToEncodeFrames(s)
    var bufs: [CVPixelBuffer] = []
    for i in 0..<4 {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self)
        memset(y, Int32(60 * i), CVPixelBufferGetBytesPerRowOfPlane(pb!, 0) * h)
        memset(CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(pb!, 1) * h / 2)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        bufs.append(pb!)
    }
    var times: [Double] = []
    for i in 0..<150 {
        let sem = DispatchSemaphore(value: 0)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let pts = CMTime(value: Int64(i), timescale: 120)
        VTCompressionSessionEncodeFrame(s, imageBuffer: bufs[i % 4], presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6); sem.signal()
        }
        if complete { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: pts) }
        sem.wait()
        usleep(5000)
    }
    VTCompressionSessionInvalidate(s)
    let t = times.dropFirst(10).sorted()
    log(String(format: "%-40@ p50=%.2f p95=%.2f", label as NSString, t[t.count/2], t[Int(Double(t.count)*0.95)]))
}
let base: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: true, kVTCompressionPropertyKey_AllowFrameReordering: false,
    kVTCompressionPropertyKey_ExpectedFrameRate: 120, kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
    kVTCompressionPropertyKey_MaximizePowerEfficiency: false, kVTCompressionPropertyKey_AverageBitRate: 80_000_000]
run("nonll fps240 maxdelay0", ll: false, props: base.merging([kVTCompressionPropertyKey_ExpectedFrameRate: 240, kVTCompressionPropertyKey_MaxFrameDelayCount: 0]) { $1 })
run("nonll speed", ll: false, props: base.merging([kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true]) { $1 })
run("h264 nonll speed", codec: kCMVideoCodecType_H264, ll: false, props: base.merging([kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true]) { $1 })
run("nonll speed fps240", ll: false, props: base.merging([kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true, kVTCompressionPropertyKey_ExpectedFrameRate: 240]) { $1 })
run("nonll speed 1920x1200", ll: false, w: 1920, h: 1200, props: base.merging([kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true]) { $1 })
run("nonll speed 2560x1600 DRL", ll: false, props: base.merging([kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true, kVTCompressionPropertyKey_DataRateLimits: [400_000, 0.004] as CFArray]) { $1 })
run("nonll speed realtime=false", ll: false, props: base.merging([kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true, kVTCompressionPropertyKey_RealTime: false]) { $1 })
