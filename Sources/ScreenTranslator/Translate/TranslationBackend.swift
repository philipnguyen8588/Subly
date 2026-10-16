import Foundation

struct TranslationPair: Equatable {
    let source: String
    let target: String
}

enum BackendKind: String, Codable {
    case gemini, apple, appleAI, openAI, anthropic, custom, shared
    /// Câu quá đơn giản: chỉ ghi vào nhật ký, không dịch, không đọc.
    case skipped
    var label: String {
        switch self {
        case .skipped: return "Không dịch"
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI"
        case .anthropic: return "Claude"
        case .custom: return "API tuỳ chỉnh"
        case .shared: return "AI share"
        case .apple: return "Apple"
        case .appleAI: return "Apple Intelligence"
        }
    }
    static func label(raw: String) -> String { BackendKind(rawValue: raw)?.label ?? raw }
}

protocol TranslationBackend: AnyObject {
    var kind: BackendKind { get }
    func translate(_ text: String, context: [TranslationPair]) async throws -> String
}

/// Nhà cung cấp AI qua mạng dùng API kiểu chat (OpenAI, Anthropic, API tuỳ chỉnh, Gemini khi đi qua AI share): chung một giao diện để router
/// không phải viết riêng cho từng hãng.
protocol CloudChatBackend: AnyObject {
    /// Đã đủ key / địa chỉ / model để gọi.
    var isReady: Bool { get }
    /// Model mặc định (Cài đặt → AI). `model:` ở các hàm dưới là model riêng của từng việc (Cài đặt → Dịch); nil = dùng mặc định.
    var model: String { get }
    func translate(_ text: String, context: [TranslationPair], model: String?) async throws -> String
    func analyze(lines: [String], timeout: TimeInterval, model: String?) async throws -> GeminiBackend.AnalysisResult
    func complete(system: String, user: String, json: Bool, maxTokens: Int, timeout: TimeInterval, model: String?) async throws -> String
}
