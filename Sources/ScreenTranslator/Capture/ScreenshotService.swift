import Foundation
import ScreenCaptureKit
import CoreGraphics

/// Chụp một lần một vùng màn hình (thumbnail, phân tích thủ công). Loại cửa sổ của chính app.
enum ScreenshotService {
    private static var cache: (content: SCShareableContent, at: Date)?
    private static let lock = NSLock()

    static func shareableContent() async throws -> SCShareableContent {
        lock.lock()
        if let c = cache, Date().timeIntervalSince(c.at) < 5 { lock.unlock(); return c.content }
        lock.unlock()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        lock.lock(); cache = (content, Date()); lock.unlock()
        return content
    }

    struct Target {
        let filter: SCContentFilter
        let local: CGRect
        let display: SCDisplay
        var windowID: CGWindowID? = nil
        var windowSize: CGSize = .zero
    }

    static func target(for region: Region) async throws -> Target {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
                ?? content.displays.first else {
            throw NSError(domain: "Screenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy màn hình"])
        }
        if region.followsWindow, let bid = region.appBundleID, region.winOffsetX != nil {
            // Bám cửa sổ: chụp thẳng cửa sổ app, vùng tính theo góc trên-trái cửa sổ.
            let wins = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bid && $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 60
            }
            let win = wins.first { $0.windowID == region.windowID }
                ?? wins.filter(\.isOnScreen).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                ?? wins.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let win else {
                throw NSError(domain: "Screenshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Không thấy cửa sổ của \(region.appName ?? bid)"])
            }
            // Kích thước cửa sổ lấy trực tiếp từ CoreGraphics (danh sách SCShareableContent có thể là bản cache).
            let size = WindowFinder.bounds(of: win.windowID)?.size ?? win.frame.size
            let local = (region.localRect(inWindowOfSize: size) ?? .zero)
                .intersection(CGRect(origin: .zero, size: size))
            guard local.width >= 8, local.height >= 8 else {
                throw NSError(domain: "Screenshot", code: 4, userInfo: [NSLocalizedDescriptionKey: "Vùng nằm ngoài cửa sổ \(region.appName ?? bid) (cửa sổ đã đổi kích thước?) → Chọn lại"])
            }
            return Target(filter: SCContentFilter(desktopIndependentWindow: win), local: local, display: display,
                          windowID: win.windowID, windowSize: size)
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let bounds = CGDisplayBounds(display.displayID)
        let local = CGRect(x: region.rect.minX - bounds.minX, y: region.rect.minY - bounds.minY,
                           width: region.rect.width, height: region.rect.height)
            .intersection(CGRect(origin: .zero, size: bounds.size))
        guard local.width >= 8, local.height >= 8 else {
            throw NSError(domain: "Screenshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Vùng quá nhỏ hoặc nằm ngoài màn hình"])
        }
        return Target(filter: filter, local: local, display: display)
    }

    /// `scale` = pixel/point. Dùng ~0.3 cho thumbnail, 2 cho OCR.
    static func capture(region: Region, scale: Double) async throws -> CGImage {
        if region.embedded {
            guard let img = PS5FrameCapture.image(for: region, maxWidth: scale < 1 ? 640 : nil) else {
                throw NSError(domain: "Screenshot", code: 5, userInfo: [NSLocalizedDescriptionKey: "Chưa có hình từ PS5 (chưa kết nối)"])
            }
            return img
        }
        let t = try await target(for: region)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = t.local
        cfg.width = max(8, Int(t.local.width * scale))
        cfg.height = max(8, Int(t.local.height * scale))
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: t.filter, configuration: cfg)
    }
}
