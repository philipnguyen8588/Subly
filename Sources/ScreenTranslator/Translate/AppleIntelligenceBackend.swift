import Foundation
import FoundationModels

/// Dịch bằng model ngôn ngữ trên máy của Apple Intelligence (FoundationModels, macOS 26+).
/// Miễn phí, offline, hiểu ngữ cảnh + glossary + tên nhân vật; chậm hơn Apple Translation (~0,4–1,3 s/câu trên M4).
final class AppleIntelligenceBackend: TranslationBackend {
    enum Status: Equatable {
        case available
        case notEnabled          // chưa bật Apple Intelligence trong System Settings
        case modelNotReady       // đang tải model
        case unsupported(String) // máy / hệ điều hành không hỗ trợ

        var label: String {
            switch self {
            case .available: return "sẵn sàng"
            case .notEnabled: return "chưa bật Apple Intelligence"
            case .modelNotReady: return "đang tải model"
            case .unsupported(let s): return s
            }
        }
    }

    enum AIError: LocalizedError {
        case unavailable(String), timeout, empty
        var errorDescription: String? {
            switch self {
            case .unavailable(let s): return "Apple Intelligence: \(s)"
            case .timeout: return "Apple Intelligence quá thời gian"
            case .empty: return "Apple Intelligence trả về rỗng"
            }
        }
    }

    let kind: BackendKind = .appleAI
    var timeout: TimeInterval = 3
    /// Router cung cấp system prompt (ngôn ngữ đích, glossary, tên nhân vật) dùng chung với Gemini.
    var instructions: () -> String = { "Translate the English subtitle into natural Vietnamese. Output only the translation." }
    var summaryInstructions: () -> String = { "" }

    var status: Status {
        guard #available(macOS 26.0, *) else { return .unsupported("cần macOS 26 trở lên") }
        switch Self.model.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable(.deviceNotEligible): return .unsupported("máy không hỗ trợ Apple Intelligence")
        case .unavailable: return .unsupported("không khả dụng")
        }
    }
    var isAvailable: Bool { status == .available }

    @available(macOS 26.0, *)
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// Nạp sẵn model để câu đầu tiên không bị trễ.
    func prewarm() {
        guard #available(macOS 26.0, *), isAvailable else { return }
        LanguageModelSession(model: Self.model, instructions: instructions()).prewarm()
    }

    func translate(_ text: String, context: [TranslationPair]) async throws -> String {
        var prompt = ""
        let ctx = context.suffix(3)
        if !ctx.isEmpty {
            prompt += "Previous lines (context only, do not repeat them):\n"
            for p in ctx { prompt += "EN: \(p.source)\nTranslated: \(p.target)\n" }
            prompt += "\nTranslate this new line:\n"
        }
        prompt += text
        let out = try await respond(system: instructions(), prompt: prompt, timeout: timeout)
        // Model nhỏ đôi khi lặp lại nhãn → cắt.
        var cleaned = TextUtils.normalize(out)
        for prefix in ["Translated:", "Translation:", "VI:"] where cleaned.hasPrefix(prefix) {
            cleaned = TextUtils.normalize(String(cleaned.dropFirst(prefix.count)))
        }
        if cleaned.count >= 2, let f = cleaned.first, let l = cleaned.last, "\"“”".contains(f), "\"“”".contains(l),
           !(text.hasPrefix("\"") || text.hasPrefix("“")) {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        guard !cleaned.isEmpty else { throw AIError.empty }
        return cleaned
    }

    /// Tóm tắt màn hình từ các dòng OCR (cắt bớt cho vừa cửa sổ ngữ cảnh 4096 token).
    func summarize(lines: [String], timeout: TimeInterval) async throws -> String {
        var body = ""
        for (i, l) in lines.enumerated() {
            let row = "\(i + 1). \(l)\n"
            if body.count + row.count > 2400 { break }
            body += row
        }
        return TextUtils.normalize(try await respond(system: summaryInstructions(), prompt: body, timeout: timeout))
    }

    /// Dịch nhiều dòng (dùng khi không có Gemini lẫn gói Apple Translation): theo lô đánh số.
    func translateBatch(_ lines: [String], timeout: TimeInterval) async throws -> [String] {
        var out = [String](repeating: "", count: lines.count)
        let sys = instructions() + "\nThe user sends numbered lines. Reply with the same numbers, one translated line per number, format `N. translation`."
        var start = 0
        while start < lines.count {
            let end = min(start + 12, lines.count)
            let prompt = (start..<end).map { "\($0 + 1). \(lines[$0])" }.joined(separator: "\n")
            let raw = try await respond(system: sys, prompt: prompt, timeout: timeout)
            for row in raw.split(separator: "\n") {
                let t = row.trimmingCharacters(in: .whitespaces)
                let digits = t.prefix { $0.isNumber }
                guard let n = Int(digits), n >= 1, n <= lines.count else { continue }
                let rest = t.dropFirst(digits.count).drop { $0 == "." || $0 == ")" || $0 == " " }
                out[n - 1] = TextUtils.normalize(String(rest))
            }
            start = end
        }
        return out
    }

    private func respond(system: String, prompt: String, timeout: TimeInterval) async throws -> String {
        guard #available(macOS 26.0, *) else { throw AIError.unavailable("cần macOS 26") }
        guard isAvailable else { throw AIError.unavailable(status.label) }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(model: Self.model, instructions: system)
                let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
                return r.content
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AIError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}
