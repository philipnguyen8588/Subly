import Foundation

/// Hội thoại hỏi đáp về cốt truyện của mục "Hỏi đáp". Chỉ giữ trong RAM, riêng cho từng game, mất khi thoát app.
@MainActor
final class StoryChat: ObservableObject {
    static let shared = StoryChat()

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: String?
        var error: String?
        var backend: BackendKind?
        var ms = 0
    }

    @Published private var byProfile: [String: [Turn]] = [:]
    @Published private(set) var isRunning = false

    private var profile: String { AppSettings.shared.activeProfile.id.uuidString }
    var turns: [Turn] { byProfile[profile] ?? [] }

    func clear() { byProfile[profile] = nil }

    func ask(_ text: String) {
        let question = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(StoryQA.maxQuestion))
        guard !question.isEmpty, !isRunning else { return }
        let profile = profile
        let history = turns.compactMap { t in t.answer.map { StoryQA.Turn(question: t.question, answer: $0) } }
        let turn = Turn(question: question)
        byProfile[profile, default: []].append(turn)
        isRunning = true
        Task {
            defer { isRunning = false }
            guard await SessionCheck.shared.authorizeAction() else {
                update(turn.id, profile) { $0.error = "Không hỏi được lúc này." }
                return
            }
            do {
                let a = try await Self.answer(question, history: history)
                update(turn.id, profile) { $0.answer = a.text; $0.backend = a.backend; $0.ms = a.ms }
            } catch {
                update(turn.id, profile) { $0.error = "Không trả lời được: \(error.localizedDescription)" }
            }
        }
    }

    private func update(_ id: UUID, _ profile: String, _ change: (inout Turn) -> Void) {
        guard let i = byProfile[profile]?.firstIndex(where: { $0.id == id }) else { return }
        change(&byProfile[profile]![i])
    }

    /// Chọn dữ liệu liên quan của game đang chọn rồi hỏi model. Dùng chung cho app và trang web.
    static func answer(_ question: String, history: [StoryQA.Turn]) async throws -> TranslationRouter.StoryAnswer {
        let store = HistoryStore.shared
        let profile = AppSettings.shared.activeProfile.id.uuidString
        let material = StoryQA.gather(question: question, story: store.story, parts: store.storyParts, history: history) {
            store.searchEntries(profile: profile, terms: $0, limit: 300)
        }
        do {
            let a = try await Pipeline.shared.router.askStory(material)
            Log.info("Hỏi đáp [\(a.backend.rawValue)] \(a.ms)ms, gửi \(a.inputChars) ký tự (~\(a.inputChars * 2 / 7) token), "
                     + "trả \(a.text.count) ký tự: \(question.prefix(80))")
            return a
        } catch {
            Log.error("Hỏi đáp lỗi: \(error.localizedDescription)")
            throw error
        }
    }
}
