import Foundation

/// Tóm tắt các câu phụ đề người dùng chọn trong nhật ký, rồi lưu vào mục "Tóm tắt" của game đang chọn.
@MainActor
final class StorySummarizer: ObservableObject {
    static let shared = StorySummarizer()

    /// Số câu đang được tóm tắt (0 = rảnh).
    @Published private(set) var runningCount = 0
    @Published private(set) var lastError: String?
    /// Id bản tóm tắt vừa lưu, để giao diện chuyển sang mục Tóm tắt.
    @Published private(set) var lastSavedID: Int64?

    var isRunning: Bool { runningCount > 0 }

    func dismissError() { lastError = nil }

    func summarize(_ entries: [TranslationEntry]) {
        guard !isRunning, !entries.isEmpty else { return }
        let sorted = entries.sorted { $0.id < $1.id }
        let profile = AppSettings.shared.activeProfile.id.uuidString
        runningCount = sorted.count
        lastError = nil
        Task {
            defer { runningCount = 0 }
            do {
                let r = try await Pipeline.shared.router.summarizeStory(lines: sorted.map(\.source))
                let skipped = BackendKind.skipped.rawValue
                let lines = sorted.enumerated().map { i, e in
                    AnalysisLine(id: i, source: e.source, target: e.backend == skipped ? "" : e.translated)
                }
                let title = r.title.isEmpty ? "Đoạn \(sorted.count) câu lúc \(sorted[0].timestamp.hm)" : r.title
                let saved = HistoryStore.shared.addSummary(title: title, summary: r.summary, lines: lines,
                                                           from: sorted.first!.timestamp, to: sorted.last!.timestamp,
                                                           backend: r.backend, ms: r.ms, profile: profile)
                Log.info("Tóm tắt [\(r.backend.rawValue)] \(sorted.count) câu, \(r.ms)ms: \(title)")
                lastSavedID = saved.id
            } catch {
                lastError = "Không tóm tắt được: \(error.localizedDescription)"
                Log.error("Tóm tắt \(sorted.count) câu lỗi: \(error.localizedDescription)")
            }
        }
    }
}
