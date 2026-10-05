import Foundation
import ScreenCaptureKit
import CoreMedia

struct CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    let displayNs: Int64   // when macOS composited the frame
    let callbackNs: Int64  // when we received it
    let dirtyFraction: Double
}

/// ScreenCaptureKit stream of the virtual display, delivering IOSurface-backed NV12 at the
/// tablet's native resolution (the GPU scales "more space" modes down; the tablet never scales).
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CapturedFrame) -> Void)?
    var onIdle: (() -> Void)?
    var onStop: ((Error) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private var width = 0, height = 0
    /// Full-range NV12 unless TD_VIDEORANGE=1 (fallback if the tablet mishandles the range flag).
    static let fullRange = ProcessInfo.processInfo.environment["TD_VIDEORANGE"] != "1"

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        self.width = width
        self.height = height
        var scDisplay: SCDisplay?
        for _ in 0..<40 {  // the new virtual display takes a moment to show up
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let scDisplay else { throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "virtual display not visible to ScreenCaptureKit"]) }

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = Capture.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 4
        cfg.showsCursor = true
        cfg.capturesAudio = false
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        Log.info("capture started on display \(displayID): \(width)×\(height) at up to \(fps) fps")
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        s.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let cb = nowNs()
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle { onIdle?(); return }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let display = (info[.displayTime] as? UInt64).map(machToNs) ?? cb
        var dirty = 1.0
        if let rects = info[.dirtyRects] as? [NSDictionary] {
            let scale = info[.scaleFactor] as? Double ?? 1
            let area = rects.compactMap { CGRect(dictionaryRepresentation: $0) }.reduce(0.0) { $0 + Double($1.width * $1.height) }
            dirty = min(1, area * scale * scale / Double(width * height))
        }
        onFrame?(CapturedFrame(pixelBuffer: pb, displayNs: display, callbackNs: cb, dirtyFraction: dirty))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture stopped: \(error.localizedDescription)")
        onStop?(error)
    }
}
