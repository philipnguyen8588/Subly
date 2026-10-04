import Foundation
import AppKit
import Combine

/// Dịch thủ công: chụp vùng manual → OCR accurate → dịch + tóm tắt → lưu.
@MainActor
final class ScreenAnalyzer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var progress: String = ""

    private let ocr = VisionOCR()
    private let router: TranslationRouter
    private let speaker: Speaker
    private let settings = AppSettings.shared

    init(router: TranslationRouter, speaker: Speaker) {
        self.router = router
        self.speaker = speaker
    }

    /// `present`: mở ảnh đã dịch ngay trên cửa sổ app (bấm từ điện thoại thì không, vì người bấm xem trên điện thoại).
    private static func recognizeBlocks(_ ocr: VisionOCR, _ img: CGImage, timeout: Double) async -> [VisionOCR.Block]? {
        await withCheckedContinuation { cont in
            let lock = NSLock()
            var done = false
            func finish(_ r: [VisionOCR.Block]?) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: r)
            }
            Task.detached(priority: .userInitiated) { finish(ocr.recognizeBlocks(img)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(5, timeout)) { finish(nil) }
        }
    }

    func analyze(regions: [Region], present: Bool = true) async -> ScreenAnalysis? {
        guard !isRunning else { return nil }
        guard !regions.isEmpty else { lastError = "Chưa có vùng dịch thủ công"; return nil }
        if regions.contains(where: { !$0.embedded }), !CGPreflightScreenCaptureAccess() { lastError = "Chưa có quyền Ghi màn hình"; return nil }
        isRunning = true
        lastError = nil
        defer { isRunning = false; progress = "" }
        let t0 = Date()

        // 1. Chụp + OCR từng vùng
        var lines: [String] = []
        var placed: (image: CGImage, blocks: [VisionOCR.Block], offset: Int)?   // vùng PS5 nhúng: giữ vị trí từng khối
        for r in regions {
            progress = "Đang chụp \(r.name)…"
            do {
                let scale = min(2.0, 3000.0 / max(1, r.width))
                let img = try await ScreenshotService.capture(region: r, scale: scale)
                progress = "Đang nhận dạng chữ…"
                // Vision có lúc treo hẳn bên trong (không bao giờ trả về): chờ tối đa `analyzeTimeout` giây rồi báo lỗi,
                // để nút Dịch màn hình không kẹt ở "Đang nhận dạng chữ…" mãi.
                guard let blocks = await Self.recognizeBlocks(ocr, img, timeout: settings.analyzeTimeout) else {
                    lastError = "Bộ nhận dạng chữ của macOS bị treo. Thoát hẳn app (⌘Q) rồi mở lại."
                    Log.error("Analyze OCR[\(r.name)] quá \(Int(settings.analyzeTimeout)) s không xong → Vision treo")
                    return nil
                }
                Log.info("Analyze OCR[\(r.name)] \(blocks.count) khối chữ")
                if placed == nil { placed = (img, blocks, lines.count) }
                lines += blocks.map(\.text)
            } catch {
                lastError = error.localizedDescription
                Log.error("Analyze capture failed: \(error.localizedDescription)")
            }
        }
        guard !lines.isEmpty else {
            lastError = "Không thấy chữ nào trong vùng"
            return nil
        }
        if lines.count > 80 { lines = Array(lines.prefix(80)) }

        // 2. Dịch + tóm tắt
        progress = "Đang dịch \(lines.count) dòng…"
        guard let out = await router.analyze(lines: lines) else {
            lastError = "Không dịch được (\(router.state.label))"
            return nil
        }
        let pairs = zip(lines, out.translations).enumerated().map { AnalysisLine(id: $0.offset + 1, source: $0.element.0, target: $0.element.1) }
        let summary = out.summary.isEmpty ? "(Apple Translation không tóm tắt; xem bản dịch từng dòng)" : out.summary
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        // Vị trí từng khối chữ trên ảnh của vùng đầu tiên, để vẽ bản dịch đè đúng chỗ.
        let items: [ShotItem] = (placed?.blocks ?? []).enumerated().compactMap { i, b in
            let k = (placed?.offset ?? 0) + i
            guard k < out.translations.count, !out.translations[k].isEmpty, k < lines.count else { return nil }
            return ShotItem(id: i, x: b.box.minX, y: b.box.minY, w: b.box.width, h: b.box.height, lines: b.lines, source: b.text, target: out.translations[k])
        }
        let a = HistoryStore.shared.addAnalysis(region: regions.map(\.name).joined(separator: ", "), image: placed?.image, items: items,
                                                summary: summary, lines: pairs, backend: out.backend, ms: ms,
                                                profile: settings.activeProfile.id.uuidString)
        if present, a.hasImage { ShotViewer.shared.show(a.id) }
        Log.info("Analyze done [\(out.backend.rawValue)] \(ms)ms: \(summary.prefix(80))")
        if settings.analyzeSpeakSummary, settings.voiceOn, !out.summary.isEmpty {
            speaker.speak(out.summary)
        }
        return a
    }

}
