import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit

/// Một SCStream cho đúng một vùng màn hình. Frame chỉ được giao khi status == .complete.
final class RegionCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let region: Region
    let fps: Int
    let scale: Double
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue: DispatchQueue
    private var windowID: CGWindowID?
    private var windowSize: CGSize = .zero
    private var resizeTimer: DispatchSourceTimer?

    init(region: Region, fps: Int, scale: Double) {
        self.region = region
        self.fps = max(1, fps)
        self.scale = scale
        self.queue = DispatchQueue(label: "capture.\(region.id.uuidString)", qos: .userInitiated, autoreleaseFrequency: .workItem)
    }

    func start() async throws {
        let t = try await ScreenshotService.target(for: region)
        let filter = t.filter
        let local = t.local

        let cfg = makeConfig(local)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        windowID = t.windowID
        windowSize = t.windowSize
        if t.windowID != nil { startResizeWatch() }
        Log.info("Capture started '\(region.name)' \(region.followsWindow ? "window(\(region.appName ?? "?"))" : "display") local=\(local) \(cfg.width)x\(cfg.height) @\(fps)fps")
    }

    private func makeConfig(_ local: CGRect) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = local
        cfg.width = max(16, Int(local.width * scale))
        cfg.height = max(16, Int(local.height * scale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 5      // worker có thể giữ cùng lúc 3 khung (đang OCR, đang chờ, đang so) → 3 là sát nút, dễ rớt khung
        cfg.showsCursor = false
        cfg.colorSpaceName = CGColorSpace.sRGB
        return cfg
    }

    /// Vùng bám cửa sổ: mỗi 0,7 s xem cửa sổ có đổi kích thước không; có thì co giãn vùng chụp theo tỉ lệ.
    /// (Di chuyển cửa sổ không cần xử lý vì stream chụp thẳng cửa sổ.)
    private func startResizeWatch() {
        resizeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.7, repeating: 0.7)
        t.setEventHandler { [weak self] in self?.checkResize() }
        t.resume()
        resizeTimer = t
    }

    private func checkResize() {
        guard let s = stream, let wid = windowID, let b = WindowFinder.bounds(of: wid) else { return }
        guard abs(b.width - windowSize.width) > 1 || abs(b.height - windowSize.height) > 1 else { return }
        windowSize = b.size
        guard let l = region.localRect(inWindowOfSize: b.size) else { return }
        let local = l.intersection(CGRect(origin: .zero, size: b.size))
        guard local.width >= 8, local.height >= 8 else { return }
        let cfg = makeConfig(local)
        Log.info("Cửa sổ '\(region.appName ?? "?")' đổi cỡ \(Int(b.width))×\(Int(b.height)) → vùng '\(region.name)' = \(local.integral)")
        Task {
            do { try await s.updateConfiguration(cfg) }
            catch { Log.error("Cập nhật vùng chụp lỗi: \(error.localizedDescription)") }
        }
    }

    func stop() async {
        resizeTimer?.cancel(); resizeTimer = nil
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        Log.info("Capture stopped '\(region.name)'")
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        onFrame?(pb)
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Capture '\(region.name)' stopped with error: \(error.localizedDescription)")
        guard self.stream === stream else { return }     // đã chủ động dừng hoặc đã mở luồng khác
        self.stream = nil
        resizeTimer?.cancel(); resizeTimer = nil
        onStopped?(error)
    }
}
