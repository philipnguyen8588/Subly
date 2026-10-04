import Foundation
import CoreVideo
import CoreGraphics

/// Nơi phát khung hình để hiển thị trong app (PS5 nhúng).
protocol FrameBroadcaster: AnyObject {
    func addDisplaySink(_ f: @escaping (CVPixelBuffer) -> Void) -> UUID
    func removeDisplaySink(_ id: UUID)
}

extension PS5Stream: FrameBroadcaster {}

/// Ảnh chụp vùng "màn hình game" của app ngoài, hiện trong tab Màn hình để nhìn và đặt khung phụ đề.
/// KHÔNG chụp liên tục: đo thực tế một luồng chụp toàn vùng chạy nền làm WindowServer tăng từ ~10 % lên ~40 % CPU
/// (kể cả ở 3 khung/giây). Chỉ chụp một tấm khi mở tab, khi đổi vùng, hoặc khi người dùng bấm "Chụp màn hình game".
/// Việc dịch phụ đề dùng luồng chụp riêng cho khung phụ đề (nhỏ, 4 fps) nên không phụ thuộc ảnh này.
@MainActor
final class ExternalMirror: ObservableObject {
    static let shared = ExternalMirror()

    @Published private(set) var image: CGImage?
    @Published private(set) var capturing = false
    @Published private(set) var error: String?
    @Published private(set) var capturedAt: Date?
    private var area: Region?

    /// Chụp nếu chưa có ảnh của vùng này (mở tab lần đầu, đổi game, vẽ lại vùng).
    func ensure(_ area: Region?) {
        guard let area else { image = nil; self.area = nil; error = nil; return }
        if area != self.area || image == nil { capture(area) }
    }

    /// Chụp lại ngay một tấm.
    func capture(_ area: Region) {
        guard !capturing else { return }
        self.area = area
        capturing = true
        Task {
            do {
                // Đủ nét để đọc và đặt khung; Dịch màn hình tự chụp tấm nét hơn cho OCR.
                let scale = min(2.0, 1800.0 / max(200, area.width))
                let img = try await ScreenshotService.capture(region: area, scale: scale)
                image = img
                capturedAt = Date()
                error = nil
            } catch {
                self.error = error.localizedDescription
                Log.warn("Chụp màn hình game lỗi: \(error.localizedDescription)")
            }
            capturing = false
        }
    }
}
