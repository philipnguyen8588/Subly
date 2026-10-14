import SwiftUI

/// Nhà cung cấp AI trả phí trong Cài đặt → AI (Gemini có mục riêng vì lưu được nhiều key).
enum AIProvider: String, CaseIterable, Identifiable {
    case openAI, anthropic, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI (trả phí)"
        case .anthropic: return "Anthropic Claude (trả phí)"
        case .custom: return "API tuỳ chỉnh (tương thích OpenAI)"
        }
    }
    var keyHint: String {
        switch self {
        case .openAI: return "API key (platform.openai.com/api-keys)"
        case .anthropic: return "API key (console.anthropic.com → API keys)"
        case .custom: return "API key (bỏ trống nếu máy chủ không cần)"
        }
    }
    var suggestedModels: [String] {
        switch self {
        case .openAI: return OpenAIBackend.models
        case .anthropic: return AnthropicBackend.models
        case .custom: return []
        }
    }
    var model: ReferenceWritableKeyPath<AppSettings, String> {
        switch self {
        case .openAI: return \.openAIModel
        case .anthropic: return \.anthropicModel
        case .custom: return \.customModel
        }
    }
    var timeout: ReferenceWritableKeyPath<AppSettings, Double> {
        switch self {
        case .openAI: return \.openAITimeout
        case .anthropic: return \.anthropicTimeout
        case .custom: return \.customTimeout
        }
    }
    var key: ReferenceWritableKeyPath<AppSettings, String> {
        switch self {
        case .openAI: return \.openAIKey
        case .anthropic: return \.anthropicKey
        case .custom: return \.customKey
        }
    }

    func listModels(key: String, settings: AppSettings) async throws -> [String] {
        switch self {
        case .openAI: return try await OpenAIBackend.listModels(apiKey: key)
        case .anthropic: return try await AnthropicBackend.listModels(apiKey: key)
        case .custom: return try await OpenAIBackend.listModels(apiKey: key, baseURL: OpenAIBackend.normalize(baseURL: settings.customBaseURL))
        }
    }

    func test(key: String, settings: AppSettings) async -> Result<String, Error> {
        let model = settings[keyPath: self.model]
        switch self {
        case .openAI: return await OpenAIBackend.test(apiKey: key, model: model)
        case .anthropic: return await AnthropicBackend.test(apiKey: key, model: model)
        case .custom:
            return await OpenAIBackend.test(apiKey: key, model: model,
                                            baseURL: OpenAIBackend.normalize(baseURL: settings.customBaseURL), requiresKey: false)
        }
    }
}

/// Cài đặt → AI: key và model của từng nhà cung cấp. Tab Dịch chỉ còn chọn dùng AI nào.
struct AISettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            GeminiKeysSection(settings: settings)
            ForEach(AIProvider.allCases) { ProviderSection(settings: settings, provider: $0) }
        }
        .formStyle(.grouped)
    }

    /// Che key khi hiện trong danh sách: chỉ để lại vài ký tự đầu và cuối.
    static func mask(_ key: String) -> String {
        key.count > 12 ? "\(key.prefix(6))…\(key.suffix(4))" : String(repeating: "•", count: key.count)
    }
}

/// Gemini miễn phí: lưu nhiều key, app dùng xoay vòng để chia đều quota.
struct GeminiKeysSection: View {
    @ObservedObject var settings: AppSettings
    @State private var newKey = ""
    @State private var result = ""
    @State private var keyResults: [String: String] = [:]
    @State private var testing = Set<String>()
    @State private var loadingModels = false

    private var models: [String] {
        var list = settings.aiModelLists["gemini"] ?? GeminiBackend.models
        if !list.contains(settings.geminiModel) { list.append(settings.geminiModel) }
        return list
    }
    private var typed: String { newKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let keys = settings.geminiAPIKeys
        Section("Gemini (miễn phí, nhiều key dùng xoay vòng)") {
            ForEach(keys, id: \.self) { k in
                HStack {
                    Image(systemName: "key").foregroundStyle(.secondary)
                    Text(AISettings.mask(k)).font(.body.monospaced())
                    if let r = keyResults[k] { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Button(testing.contains(k) ? "Đang test…" : "Test key") { test(k) }
                        .controlSize(.small).disabled(testing.contains(k))
                    Button("Xoá key", role: .destructive) {
                        settings.geminiAPIKeys = keys.filter { $0 != k }
                        keyResults[k] = nil
                    }.controlSize(.small)
                }
            }
            SecureField("Thêm API key (aistudio.google.com/apikey)", text: $newKey)
            HStack {
                Button("Lưu key") {
                    if keys.contains(typed) { result = "Key này đã có trong danh sách" }
                    else { settings.geminiAPIKeys = keys + [typed]; newKey = ""; result = "Đã lưu (\(keys.count + 1) key)" }
                }.disabled(typed.isEmpty)
                Button(testing.contains(typed) ? "Đang test…" : "Test key") { test(typed) }
                    .disabled(typed.isEmpty || testing.contains(typed))
                if keys.count > 1 {
                    Button("Test tất cả") { keys.forEach(test) }
                    Button("Xoá tất cả", role: .destructive) { settings.geminiAPIKeys = []; keyResults = [:]; result = "" }
                }
            }
            if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Picker("Model", selection: $settings.geminiModel) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                Button(loadingModels ? "Đang tải…" : "Tải model") { loadModels() }
                    .disabled(loadingModels || (keys.isEmpty && typed.isEmpty))
                    .help("Lấy danh sách model thật mà key này dùng được")
            }
            HStack {
                Text("Timeout phụ đề")
                Slider(value: $settings.geminiTimeout, in: 2...10, step: 0.5)
                Text("\(settings.geminiTimeout, specifier: "%.1f")s").monospacedDigit()
            }
            Text(keys.count > 1
                 ? "Đang có \(keys.count) key: mỗi request dùng key kế tiếp, key nào hết quota (429) thì nghỉ và các key còn lại chạy tiếp. Quota gộp khoảng \(settings.geminiRPM) request/phút, \(settings.geminiRPD) request/ngày."
                 : "Thêm nhiều key (mỗi key từ một tài khoản Google) để app dùng xoay vòng: quota miễn phí được cộng lại và ít bị gián đoạn khi một key hết lượt.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func test(_ key: String) {
        testing.insert(key)
        let model = settings.geminiModel
        let saved = settings.geminiAPIKeys.contains(key)
        Task {
            let text: String
            switch await GeminiBackend.test(apiKey: key, model: model) {
            case .success(let s): text = "OK: \(s)"
            case .failure(let e): text = "Lỗi: \(e.localizedDescription)"
            }
            if saved { keyResults[key] = text } else { result = text }
            testing.remove(key)
        }
    }

    private func loadModels() {
        loadingModels = true
        let key = typed.isEmpty ? settings.geminiAPIKey : typed, base = settings.geminiBaseURL
        Task {
            do {
                let list = try await GeminiBackend.listModels(apiKey: key, baseURL: base)
                if !list.isEmpty {
                    settings.aiModelLists["gemini"] = list
                    if !list.contains(settings.geminiModel) { settings.geminiModel = list[0] }
                }
                result = "Có \(list.count) model dùng được"
            } catch {
                result = "Không tải được danh sách: \(error.localizedDescription)"
            }
            loadingModels = false
        }
    }
}

/// Một nhà cung cấp trả phí: key (lưu / test / xoá), model (chọn hoặc tải danh sách), thời gian chờ.
struct ProviderSection: View {
    @ObservedObject var settings: AppSettings
    let provider: AIProvider
    @State private var key = ""
    @State private var result = ""
    @State private var testing = false
    @State private var loadingModels = false

    private var savedKey: String { settings[keyPath: provider.key] }
    private var typed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var models: [String] {
        var list = settings.aiModelLists[provider.rawValue] ?? provider.suggestedModels
        let current = settings[keyPath: provider.model]
        if !current.isEmpty, !list.contains(current) { list.append(current) }
        return list
    }
    /// API tuỳ chỉnh có thể không cần key; hai hãng còn lại bắt buộc.
    private var canCall: Bool {
        provider == .custom ? !settings.customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty : !typed.isEmpty
    }

    var body: some View {
        Section(provider.title) {
            if provider == .custom {
                TextField("Địa chỉ API", text: $settings.customBaseURL, prompt: Text("https://openrouter.ai/api/v1"))
                    .autocorrectionDisabled()
            }
            SecureField(provider.keyHint, text: $key)
            HStack {
                Button("Lưu key") { settings[keyPath: provider.key] = typed; result = typed.isEmpty ? "Đã xoá key" : "Đã lưu" }
                    .disabled(typed == savedKey)
                Button(testing ? "Đang test…" : "Test key") { test() }.disabled(testing || !canCall)
                if !savedKey.isEmpty {
                    Button("Xoá key", role: .destructive) { settings[keyPath: provider.key] = ""; key = ""; result = "" }
                }
            }
            if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if provider == .custom {
                TextField("Model", text: $settings.customModel, prompt: Text("gõ tên model hoặc bấm Tải model"))
                    .autocorrectionDisabled()
            }
            HStack {
                if !models.isEmpty {
                    Picker(provider == .custom ? "Chọn từ danh sách" : "Model", selection: $settings[dynamicMember: provider.model]) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Text("Chưa có danh sách model").foregroundStyle(.secondary)
                    Spacer()
                }
                Button(loadingModels ? "Đang tải…" : "Tải model") { loadModels() }
                    .disabled(loadingModels || !canCall)
                    .help("Lấy danh sách model thật mà key này dùng được")
            }
            HStack {
                Text("Timeout phụ đề")
                Slider(value: $settings[dynamicMember: provider.timeout], in: 2...15, step: 0.5)
                Text("\(settings[keyPath: provider.timeout], specifier: "%.1f")s").monospacedDigit()
            }
            if provider == .custom {
                Text("Dùng cho máy chủ nói giao thức Chat Completions của OpenAI: OpenRouter, Groq, DeepSeek, hoặc model chạy trên máy như Ollama (http://localhost:11434/v1), LM Studio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { key = savedKey }
    }

    private func test() {
        testing = true; result = ""
        let k = typed
        Task {
            switch await provider.test(key: k, settings: settings) {
            case .success(let s): result = "OK: \(s)"
            case .failure(let e): result = "Lỗi: \(e.localizedDescription)"
            }
            testing = false
        }
    }

    private func loadModels() {
        loadingModels = true
        let k = typed
        Task {
            do {
                let list = try await provider.listModels(key: k, settings: settings)
                if !list.isEmpty {
                    settings.aiModelLists[provider.rawValue] = list
                    let current = settings[keyPath: provider.model]
                    if provider == .custom, current.isEmpty { settings.customModel = list[0] }
                }
                result = "Có \(list.count) model dùng được"
            } catch {
                result = "Không tải được danh sách: \(error.localizedDescription)"
            }
            loadingModels = false
        }
    }
}
