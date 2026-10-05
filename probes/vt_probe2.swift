// Feasibility probe: VideoToolbox encode latency variants at 2560x1600 with desktop-like content.
import Foundation
import VideoToolbox
import CoreMedia
func log(_ s: String) { print(s); fflush(stdout) }

func run(_ codec: CMVideoCodecType, _ name: String, lowLatency: Bool, content: String, pace: Bool) {
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: nil, width: 2560, height: 1600, codecType: codec, encoderSpecification: spec as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let s = session else { log("\(name) create fail"); return }
    func set(_ k: CFString, _ v: Any) { _ = VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
    set(kVTCompressionPropertyKey_RealTime, true)
    set(kVTCompressionPropertyKey_AllowFrameReordering, false)
    set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, 120)
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max)
    set(kVTCompressionPropertyKey_MaximizePowerEfficiency, false)
    set(kVTCompressionPropertyKey_AverageBitRate, 80_000_000)
    set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
    if lowLatency { set(kVTCompressionPropertyKey_DataRateLimits, [400_000, 0.004] as CFArray) }
    VTCompressionSessionPrepareToEncodeFrames(s)
    // Pool of IOSurface buffers, pre-filled so no CPU writes happen in the timed loop.
    var bufs: [CVPixelBuffer] = []
    for i in 0..<8 {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2560, 1600, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvs = CVPixelBufferGetBytesPerRowOfPlane(pb!, 1)
        for r in 0..<1600 { for c in 0..<2560 {
            var v: UInt8 = 235
            if content == "text" { v = ((r / 2 + c / 3 + i * 5) % 17 < 2 && (r % 40) < 28) ? 20 : 240 }   // text-like strokes, scrolled per buffer
            else { let bx = 400 + i * 120; v = (c >= bx && c < bx + 300 && r >= 600 && r < 900) ? 30 : UInt8((r * 255) / 1600) }   // gradient + moving box
            y[r * ys + c] = v } }
        for r in 0..<800 { for c in 0..<2560 { uv[r * uvs + c] = 128 } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        bufs.append(pb!)
    }
    var times: [Double] = [], sizes: [Int] = []
    for i in 0..<240 {
        let sem = DispatchSemaphore(value: 0)
        let t0 = DispatchTime.now().uptimeNanoseconds
        VTCompressionSessionEncodeFrame(s, imageBuffer: bufs[i % 8], presentationTimeStamp: CMTime(value: Int64(i), timescale: 120), duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sb in
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            if let sb { sizes.append(CMSampleBufferGetTotalSampleSize(sb)) }
            sem.signal()
        }
        sem.wait()
        if pace { usleep(8333 - UInt32(min(8000, (DispatchTime.now().uptimeNanoseconds - t0) / 1000))) }
    }
    VTCompressionSessionInvalidate(s)
    let t = times.dropFirst(10).sorted()
    log(String(format: "%@ ll=%d %@ pace=%d: p50=%.2f p95=%.2f ms, avg %d KB", name, lowLatency ? 1 : 0, content, pace ? 1 : 0, t[t.count/2], t[Int(Double(t.count)*0.95)], sizes.reduce(0,+)/max(1,sizes.count)/1024))
}
for content in ["box", "text"] {
    for ll in [true, false] {
        run(kCMVideoCodecType_HEVC, "HEVC", lowLatency: ll, content: content, pace: true)
        run(kCMVideoCodecType_H264, "H264", lowLatency: ll, content: content, pace: true)
    }
}
run(kCMVideoCodecType_HEVC, "HEVC", lowLatency: true, content: "text", pace: false)
