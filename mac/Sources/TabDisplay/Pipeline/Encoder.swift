import Foundation
import VideoToolbox
import CoreMedia

enum CodecChoice: UInt8 {
    case hevc = 0, h264 = 1
    var cm: CMVideoCodecType { self == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264 }
}

struct EncodedFrame {
    let annexB: Data
    let keyframe: Bool
    let refinement: Bool
    let displayNs: Int64
    let callbackNs: Int64
    let encodedNs: Int64
}

/// Hardware VideoToolbox encoder, one frame in → one access unit out, no reordering.
///
/// Measured (M3, macOS 26): `EnableLowLatencyRateControl` encodes 2560×1600 in ~11 ms vs
/// ~6.3 ms with the default real-time rate control, so low-latency RC is off by default.
final class Encoder {
    private var session: VTCompressionSession?
    let codec: CodecChoice
    private let fps: Int
    var onOutput: ((EncodedFrame) -> Void)?
    private var frameIndex: Int64 = 0
    private var currentCap = 0
    /// Pure hardware encode time (submit → output), ms.
    let encodeDuration = SampleWindow()

    init(codec: CodecChoice, width: Int, height: Int, fps: Int, bitrate: Int, lowLatencyRC: Bool = false) throws {
        self.codec = codec
        self.fps = fps
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatencyRC { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec.cm,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw NSError(domain: "Encoder", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed (\(st))"]) }
        session = s
        let env = ProcessInfo.processInfo.environment
        set(kVTCompressionPropertyKey_RealTime, env["TD_REALTIME"] != "0")
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, Int(env["TD_EXPECTED_FPS"] ?? "") ?? fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 0)
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, false)
        set(kVTCompressionPropertyKey_ProfileLevel, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)  // must match the capture buffers' tags, or VideoToolbox adds a conversion pass (~3 ms)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(s)
        Log.info("encoder: \(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height)@\(fps) \(bitrate / 1_000_000) Mbps lowLatencyRC=\(lowLatencyRC)")
    }

    private func set(_ key: CFString, _ value: Any) {
        guard let s = session else { return }
        let r = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
        if r != noErr { Log.info("encoder: \(key) not supported (\(r))") }
    }

    func setBitrate(_ bps: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bps)
    }

    private var maxQP: Int?

    /// Idle refinement: cap the quantizer so re-encoding a static frame actually adds detail
    /// (at the normal QP the encoder just emits skip blocks). nil restores rate control.
    func setMaxQP(_ qp: Int?) {
        guard qp != maxQP else { return }
        maxQP = qp
        set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp ?? 51)
    }

    /// Caps the size of any single frame (bytes per frame interval).
    func setFrameCap(_ bytes: Int) {
        guard bytes != currentCap else { return }
        currentCap = bytes
        set(kVTCompressionPropertyKey_DataRateLimits, [bytes, 1.0 / Double(fps)] as CFArray)
    }

    private var loggedBuffer = false
    private var lastYStats: Int64 = 0
    private static let yStats = ProcessInfo.processInfo.environment["TD_YSTATS"] == "1"

    /// Debug: Y plane range of the captured frame (reads pixels on the CPU; TD_YSTATS=1 only).
    private func logYRange(_ pb: CVPixelBuffer) {
        let now = nowNs()
        guard now - lastYStats > 2_000_000_000 else { return }
        lastYStats = now
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), h = CVPixelBufferGetHeight(pb), w = CVPixelBufferGetWidth(pb)
        var lo = 255, hi = 0
        for r in stride(from: h / 8, to: h * 7 / 8, by: 2) { for c in stride(from: w / 8, to: w * 7 / 8, by: 1) { let v = Int(y[r * bpr + c]); lo = min(lo, v); hi = max(hi, v) } }
        Log.info("encoder input Y range: \(lo)...\(hi)")
    }

    func encode(_ pb: CVPixelBuffer, displayNs: Int64, callbackNs: Int64, keyframe: Bool, refinement: Bool) {
        guard let s = session else { return }
        if Encoder.yStats { logYRange(pb) }
        if !loggedBuffer {
            loggedBuffer = true
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            Log.info("encoder input: \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fmt=\(String(format: "%08x", fmt)) bpr=\(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)) iosurface=\(CVPixelBufferGetIOSurface(pb) != nil)")
        }
        let props: CFDictionary? = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        let codec = self.codec
        let submitted = nowNs()
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            let done = nowNs()
            self?.encodeDuration.add(Double(done - submitted) / 1e6)
            if Encoder.verify, let sb { self?.verifyDecode(sb) }
            guard status == noErr, let sb, let data = Encoder.annexB(sb, codec: codec) else {
                Log.info("encoder: frame failed (\(status))")
                self?.onOutput?(EncodedFrame(annexB: Data(), keyframe: false, refinement: refinement, displayNs: displayNs, callbackNs: callbackNs, encodedNs: done))
                return
            }
            self?.onOutput?(EncodedFrame(annexB: data.0, keyframe: data.1, refinement: refinement, displayNs: displayNs, callbackNs: callbackNs, encodedNs: done))
        }
    }

    func invalidate() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }

    deinit { invalidate() }

    // MARK: debug: decode our own keyframes on the Mac and report the Y range (TD_VERIFY=1)

    private static let verify = ProcessInfo.processInfo.environment["TD_VERIFY"] == "1"
    private var verifier: VTDecompressionSession?
    private var lastVerify: Int64 = 0

    func verifyDecode(_ sb: CMSampleBuffer) {
        guard Encoder.verify, let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        let sample = nowNs() - lastVerify > 2_000_000_000
        if sample { lastVerify = nowNs() }
        if verifier == nil {
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary
            let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil, imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &verifier)
            Log.info("verify: decoder session \(st)")
        }
        guard let v = verifier else { return }
        let st = VTDecompressionSessionDecodeFrame(v, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let pb = image else { Log.info("verify decode failed \(status)"); return }
            guard sample else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), h = CVPixelBufferGetHeight(pb), w = CVPixelBufferGetWidth(pb)
            var lo = 255, hi = 0
            for r in stride(from: h / 8, to: h * 7 / 8, by: 2) { for c in w / 8..<(w * 7 / 8) { let val = Int(y[r * bpr + c]); lo = min(lo, val); hi = max(hi, val) } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            Log.info("verify: Mac-decoded Y range \(lo)...\(hi)")
        }
        if st != noErr { Log.info("verify: decode call \(st)") }
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]
    private static var loggedFormat = false

    /// AVCC/HVCC sample → Annex B, with parameter sets prepended on keyframes.
    static func annexB(_ sb: CMSampleBuffer, codec: CodecChoice) -> (Data, Bool)? {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var keyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        var out = Data()
        out.reserveCapacity(CMBlockBufferGetDataLength(bb) + 256)
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sb), !loggedFormat {
            loggedFormat = true
            let ext = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
            Log.info("encoder output: fullRange=\(ext[kCMFormatDescriptionExtension_FullRangeVideo as String] ?? "unset") primaries=\(ext[kCMFormatDescriptionExtension_ColorPrimaries as String] ?? "-") transfer=\(ext[kCMFormatDescriptionExtension_TransferFunction as String] ?? "-") matrix=\(ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] ?? "-")")
        }
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            var i = 0
            repeat {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let r = codec == .hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                guard r == noErr, let ptr else { break }
                out.append(contentsOf: startCode)
                out.append(ptr, count: size)
                i += 1
            } while i < count
        }
        var length = 0, contiguous = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &length, dataPointerOut: &base) == noErr, base != nil else { return nil }
        if contiguous < length {
            var copy = Data(count: length)
            copy.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            return copy.withUnsafeBytes { appendNALs(UnsafeRawPointer($0.baseAddress!), length, into: &out) } ? (out, keyframe) : nil
        }
        return appendNALs(UnsafeRawPointer(base!), length, into: &out) ? (out, keyframe) : nil
    }

    private static func appendNALs(_ raw: UnsafeRawPointer, _ length: Int, into out: inout Data) -> Bool {
        var off = 0
        while off + 4 <= length {
            let nalLen = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
            off += 4
            guard off + nalLen <= length else { break }
            out.append(contentsOf: startCode)
            out.append(raw.advanced(by: off).assumingMemoryBound(to: UInt8.self), count: nalLen)
            off += nalLen
        }
        return true
    }
}
