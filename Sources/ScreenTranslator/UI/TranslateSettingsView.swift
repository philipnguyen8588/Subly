import SwiftUI

// MARK: - Khối cài đặt nổi bật (dùng chung cho tab Dịch và tab AI)

/// Một khối cài đặt: nền sáng, viền, tiêu đề lớn có biểu tượng; phía phải tiêu đề là trạng thái / nút.
struct SettingsBlock<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .bold))
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.controlStroke))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// Một hàng "nhãn — điều khiển" trong khối cài đặt, nhãn cố định độ rộng để các hàng thẳng cột.
struct BlockRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// Nhãn trạng thái nhỏ: xanh = sẵn sàng, cam = còn thiếu, xám = không bắt buộc / chưa dùng.
struct StatusChip: View {
    enum Tone { case ok, warn, idle }
    let text: String
    let tone: Tone

    var body: some View {
        let color: Color = tone == .ok ? .green : tone == .warn ? .orange : .secondary
        Label(text, systemImage: tone == .ok ? "checkmark.seal.fill" : tone == .warn ? "exclamationmark.triangle.fill" : "minus.circle")
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 9).frame(height: 24)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Cài đặt → Dịch

struct TranslateSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var pipeline: Pipeline
    /// Chuyển sang tab AI (nơi nhập key và chọn model).
    var openAI: () -> Void = {}
    /// "AI share" chỉ hiện trong ô chọn AI khi đã nhập token.
    private var hasShare: Bool { settings.aiShare != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Label("Dịch sang", systemImage: "globe").foregroundStyle(.secondary)
                    Picker("", selection: $settings.targetLanguage) {
                        ForEach(TargetLanguage.all) { l in Text(l.name).tag(l.code) }
                    }
                    .labelsHidden().fixedSize()
                    if RuntimeConfig.enabled {
                        Spacer()
                        TextField("Email", text: $settings.userEmail, prompt: Text("ban@example.com"))
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                TaskAIBlock(task: .subtitle, settings: settings, openAI: openAI) {
                    Picker("", selection: $settings.translationEngine) {
                        ForEach(TranslationEngine.allCases.filter { $0 != .shared || hasShare || settings.translationEngine == .shared }) {
                            Text($0.pickerLabel).tag($0)
                        }
                    }
                    .labelsHidden()
                } extra: {
                    BlockRow(label: "Ngữ cảnh") {
                        Stepper("\(settings.contextPairs) câu trước", value: $settings.contextPairs, in: 0...10)
                    }
                    BlockRow(label: "Hàng đợi") {
                        Picker("", selection: $settings.queueMode) {
                            ForEach(QueueMode.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }

                TaskAIBlock(task: .screen, settings: settings, openAI: openAI) {
                    Picker("", selection: $settings.screenEngine) {
                        ForEach(ScreenEngine.allCases.filter { $0 != .shared || hasShare || settings.screenEngine == .shared }) { e in
                            Text(e == .sameAsSubtitle ? "Giống dịch phụ đề (\(settings.engine.shortLabel))" : e.shortLabel).tag(e)
                        }
                    }
                    .labelsHidden()
                } extra: {
                    BlockRow(label: "Thời gian chờ") {
                        Slider(value: $settings.analyzeTimeout, in: 5...60, step: 5).frame(maxWidth: 220)
                        Text("\(Int(settings.analyzeTimeout)) s").monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                TaskAIBlock(task: .summary, settings: settings, openAI: openAI) {
                    Picker("", selection: $settings.summaryEngine) {
                        ForEach(SummaryEngine.allCases.filter { $0 != .shared || hasShare || settings.summaryEngine == .shared }) { e in
                            Text(e == .sameAsSubtitle ? "Giống dịch phụ đề" : e.shortLabel).tag(e)
                        }
                    }
                    .labelsHidden()
                } extra: {
                    Toggle("Tự viết cốt truyện khi đang dịch", isOn: $settings.storyEnabled)
                    if settings.storyEnabled {
                        BlockRow(label: "Cập nhật") {
                            Stepper("mỗi \(settings.storyIntervalMin) phút", value: $settings.storyIntervalMin, in: 5...60, step: 5)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

/// Khối cài đặt của một việc dùng AI: chọn AI, chọn model, trạng thái và nút Kiểm tra.
struct TaskAIBlock<EnginePicker: View, Extra: View>: View {
    let task: AITask
    @ObservedObject var settings: AppSettings
    var openAI: () -> Void
    @ViewBuilder var enginePicker: EnginePicker
    @ViewBuilder var extra: Extra
    @State private var testing = false
    @State private var message: (ok: Bool, text: String)?

    var body: some View {
        let e = Readiness.engine(task)
        let issue = Readiness.issue(task)
        let required = Readiness.isRequired(task)
        SettingsBlock(title: Readiness.taskTitle(task), icon: Readiness.taskIcon(task)) {
            if let issue {
                StatusChip(text: required ? issue.title : "\(issue.title) · không bắt buộc", tone: required ? .warn : .idle)
            } else {
                StatusChip(text: e.offline ? "Sẵn sàng · offline" : "Đã kiểm tra", tone: .ok)
            }
            if let issue, issue.tab == .ai {
                Button("Nhập key") { openAI() }.appButton(.tinted)
            } else if e.provider != nil {
                Button(testing ? "Đang kiểm tra…" : "Kiểm tra") { test() }
                    .appButton(issue == nil ? .secondary : .tinted, minWidth: 92).disabled(testing)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                BlockRow(label: "AI") { enginePicker.frame(maxWidth: 300) }
                if let p = e.provider { modelRow(p) }
                if let message {
                    Text(message.text).font(.caption).foregroundStyle(message.ok ? Color.green : Theme.danger)
                        .textSelection(.enabled).lineLimit(3)
                }
                Divider().padding(.vertical, 2)
                extra
            }
        }
        .onChange(of: e.model) { _, _ in message = nil }
    }

    /// Model riêng cho việc này (mặc định = model ở tab AI).
    @ViewBuilder private func modelRow(_ p: String) -> some View {
        let key = "\(task.rawValue).\(p)"
        // AI share: chỉ các model đã share (model đã chọn mà admin bỏ đi thì coi như mặc định).
        let isShare = p == "shared"
        let current = isShare ? settings.taskModel(task, p) ?? "" : settings.taskModels[key] ?? ""
        let base = isShare ? settings.aiShare?.models ?? [] : settings.aiModelLists[p] ?? suggested(p)
        let models = current.isEmpty || base.contains(current) ? base : base + [current]
        let def = settings.defaultModel(p)
        BlockRow(label: "Model") {
            Picker("", selection: Binding(get: { current },
                                          set: { settings.taskModels[key] = $0.isEmpty ? nil : $0 })) {
                Text("Mặc định (\(def.isEmpty ? "chưa chọn" : def))").tag("")
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 300)
        }
    }

    private func suggested(_ p: String) -> [String] {
        switch p {
        case "gemini": return GeminiBackend.models
        case "openAI": return OpenAIBackend.models
        case "anthropic": return AnthropicBackend.models
        default: return []
        }
    }

    private func test() {
        testing = true; message = nil
        Task {
            switch await Readiness.test(task) {
            case .success(let s): message = (true, "OK: \(s)")
            case .failure(let er): message = (false, "Lỗi: \(er.localizedDescription)")
            }
            testing = false
        }
    }
}
