import AppKit
import CryptoKit

/// Kiểm tra cài đặt AI trước khi cho Bắt đầu, riêng cho từng việc (dịch phụ đề, dịch màn hình, tóm tắt & cốt truyện):
/// đã chọn AI, có model, có key và key đã "Kiểm tra" thành công với đúng model đó.
/// AI chạy trên máy (Apple Translation / Apple Intelligence) không cần key, chỉ cần máy dùng được.
@MainActor
enum Readiness {
    struct Issue: Equatable {
        let title: String
        let detail: String
        let tab: SettingsView.Tab
    }

    /// Engine đang dùng cho một việc: tên ngắn, nhà cung cấp qua mạng (nil = chạy trên máy) và model.
    @MainActor struct TaskEngine {
        let task: AITask
        let name: String
        let provider: String?
        var model: String { provider.map { Readiness.model(task, $0) } ?? "" }
        var offline: Bool { provider == nil }
    }

    static let allTasks: [AITask] = [.subtitle, .screen, .summary]

    // MARK: tên

    /// Nhà cung cấp AI qua mạng của engine dịch phụ đề; nil = engine trên máy.
    static func provider(_ e: TranslationEngine) -> String? {
        switch e {
        case .auto: return "gemini"
        case .openAI: return "openAI"
        case .anthropic: return "anthropic"
        case .custom: return "custom"
        case .shared: return "shared"
        case .appleIntelligence, .appleTranslation: return nil
        }
    }

    static func providerName(_ p: String) -> String {
        switch p {
        case "gemini": return "Gemini"
        case "openAI": return "OpenAI"
        case "anthropic": return "Anthropic Claude"
        case "custom": return "API tuỳ chỉnh"
        case "shared": return "AI share"
        default: return p
        }
    }

    static func taskTitle(_ t: AITask) -> String {
        switch t {
        case .subtitle: return "Dịch phụ đề"
        case .screen: return "Dịch màn hình"
        case .summary: return "Tóm tắt & cốt truyện"
        }
    }

    static func taskIcon(_ t: AITask) -> String {
        switch t {
        case .subtitle: return "captions.bubble"
        case .screen: return "doc.text.magnifyingglass"
        case .summary: return "text.book.closed"
        }
    }

    /// Model thật sự dùng cho một việc với nhà cung cấp này (model riêng của việc, không có thì model mặc định ở tab AI).
    static func model(_ task: AITask, _ p: String) -> String {
        let s = AppSettings.shared
        return s.taskModel(task, p) ?? s.defaultModel(p)
    }

    static func engine(_ t: AITask) -> TaskEngine {
        let s = AppSettings.shared
        switch t {
        case .subtitle:
            return TaskEngine(task: t, name: s.engine.shortLabel, provider: provider(s.engine))
        case .screen:
            switch s.effectiveScreenEngine {
            case .appleIntelligence: return TaskEngine(task: t, name: "Apple Intelligence", provider: nil)
            case .appleTranslation: return TaskEngine(task: t, name: "Apple Translation", provider: nil)
            case let e: return TaskEngine(task: t, name: providerName(e.rawValue), provider: e.rawValue)
            }
        case .summary:
            let e = s.effectiveSummaryEngine
            if e == .appleIntelligence { return TaskEngine(task: t, name: "Apple Intelligence", provider: nil) }
            return TaskEngine(task: t, name: providerName(e.rawValue), provider: e.rawValue)
        }
    }

    /// Các key đã lưu của nhà cung cấp (Gemini có thể nhiều key; API tuỳ chỉnh có thể không cần key).
    static func savedKeys(_ p: String) -> [String] {
        let s = AppSettings.shared
        switch p {
        case "gemini": return s.geminiAPIKeys
        case "openAI": return s.openAIKey.isEmpty ? [] : [s.openAIKey]
        case "anthropic": return s.anthropicKey.isEmpty ? [] : [s.anthropicKey]
        case "custom": return [s.customKey]
        case "shared": return s.aiShareToken.isEmpty || s.aiShare == nil ? [] : [s.aiShareToken]
        default: return []
        }
    }

    /// Việc nào đang dùng nhà cung cấp này (để hiện ở tab AI).
    static func tasks(using p: String) -> [AITask] { allTasks.filter { engine($0).provider == p } }

    // MARK: kết quả test

    private static func signature(_ p: String, model: String, key: String) -> String {
        let base = p == "custom" ? AppSettings.shared.customBaseURL.trimmingCharacters(in: .whitespaces) : ""
        let digest = SHA256.hash(data: Data("\(p)|\(model)|\(base)|\(key)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Ghi nhận một lần test: thành công thì nhớ, lỗi thì quên cặp này.
    static func record(_ p: String, model: String, key: String, ok: Bool) {
        let s = AppSettings.shared
        let sig = signature(p, model: model, key: key)
        var list = s.aiVerified.filter { $0 != sig }
        if ok { list.append(sig) }
        if list.count > 64 { list.removeFirst(list.count - 64) }
        if list != s.aiVerified { s.aiVerified = list }
    }

    static func isVerified(_ p: String, model: String, key: String) -> Bool {
        AppSettings.shared.aiVerified.contains(signature(p, model: model, key: key))
    }

    /// Nhà cung cấp đã có ít nhất một key (đang lưu) test thành công với model này.
    static func isVerified(_ p: String, model: String) -> Bool {
        savedKeys(p).contains { isVerified(p, model: model, key: $0) }
    }

    /// Test một cặp nhà cung cấp + model bằng mọi key đã lưu, ghi nhận kết quả từng key.
    static func test(_ p: String, model: String) async -> Result<String, Error> {
        let s = AppSettings.shared
        let keys = savedKeys(p)
        guard !model.isEmpty else { return .failure(err("Chưa chọn model cho \(providerName(p))")) }
        if p != "custom", keys.allSatisfy(\.isEmpty) { return .failure(err("Chưa có key \(providerName(p))")) }
        var last: Result<String, Error> = .failure(err("Chưa có key"))
        var okCount = 0
        for k in keys where p == "custom" || !k.isEmpty {
            let r: Result<String, Error>
            switch p {
            case "gemini": r = await GeminiBackend.test(apiKey: k, model: model)
            case "openAI": r = await OpenAIBackend.test(apiKey: k, model: model)
            case "anthropic": r = await AnthropicBackend.test(apiKey: k, model: model)
            case "shared": r = await AIShareClient.test(model: model)
            default: r = await OpenAIBackend.test(apiKey: k, model: model,
                                                  baseURL: OpenAIBackend.normalize(baseURL: s.customBaseURL), requiresKey: false)
            }
            if case .success = r { okCount += 1 }
            record(p, model: model, key: k, ok: (try? r.get()) != nil)
            last = r
        }
        if okCount > 0, keys.count > 1 { return .success("\(okCount)/\(keys.count) key dùng được") }
        return last
    }

    /// Test một việc (nút "Kiểm tra" của khối đó).
    static func test(_ t: AITask) async -> Result<String, Error> {
        let e = engine(t)
        guard let p = e.provider else { return .success("Chạy trên máy, không cần key") }
        return await test(p, model: e.model)
    }

    /// Test mọi việc đang dùng AI qua mạng mà chưa kiểm tra (mỗi cặp nhà cung cấp + model một lần).
    /// Trả về lỗi đầu tiên (nil = tất cả OK).
    static func testAll() async -> String? {
        var done = Set<String>()
        var firstError: String?
        for t in allTasks {
            let e = engine(t)
            guard let p = e.provider, !done.contains("\(p)|\(e.model)"), !isVerified(p, model: e.model) else { continue }
            done.insert("\(p)|\(e.model)")
            if case .failure(let er) = await test(p, model: e.model), firstError == nil {
                firstError = "\(taskTitle(t)): \(er.localizedDescription)"
            }
        }
        return firstError
    }

    private static func err(_ m: String) -> Error { NSError(domain: "Readiness", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }

    // MARK: kiểm tra

    /// Việc còn thiếu của một việc (nil = sẵn sàng). Tiêu đề ngắn để hiện trong nhãn trạng thái.
    static func issue(_ t: AITask) -> Issue? {
        let s = AppSettings.shared
        let pipeline = Pipeline.shared
        let e = engine(t)
        let what = taskTitle(t)
        guard let p = e.provider else {
            if e.name == "Apple Translation", pipeline.apple.installed == false {
                return Issue(title: "Chưa cài gói ngôn ngữ",
                             detail: "\(what): tải gói Anh → \(s.target.name) trong Cài đặt → Apple (offline), hoặc chọn AI khác.", tab: .apple)
            }
            if e.name == "Apple Intelligence", !pipeline.router.ai.isAvailable {
                return Issue(title: "Apple Intelligence chưa bật",
                             detail: "\(what): \(pipeline.router.ai.status.label). Bật Apple Intelligence trong System Settings, hoặc chọn AI khác.", tab: .apple)
            }
            return nil
        }
        let name = providerName(p)
        if p == "shared" {
            guard let info = s.aiShare, !s.aiShareToken.isEmpty else {
                return Issue(title: "Chưa nhập AI share", detail: "\(what): dán token AI share trong Cài đặt → AI, hoặc chọn AI khác.", tab: .ai)
            }
            if info.revoked {
                return Issue(title: "AI share bị thu hồi", detail: "\(what): token AI share không còn dùng được. Xin token mới hoặc chọn AI khác.", tab: .ai)
            }
        } else if p == "custom" {
            if s.customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                return Issue(title: "Chưa có địa chỉ API", detail: "\(what): nhập địa chỉ máy chủ API tuỳ chỉnh trong Cài đặt → AI.", tab: .ai)
            }
        } else if savedKeys(p).isEmpty {
            return Issue(title: "Chưa có key \(name)", detail: "\(what): nhập và lưu key \(name) trong Cài đặt → AI.", tab: .ai)
        }
        if e.model.isEmpty {
            return Issue(title: "Chưa chọn model", detail: "\(what): chọn model \(name) trong Cài đặt → Dịch.", tab: .translate)
        }
        if !isVerified(p, model: e.model) {
            return Issue(title: "Chưa kiểm tra",
                         detail: "\(what): bấm “Kiểm tra” để thử \(name) · \(e.model). Đổi key hoặc model thì cần kiểm tra lại.", tab: .translate)
        }
        return nil
    }

    /// Việc bắt buộc phải sẵn sàng trước khi Bắt đầu. Tóm tắt & cốt truyện chỉ bắt buộc khi bật tự viết cốt truyện.
    static func isRequired(_ t: AITask) -> Bool { t != .summary || AppSettings.shared.storyOn }

    /// Danh sách việc còn thiếu (chỉ các việc bắt buộc); rỗng = được bắt đầu.
    static func check() -> [Issue] {
        if AppSettings.shared.forceReady { return [] }
        return allTasks.filter(isRequired).compactMap(issue)
    }

    /// Báo việc còn thiếu, có nút mở đúng trang Cài đặt.
    static func alert(_ issues: [Issue]) {
        guard let first = issues.first else { return }
        Log.warn("Chưa sẵn sàng để bắt đầu: \(issues.map(\.detail).joined(separator: "; "))")
        if AppSettings.shared.suppressAlerts { return }
        let a = NSAlert()
        a.messageText = "Chưa cài đặt xong phần dịch"
        a.informativeText = issues.map(\.detail).joined(separator: "\n\n")
        a.addButton(withTitle: "Mở Cài đặt")
        a.addButton(withTitle: "Để sau")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { WindowManager.shared.showSettings(tab: first.tab) }
    }

    /// Kiểm tra và báo; true = được bắt đầu.
    static func ensure() -> Bool {
        let issues = check()
        if !issues.isEmpty { alert(issues) }
        return issues.isEmpty
    }
}
