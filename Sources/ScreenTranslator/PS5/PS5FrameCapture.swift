import Foundation
import CoreVideo
import CoreGraphics
import CoreImage

/// Nguồn khung hình cho một vùng: màn hình/cửa sổ (RegionCapture) hoặc luồng PS5 nhúng (PS5FrameCapture).
protocol FrameCapture: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// Nguồn bị hệ thống dừng ngoài ý muốn (chỉ luồng chụp màn hình mới gọi).
    var onStopped: ((Error) -> Void)? { get set }
    func start() async throws
    func stop() async
}

extension RegionCapture: FrameCapture {}

/// Cắt vùng (toạ độ chuẩn hoá 0...1) từ khung hình PS5 mới nhất, `fps` lần mỗi giây.
final class PS5FrameCapture: FrameCapture {
    let region: Region
    let fps: Int
    /// So với ảnh gốc của luồng: < 1 thu nhỏ (OCR nhanh hơn), > 1 phóng to (đọc chữ nhỏ).
    let scale: Double
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStopped: ((Error) -> Void)?
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var lastIndex = -1

    init(region: Region, fps: Int, scale: Double = 1) {
        self.region = region
        self.fps = max(1, fps)
        self.scale = scale
        queue = DispatchQueue(label: "ps5.capture.\(region.id.uuidString)", qos: .userInitiated, autoreleaseFrequency: .workItem)
    }

    func start() async throws {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        Log.info("Capture started '\(region.name)' PS5 nhúng \(region.rect) @\(fps)fps ×\(scale)")
    }

    func stop() async {
        timer?.cancel(); timer = nil
    }

    private func tick() {
        guard let (pb, idx) = PS5Stream.shared.latestFrame(), idx != lastIndex else { return }
        lastIndex = idx
        guard let c = Self.crop(pb, normalized: region.rect) else { return }
        onFrame?(abs(scale - 1) < 0.01 ? c : Self.resize(c, scale: scale) ?? c)
    }

    /// Cắt vùng chuẩn hoá khỏi khung BGRA thành một CVPixelBuffer BGRA mới.
    static func crop(_ src: CVPixelBuffer, normalized r: CGRect) -> CVPixelBuffer? {
        let W = CVPixelBufferGetWidth(src), H = CVPixelBufferGetHeight(src)
        let x = max(0, min(W - 2, Int((r.minX * CGFloat(W)).rounded())))
        let y = max(0, min(H - 2, Int((r.minY * CGFloat(H)).rounded())))
        let w = max(2, min(W - x, Int((r.width * CGFloat(W)).rounded())))
        let h = max(2, min(H - y, Int((r.height * CGFloat(H)).rounded())))
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let out else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []); CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        guard let sb = CVPixelBufferGetBaseAddress(src), let db = CVPixelBufferGetBaseAddress(out) else { return nil }
        let sStride = CVPixelBufferGetBytesPerRow(src), dStride = CVPixelBufferGetBytesPerRow(out)
        for row in 0..<h {
            memcpy(db + row * dStride, sb + (y + row) * sStride + x * 4, w * 4)
        }
        return out
    }

    /// Đổi cỡ khung BGRA (Lanczos) thành một CVPixelBuffer BGRA mới.
    static func resize(_ src: CVPixelBuffer, scale: Double) -> CVPixelBuffer? {
        let w = max(2, Int((Double(CVPixelBufferGetWidth(src)) * scale).rounded()))
        let h = max(2, Int((Double(CVPixelBufferGetHeight(src)) * scale).rounded()))
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let out else { return nil }
        let img = lanczos(CIImage(cvPixelBuffer: src), scale)
        ci.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
        return out
    }

    private static func lanczos(_ img: CIImage, _ s: Double) -> CIImage {
        img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
    }

    private static let ci = CIContext()
    /// Ảnh tĩnh của vùng (thumbnail, phân tích màn hình). nil nếu chưa có khung hình.
    /// `scale`: phóng to / thu nhỏ so với ảnh gốc (bỏ qua khi có `maxWidth`).
    static func image(for region: Region, maxWidth: CGFloat? = nil, scale: Double = 1) -> CGImage? {
        guard let (pb, _) = PS5Stream.shared.latestFrame(), let c = crop(pb, normalized: region.rect) else { return nil }
        var img = CIImage(cvPixelBuffer: c)
        if let maxWidth, img.extent.width > maxWidth {
            let s = maxWidth / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        } else if maxWidth == nil, abs(scale - 1) >= 0.01 {
            img = lanczos(img, scale)
        }
        return ci.createCGImage(img, from: img.extent)
    }
}
