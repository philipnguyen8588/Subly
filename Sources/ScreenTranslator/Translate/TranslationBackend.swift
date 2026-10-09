import Foundation

struct TranslationPair: Equatable {
    let source: String
    let target: String
}

enum BackendKind: String, Codable {
    case gemini, apple, appleAI, openAI
    /// Câu quá đơn giản: chỉ ghi vào nhật ký, không dịch, không đọc.
    case skipped
    var label: String {
        switch self {
        case .skipped: return "Không dịch"
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI"
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
