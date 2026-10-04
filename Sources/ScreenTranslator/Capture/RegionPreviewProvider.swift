import Foundation
import AppKit
import CoreVideo
import VideoToolbox
import Combine

/// Ảnh thu nhỏ của từng vùng cho card trong cửa sổ chính.
/// Khi pipeline chạy: nhận frame từ RegionWorker (tối đa 1 ảnh/giây/vùng).
/// Khi không chạy và cửa sổ chính đang hiện: tự chụp mỗi 2 giây.
@MainActor
final class RegionPreviewProvider: ObservableObject {
    static let shared = RegionPreviewProvider()

    @Published private(set) var images: [UUID: CGImage] = [:]
    @Published private(set) var lastOCR: [UUID: (ms: Double, text: String, at: Date)] = [:]

    var windowVisible = false { didSet { updateIdleTimer() } }
    var pipelineRunning = false { didSet { updateIdleTimer() } }

    private var idleTimer: Timer?
    private let throttle = Throttle()
    private let maxWidth: CGFloat = 320

    private init() {}

    // MARK: từ RegionWorker (thread bất kỳ)
    nonisolated func pushFrame(regionID: UUID, _ pb: CVPixelBuffer) {
        guard throttle.allow(regionID, interval: 1.0) else { return }
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        guard let full = cg, let small = Self.downscale(full, maxWidth: 320) else { return }
        Task { @MainActor in self.images[regionID] = small }
    }

    nonisolated func reportOCR(regionID: UUID, ms: Double, text: String) {
        Task { @MainActor in self.lastOCR[regionID] = (ms, text, Date()) }
    }

    func remove(_ id: UUID) { images.removeValue(forKey: id); lastOCR.removeValue(forKey: id) }

    // MARK: idle screenshots
    private func updateIdleTimer() {
        idleTimer?.invalidate(); idleTimer = nil
        guard windowVisible, !pipelineRunning else { return }
        idleTick()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.idleTick() }
        }
    }

    func refreshNow() { idleTick() }

    private func idleTick() {
        guard CGPreflightScreenCaptureAccess() else { return }
        for r in AppSettings.shared.regions {
            let scale = r.embedded ? 0.5 : min(1.0, Double(maxWidth) / max(1, r.width))
            Task {
                if let img = try? await ScreenshotService.capture(region: r, scale: scale) {
                    self.images[r.id] = img
                }
            }
        }
    }

    nonisolated static func downscale(_ img: CGImage, maxWidth: CGFloat) -> CGImage? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        guard w > maxWidth else { return img }
        let s = maxWidth / w
        let nw = Int(w * s), nh = max(1, Int(h * s))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }

    /// Cổng chặn theo thời gian, dùng được từ mọi thread.
    final class Throttle {
        private var last: [UUID: Date] = [:]
        private let lock = NSLock()
        func allow(_ id: UUID, interval: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            if let l = last[id], now.timeIntervalSince(l) < interval { return false }
            last[id] = now
            return true
        }
    }
}
