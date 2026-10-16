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

/// Cài đặt → AI: mỗi nhà cung cấp một khối (key, model, thời gian chờ) kèm trạng thái và việc đang dùng nó.
struct AISettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if AIShareClient.available { AIShareSection(settings: settings) }
                GeminiKeysSection(settings: settings)
                ForEach(AIProvider.allCases) { ProviderSection(settings: settings, provider: $0) }
            }
            .padding(20)
        }
    }

    /// Che key khi hiện trong danh sách: chỉ để lại vài ký tự đầu và cuối.
    static func mask(_ key: String) -> String {
        key.count > 12 ? "\(key.prefix(6))…\(key.suffix(4))" : String(repeating: "•", count: key.count)
    }

    /// Các model cần thử khi bấm Test key: model mặc định + model riêng của các việc đang dùng nhà cung cấp này.
    @MainActor static func modelsToTest(_ p: String) -> [String] {
        var out: [String] = []
        for m in [AppSettings.shared.defaultModel(p)] + Readiness.tasks(using: p).map({ Readiness.model($0, p) })
        where !m.isEmpty && !out.contains(m) { out.append(m) }
        return out
    }

    /// Test một key với mọi model cần thử, ghi nhận từng kết quả.
    @MainActor static func test(_ p: String, key: String, run: (String) async -> Result<String, Error>) async -> String {
        let models = modelsToTest(p)
        guard !models.isEmpty else { return "Lỗi: chưa chọn model" }
        var failures: [String] = []
        var okText = ""
        for m in models {
            let r = await run(m)
            Readiness.record(p, model: m, key: key, ok: (try? r.get()) != nil)
            switch r {
            case .success(let s): okText = s
            case .failure(let e): failures.append(models.count > 1 ? "\(m): \(e.localizedDescription)" : e.localizedDescription)
            }
        }
        return failures.isEmpty ? "OK: \(okText)" : "Lỗi: " + failures.joined(separator: "; ")
    }

    /// Trạng thái của một nhà cung cấp và tên các việc đang dùng nó.
    @MainActor static func status(_ p: String, hasKey: Bool) -> (text: String, tone: StatusChip.Tone, uses: String?) {
        let uses = Readiness.tasks(using: p)
        let usesText = uses.isEmpty ? nil : "Đang dùng cho: " + uses.map(Readiness.taskTitle).joined(separator: ", ")
        if !hasKey { return ("Chưa có key", uses.isEmpty ? .idle : .warn, usesText) }
        if uses.isEmpty { return ("Chưa dùng", .idle, usesText) }
        let ok = uses.allSatisfy { Readiness.isVerified(p, model: Readiness.model($0, p)) }
        return ok ? ("Đã kiểm tra", .ok, usesText) : ("Chưa kiểm tra", .warn, usesText)
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
        let st = AISettings.status("gemini", hasKey: !keys.isEmpty)
        SettingsBlock(title: "Gemini", icon: "sparkles", subtitle: st.uses ?? "Miễn phí · lưu được nhiều key, dùng xoay vòng") {
            StatusChip(text: st.text, tone: st.tone)
            if keys.count > 1 {
                Button("Test tất cả") { keys.forEach(test) }.appButton()
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(keys, id: \.self) { k in
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        Text(AISettings.mask(k)).font(.body.monospaced())
                        if let r = keyResults[k] {
                            Text(r).font(.caption).foregroundStyle(r.hasPrefix("OK") ? Color.green : Theme.danger).lineLimit(1)
                        } else if AISettings.modelsToTest("gemini").allSatisfy({ Readiness.isVerified("gemini", model: $0, key: k) }) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Đã kiểm tra")
                        }
                        Spacer()
                        Button(testing.contains(k) ? "Đang test…" : "Test") { test(k) }
                            .appButton(minWidth: 90).disabled(testing.contains(k))
                        Button(role: .destructive) {
                            settings.geminiAPIKeys = keys.filter { $0 != k }
                            keyResults[k] = nil
                        } label: { Image(systemName: "trash") }
                        .appIconButton().help("Xoá key này")
                    }
                }
                BlockRow(label: keys.isEmpty ? "API key" : "Thêm key") {
                    SecureField("aistudio.google.com/apikey", text: $newKey).textFieldStyle(.roundedBorder)
                    Button("Lưu") {
                        if keys.contains(typed) { result = "Key này đã có trong danh sách" }
                        else { settings.geminiAPIKeys = keys + [typed]; newKey = ""; result = "" }
                    }
                    .appButton(.primary).disabled(typed.isEmpty)
                    Button(testing.contains(typed) ? "Đang test…" : "Test") { test(typed) }
                        .appButton(minWidth: 90).disabled(typed.isEmpty || testing.contains(typed))
                }
                if !result.isEmpty {
                    Text(result).font(.caption).foregroundStyle(result.hasPrefix("OK") ? Color.green : Theme.danger).textSelection(.enabled)
                }
                BlockRow(label: "Model") {
                    Picker("", selection: $settings.geminiModel) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                    Button(loadingModels ? "Đang tải…" : "Tải model") { loadModels() }
                        .appButton().disabled(loadingModels || (keys.isEmpty && typed.isEmpty))
                        .help("Lấy danh sách model thật mà key này dùng được")
                }
                BlockRow(label: "Thời gian chờ") {
                    Slider(value: $settings.geminiTimeout, in: 2...10, step: 0.5).frame(maxWidth: 220)
                    Text("\(settings.geminiTimeout, specifier: "%.1f") s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func test(_ key: String) {
        testing.insert(key)
        let saved = settings.geminiAPIKeys.contains(key)
        Task {
            let text = await AISettings.test("gemini", key: key) { await GeminiBackend.test(apiKey: key, model: $0) }
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
                result = "OK: có \(list.count) model dùng được"
            } catch {
                result = "Lỗi: không tải được danh sách: \(error.localizedDescription)"
            }
            loadingModels = false
        }
    }
}

/// Một nhà cung cấp trả phí / tuỳ chỉnh: key (lưu / test / xoá), model (chọn hoặc tải danh sách), thời gian chờ.
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
    private var shortTitle: String {
        switch provider {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .custom: return "API tuỳ chỉnh"
        }
    }
    private var icon: String {
        switch provider {
        case .openAI: return "bolt.fill"
        case .anthropic: return "asterisk"
        case .custom: return "server.rack"
        }
    }

    var body: some View {
        let hasKey = provider == .custom ? !settings.customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty : !savedKey.isEmpty
        let st = AISettings.status(provider.rawValue, hasKey: hasKey)
        SettingsBlock(title: shortTitle, icon: icon, subtitle: st.uses ?? (provider == .custom ? "OpenRouter, Groq, Ollama, LM Studio…" : "Trả phí")) {
            StatusChip(text: provider == .custom && !hasKey ? "Chưa có địa chỉ" : st.text, tone: st.tone)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if provider == .custom {
                    BlockRow(label: "Địa chỉ API") {
                        TextField("", text: $settings.customBaseURL, prompt: Text("https://openrouter.ai/api/v1"))
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    }
                }
                BlockRow(label: "API key") {
                    SecureField(provider == .custom ? "bỏ trống nếu không cần" : "", text: $key).textFieldStyle(.roundedBorder)
                    Button("Lưu") { settings[keyPath: provider.key] = typed; result = typed.isEmpty ? "Đã xoá key" : "" }
                        .appButton(.primary).disabled(typed == savedKey)
                    Button(testing ? "Đang test…" : "Test") { test() }.appButton(minWidth: 90).disabled(testing || !canCall)
                    if !savedKey.isEmpty {
                        Button(role: .destructive) { settings[keyPath: provider.key] = ""; key = ""; result = "" } label: { Image(systemName: "trash") }
                            .appIconButton().help("Xoá key")
                    }
                }
                if !result.isEmpty {
                    Text(result).font(.caption).foregroundStyle(result.hasPrefix("OK") ? Color.green : Theme.danger).textSelection(.enabled)
                }
                if provider == .custom {
                    BlockRow(label: "Tên model") {
                        TextField("", text: $settings.customModel, prompt: Text("gõ tên hoặc bấm Tải model"))
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    }
                }
                BlockRow(label: "Model") {
                    if !models.isEmpty {
                        Picker("", selection: $settings[dynamicMember: provider.model]) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 280)
                    } else {
                        Text("Chưa có danh sách").foregroundStyle(.secondary)
                    }
                    Button(loadingModels ? "Đang tải…" : "Tải model") { loadModels() }
                        .appButton().disabled(loadingModels || !canCall)
                        .help("Lấy danh sách model thật mà key này dùng được")
                }
                BlockRow(label: "Thời gian chờ") {
                    Slider(value: $settings[dynamicMember: provider.timeout], in: 2...15, step: 0.5).frame(maxWidth: 220)
                    Text("\(settings[keyPath: provider.timeout], specifier: "%.1f") s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { key = savedKey }
    }

    private func test() {
        testing = true; result = ""
        let k = typed
        let p = provider
        Task {
            result = await AISettings.test(p.rawValue, key: k) { model in
                switch p {
                case .openAI: return await OpenAIBackend.test(apiKey: k, model: model)
                case .anthropic: return await AnthropicBackend.test(apiKey: k, model: model)
                case .custom: return await OpenAIBackend.test(apiKey: k, model: model,
                                                              baseURL: OpenAIBackend.normalize(baseURL: settings.customBaseURL), requiresKey: false)
                }
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
                result = "OK: có \(list.count) model dùng được"
            } catch {
                result = "Lỗi: không tải được danh sách: \(error.localizedDescription)"
            }
            loadingModels = false
        }
    }
}

/// AI share: dán token do chủ server cấp. Key thật nằm trên server, app chỉ gửi token qua proxy và chỉ dùng được
/// các model đã share; chủ server sửa model hay thu hồi thì app nhận ở lần kiểm tra kế tiếp.
struct AIShareSection: View {
    @ObservedObject var settings: AppSettings
    @State private var token = ""
    @State private var busy = false
    @State private var result = ""

    private var typed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let info = settings.aiShare
        let st = status(info)
        SettingsBlock(title: "AI share", icon: "person.2.fill",
                      subtitle: st.uses ?? "Dùng key người khác chia sẻ (qua server, không thấy key)") {
            StatusChip(text: st.text, tone: st.tone)
            if info != nil {
                Button(busy ? "Đang kiểm tra…" : "Kiểm tra") { check() }.appButton(minWidth: 92).disabled(busy)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if let info {
                    BlockRow(label: "Share") {
                        Image(systemName: "key.horizontal.fill").foregroundStyle(.secondary)
                        Text(info.label.isEmpty ? "(không tên)" : info.label).fontWeight(.semibold)
                        Text("· \(AIShareClient.providerName(info.provider))").foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { AIShareClient.remove(); result = "" } label: { Image(systemName: "trash") }
                            .appIconButton().help("Bỏ AI share này")
                    }
                    BlockRow(label: "Model") {
                        Text(info.models.joined(separator: ", ")).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                BlockRow(label: info == nil ? "Token" : "Token mới") {
                    TextField("", text: $token, prompt: Text("dán token sts_…")).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    Button(busy ? "Đang nhập…" : "Nhập") { importToken() }.appButton(.primary).disabled(typed.isEmpty || busy)
                }
                if !result.isEmpty {
                    Text(result).font(.caption).foregroundStyle(result.hasPrefix("OK") ? Color.green : Theme.danger).textSelection(.enabled)
                }
                Text("Chọn “AI share” ở Cài đặt → Dịch để dùng cho từng việc. Key thật nằm trên server của người share; app chỉ giữ token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ info: AppSettings.AIShareInfo?) -> (text: String, tone: StatusChip.Tone, uses: String?) {
        guard let info else { return ("Chưa nhập", .idle, nil) }
        let st = AISettings.status("shared", hasKey: true)
        if info.revoked { return ("Bị thu hồi", .warn, st.uses) }
        return st
    }

    private func importToken() {
        busy = true; result = ""
        let t = typed
        Task {
            do {
                let info = try await AIShareClient.importToken(t)
                token = ""
                result = "OK: đã nhập “\(info.label)” · \(AIShareClient.providerName(info.provider)) · \(info.models.count) model"
            } catch {
                result = "Lỗi: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// Lấy lại thông tin share từ server rồi dịch thử bằng các model đang dùng.
    private func check() {
        busy = true; result = ""
        Task {
            if let err = await AIShareClient.refresh() {
                result = "Lỗi: \(err.localizedDescription)"
            } else {
                result = await AISettings.test("shared", key: settings.aiShareToken) { await AIShareClient.test(model: $0) }
            }
            busy = false
        }
    }
}
