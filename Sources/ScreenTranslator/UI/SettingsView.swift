import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import CoreImage

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var pipeline = Pipeline.shared
    @State private var tab: Tab = .translate

    enum Tab: String, CaseIterable, Identifiable {
        case translate, capture, voice, overlay, glossary, profile, hotkeys, web
        var id: String { rawValue }
        var title: String {
            switch self {
            case .translate: return "Dịch"; case .capture: return "Capture & OCR"; case .voice: return "Voice"
            case .overlay: return "Overlay"; case .glossary: return "Thuật ngữ chung"; case .profile: return "Game"; case .hotkeys: return "Phím tắt"
            case .web: return "iPhone / Web"
            }
        }
        var icon: String {
            switch self {
            case .translate: return "character.bubble"; case .capture: return "rectangle.dashed"; case .voice: return "speaker.wave.2"
            case .overlay: return "captions.bubble"; case .glossary: return "character.book.closed"; case .profile: return "gamecontroller"; case .hotkeys: return "keyboard"
            case .web: return "iphone"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(Tab.allCases, selection: $tab) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                switch tab {
                case .translate: TranslateSettings(settings: settings, pipeline: pipeline)
                case .capture: CaptureSettings(settings: settings)
                case .voice: VoiceSettings(settings: settings)
                case .overlay: OverlaySettings(settings: settings, pipeline: pipeline)
                case .glossary: GlossarySettings(settings: settings).padding()
                case .profile: ProfileSettings(settings: settings).padding()
                case .hotkeys: HotkeySettings(settings: settings)
                case .web: WebSettings(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

struct TranslateSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var pipeline: Pipeline
    @State private var key = ""
    @State private var testResult = ""
    @State private var testing = false
    @State private var models: [String] = GeminiBackend.models
    @State private var loadingModels = false

    var body: some View {
        Form {
            Section("Ngôn ngữ") {
                Picker("Dịch sang", selection: $settings.targetLanguage) {
                    ForEach(TargetLanguage.all) { l in Text(l.name).tag(l.code) }
                }
                Text("Nguồn: tiếng Anh. Đổi ngôn ngữ đích sẽ đổi cả giọng đọc và gói Apple Translation.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Engine dịch phụ đề") {
                Picker("Engine", selection: $settings.translationEngine) {
                    ForEach(TranslationEngine.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("Apple Intelligence:")
                    let st = pipeline.router.ai.status
                    Text(st.label).foregroundStyle(st == .available ? .green : .orange)
                    Spacer()
                    if st != .available {
                        Button("Mở System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                        }.controlSize(.small)
                    }
                }
                if settings.translationEngine == .appleIntelligence {
                    HStack {
                        Text("Timeout")
                        Slider(value: $settings.aiTimeout, in: 1.5...8, step: 0.5)
                        Text("\(settings.aiTimeout, specifier: "%.1f")s").monospacedDigit()
                    }
                }
                Text("Apple Intelligence là model ngôn ngữ chạy ngay trên máy: miễn phí, không cần mạng, dùng được ngữ cảnh, thuật ngữ và tên nhân vật. Đo trên máy này: 0,4–1,3 s mỗi câu (Apple Translation ~30 ms, Gemini ~1 s). Lỗi hay quá thời gian thì tự rơi về Apple Translation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            OpenAISettings(settings: settings)
            Section("Gemini API (free tier)") {
                SecureField("API key (aistudio.google.com/apikey)", text: $key)
                HStack {
                    Button("Lưu key") { settings.geminiAPIKey = key.trimmingCharacters(in: .whitespaces); testResult = "Đã lưu" }
                    Button(testing ? "Đang test…" : "Test key") { testKey() }.disabled(testing || key.isEmpty)
                    if !settings.geminiAPIKey.isEmpty {
                        Button("Xoá key", role: .destructive) { settings.geminiAPIKey = ""; key = ""; testResult = "" }
                    }
                }
                if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Picker("Model", selection: $settings.geminiModel) {
                        ForEach(models, id: \.self) { Text($0) }
                    }
                    Button(loadingModels ? "…" : "Tải danh sách") { loadModels() }
                        .disabled(loadingModels || settings.geminiAPIKey.isEmpty)
                        .help("Lấy danh sách model thật mà key này dùng được")
                }
                Text("Nếu model quá tải (503) hay không có (404), app tự thử: \(GeminiBackend.fallbackModels.joined(separator: " → ")).")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Giới hạn: \(settings.rpm) request/phút", value: $settings.rpm, in: 1...60)
                Stepper("Giới hạn: \(settings.rpd) request/ngày", value: $settings.rpd, in: 10...5000, step: 10)
                Text("Đã dùng hôm nay: \(pipeline.router.usedToday)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Timeout phụ đề")
                    Slider(value: $settings.geminiTimeout, in: 2...10, step: 0.5)
                    Text("\(settings.geminiTimeout, specifier: "%.1f")s").monospacedDigit()
                }
                Stepper("Ngữ cảnh: \(settings.contextPairs) câu trước", value: $settings.contextPairs, in: 0...10)
            }
            Section("Apple Translation (on-device, fallback)") {
                HStack {
                    Text("Gói ngôn ngữ Anh → \(settings.target.name):")
                    switch pipeline.apple.installed {
                    case .some(true): Text("đã cài").foregroundStyle(.green)
                    case .some(false): Text("chưa cài").foregroundStyle(.red)
                    case .none: Text("đang kiểm tra…").foregroundStyle(.secondary)
                    }
                }
                LanguageDownloadButton(backend: pipeline.apple)
            }
            Section("Dịch màn hình (thủ công)") {
                Picker("Engine", selection: $settings.screenEngine) {
                    ForEach(ScreenEngine.allCases) { Text($0.label).tag($0) }
                }
                if settings.screenEngine == .openAI, settings.openAIKey.isEmpty {
                    Text("Chưa có OpenAI API key (nhập ở mục OpenAI phía trên) nên sẽ dùng engine trên máy.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if settings.screenEngine == .gemini, settings.geminiAPIKey.isEmpty {
                    Text("Chưa có Gemini API key (nhập ở mục Gemini phía trên) nên sẽ dùng engine trên máy.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Chọn riêng với engine phụ đề: phụ đề cần nhanh, còn dịch màn hình (nhật ký, tiểu sử nhân vật, nhiệm vụ) cần hiểu và tóm tắt kỹ. Gemini lỗi, hết quota hoặc mất mạng thì tự dùng engine trên máy.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Đọc tóm tắt bằng giọng nói", isOn: $settings.analyzeSpeakSummary)
                HStack {
                    Text("Timeout")
                    Slider(value: $settings.analyzeTimeout, in: 5...60, step: 5)
                    Text("\(Int(settings.analyzeTimeout))s").monospacedDigit()
                }
            }
            Section("Hàng đợi phụ đề") {
                Picker("Chế độ", selection: $settings.queueMode) {
                    ForEach(QueueMode.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            key = settings.geminiAPIKey
            if !models.contains(settings.geminiModel) { models.append(settings.geminiModel) }
        }
    }

    private func loadModels() {
        loadingModels = true
        let k = settings.geminiAPIKey, base = settings.geminiBaseURL
        Task {
            do {
                let list = try await GeminiBackend.listModels(apiKey: k, baseURL: base)
                if !list.isEmpty {
                    models = list
                    if !list.contains(settings.geminiModel) { settings.geminiModel = list[0] }
                }
                testResult = "Có \(list.count) model dùng được"
            } catch {
                testResult = "Không tải được danh sách: \(error.localizedDescription)"
            }
            loadingModels = false
        }
    }

    private func testKey() {
        testing = true; testResult = ""
        let k = key.trimmingCharacters(in: .whitespaces), m = settings.geminiModel
        Task {
            switch await GeminiBackend.test(apiKey: k, model: m) {
            case .success(let s): testResult = "OK: \(s)"
            case .failure(let e): testResult = "Lỗi: \(e.localizedDescription)"
            }
            testing = false
        }
    }
}

/// Mục OpenAI trong Cài đặt → Dịch: key, model, thời gian chờ.
struct OpenAISettings: View {
    @ObservedObject var settings: AppSettings
    @State private var key = ""
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        Section("OpenAI API (trả phí)") {
            SecureField("API key (platform.openai.com/api-keys)", text: $key)
            HStack {
                Button("Lưu key") { settings.openAIKey = key.trimmingCharacters(in: .whitespacesAndNewlines); result = "Đã lưu" }
                Button(testing ? "Đang test…" : "Test key") { test() }.disabled(testing || key.isEmpty)
                if !settings.openAIKey.isEmpty {
                    Button("Xoá key", role: .destructive) { settings.openAIKey = ""; key = ""; result = "" }
                }
            }
            if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Picker("Model", selection: $settings.openAIModel) {
                ForEach(OpenAIBackend.models, id: \.self) { Text($0).tag($0) }
                if !OpenAIBackend.models.contains(settings.openAIModel) { Text(settings.openAIModel).tag(settings.openAIModel) }
            }
            HStack {
                Text("Timeout phụ đề")
                Slider(value: $settings.openAITimeout, in: 2...10, step: 0.5)
                Text("\(settings.openAITimeout, specifier: "%.1f")s").monospacedDigit()
            }
            Text("Dùng khi chọn engine OpenAI ở trên (phụ đề) hoặc ở mục Dịch màn hình. Tính tiền theo token. gpt-5.4-nano rẻ nhất (~1 s/câu) nhưng hay dịch lủng củng; gpt-5.4-mini tự nhiên hơn, gần như cùng tốc độ; gpt-5.4 hay nhất (~1,7 s/câu), đắt nhất. Xem giá ở trang Pricing của OpenAI. Lỗi, hết tiền hoặc mất mạng thì tự dùng Apple Intelligence. Key lưu trong file chỉ tài khoản của bạn đọc được.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { key = settings.openAIKey }
    }

    private func test() {
        testing = true; result = ""
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines), m = settings.openAIModel
        Task {
            switch await OpenAIBackend.test(apiKey: k, model: m) {
            case .success(let s): result = "OK: \(s)"
            case .failure(let e): result = "Lỗi: \(e.localizedDescription)"
            }
            testing = false
        }
    }
}

struct CaptureSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section("Capture") {
                Picker("Tần suất quét", selection: $settings.fps) {
                    Text("2 fps").tag(2); Text("4 fps").tag(4); Text("8 fps").tag(8)
                }
                Picker("Độ phân giải capture", selection: $settings.captureScale) {
                    Text("1×").tag(1.0); Text("1.5×").tag(1.5); Text("2× (Retina)").tag(2.0)
                }
                HStack {
                    Text("Chờ ổn định sau khi đổi")
                    Slider(value: $settings.stableDelayMs, in: 0...1000, step: 50)
                    Text("\(Int(settings.stableDelayMs)) ms").monospacedDigit()
                }
                HStack {
                    Text("Ngưỡng phát hiện thay đổi")
                    Slider(value: $settings.diffThreshold, in: 1...20, step: 1)
                    Text("\(Int(settings.diffThreshold))").monospacedDigit()
                }
            }
            Section("OCR") {
                Toggle("OCR chính xác (khuyên dùng, ~60 ms; tắt = chế độ nhanh ~20 ms nhưng hay đọc sai)", isOn: $settings.ocrAccurate)
                HStack {
                    Text("Bỏ qua chữ nhỏ hơn (tỉ lệ chiều cao vùng)")
                    Slider(value: $settings.minTextHeight, in: 0...0.3, step: 0.01)
                    Text("\(settings.minTextHeight, specifier: "%.2f")").monospacedDigit()
                }
                HStack {
                    Text("Coi là trùng nếu giống ≥")
                    Slider(value: $settings.dedupSimilarity, in: 0.5...1, step: 0.05)
                    Text("\(Int(settings.dedupSimilarity * 100))%").monospacedDigit()
                }
                Toggle("Soi thông minh: nghỉ sau mỗi câu phụ đề (câu dài nghỉ tối đa 1,2 s, câu ngắn ~0,3 s) để giảm OCR", isOn: $settings.adaptiveCapture)
                Toggle("Bỏ qua câu chỉ có từ cảm thán (hmm, haha, huh, ugh…) và mô tả âm thanh như [grunts]", isOn: $settings.skipInterjections)
                Toggle("Không dịch, không đọc câu quá đơn giản (1–2 từ, hoặc tối đa 5 từ toàn từ cơ bản như yes, no, okay, let's go); vẫn ghi câu gốc vào nhật ký", isOn: $settings.skipSimpleLines)
                Toggle("Chỉ nhận chữ nằm giữa khung phụ đề – bỏ chữ ở mép như nút Quick Save, Back (tắt nếu game canh phụ đề sang trái)", isOn: $settings.centerOnlySubtitles)
                Toggle("Bỏ qua chữ giao diện (menu, cài đặt, danh sách) – chỉ dịch khi trông giống phụ đề", isOn: $settings.skipUIText)
                Text("Nhận biết qua nhiều từ Viết Hoa, nhiều cột/hàng, cỡ chữ lẫn, nhiều số. Tắt nếu game có phụ đề kiểu lạ bị bỏ qua nhầm (xem log “UI[...] bỏ qua”). Có hiệu lực khi Bắt đầu lại.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Thay đổi capture có hiệu lực khi Bắt đầu lại. Game có hiệu ứng chữ chạy: tăng “Chờ ổn định”.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct VoiceSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var catalog = VoiceCatalog.shared

    var body: some View {
        let voices = Speaker.voices(for: settings.targetLanguage)
        Form {
            Section("Voice") {
                Toggle("Đọc bản dịch", isOn: $settings.voiceEnabled)
                Picker("Engine", selection: $settings.voiceEngine) {
                    ForEach(Speaker.Engine.allCases) { Text($0.label).tag($0) }
                }
                if settings.voiceEngine == .edge {
                    Picker("Giọng Edge (\(settings.target.name))", selection: $settings.edgeVoice) {
                        Text("Mặc định (\(EdgeTTS.voices(for: settings.targetLanguage).first?.name ?? "—"))").tag("")
                        ForEach(EdgeTTS.voices(for: settings.targetLanguage)) { v in Text(v.name).tag(v.id) }
                    }
                    HStack {
                        Text("Tốc độ giọng Edge")
                        Slider(value: $settings.edgeRatePercent, in: -20...100, step: 5)
                        Text(settings.edgeRatePercent >= 0 ? "+\(Int(settings.edgeRatePercent))%" : "\(Int(settings.edgeRatePercent))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    Text("Giọng neural của Microsoft (có giọng nam), miễn phí, cần mạng. Lưu ý: máy chủ miễn phí mất 3–5 giây mới bắt đầu trả âm thanh cho mỗi câu mới, nên KHÔNG hợp với phụ đề thời gian thực. Lỗi 3 lần liên tiếp thì app tự dùng giọng Apple.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if settings.voiceEngine == .local {
                Section("Giọng AI offline (tiếng Việt)") {
                    ForEach(VoiceCatalog.voices) { v in
                        HStack(spacing: 8) {
                            Image(systemName: settings.localVoiceID == v.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(settings.localVoiceID == v.id ? Color.accentColor : .secondary)
                                .onTapGesture { if catalog.installed.contains(v.id) { settings.localVoiceID = v.id } }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name)
                                if !v.note.isEmpty { Text(v.note).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let p = catalog.downloading[v.id] {
                                ProgressView(value: p).frame(width: 90)
                                Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                            } else if catalog.installed.contains(v.id) {
                                Button("Nghe thử") { preview(local: v.id) }.controlSize(.small)
                                Button("Xoá", role: .destructive) { catalog.delete(v.id) }.controlSize(.small)
                            } else {
                                if let e = catalog.errors[v.id] { Text(e).font(.caption).foregroundStyle(.red).lineLimit(1) }
                                Button("Tải (\(v.sizeMB) MB)") { catalog.download(v.id); settings.localVoiceID = v.id }.controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        Text("Tốc độ")
                        Slider(value: $settings.localSpeed, in: 0.8...1.8, step: 0.05)
                        Text("×\(settings.localSpeed, specifier: "%.2f")").monospacedDigit()
                    }
                    Text("Model neural chạy ngay trên máy, không cần mạng sau khi tải. Mỗi câu mất khoảng 0,1–0,3 s để tạo tiếng (đo trên máy này: 6,5 s âm thanh trong 0,3 s). Lần tải đầu kèm 18 MB dữ liệu phiên âm dùng chung. Chỉ có tiếng Việt; ngôn ngữ đích khác sẽ dùng giọng Apple.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Giọng Apple (offline)") {
                Picker("Giọng (\(settings.target.name))", selection: $settings.voiceIdentifier) {
                    if let b = Speaker.bestVoice(for: settings.targetLanguage) {
                        Text("Mặc định (\(b.name) – \(Speaker.qualityName(b.quality)))").tag("")
                    } else {
                        Text("Mặc định").tag("")
                    }
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) – \(Speaker.qualityName(v.quality))").tag(v.identifier)
                    }
                }
                if !voices.contains(where: { $0.quality != .default }) {
                    Text("Chưa có giọng Enhanced cho ngôn ngữ này. Tải trong System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Tốc độ")
                    Slider(value: $settings.voiceRate, in: 0.3...0.85)
                    Text("\(settings.voiceRate, specifier: "%.2f")").monospacedDigit()
                }
                Toggle("Ngắt câu đang đọc khi có câu mới (tắt = đọc hết từng câu theo thứ tự)", isOn: $settings.interruptSpeech)
                if !settings.interruptSpeech {
                    HStack {
                        Text("Khi còn câu đang đọc dở, câu kế tiếp nhanh thêm")
                        Slider(value: $settings.catchUpPercent, in: 0...50, step: 5)
                        Text("+\(Int(settings.catchUpPercent))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    if settings.queueMode != .fifo {
                        Text("Hàng đợi phụ đề đang ở chế độ “chỉ giữ câu mới nhất” nên câu chưa kịp dịch vẫn có thể bị bỏ. Đổi sang “Hội thoại (đọc lần lượt)” ở Cài đặt → Dịch.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Toggle("Không đọc tên người nói ở đầu câu (\"Kratos: …\")", isOn: $settings.voiceSkipSpeaker)
                Toggle("Tự đọc nhanh hơn với câu dài (+10 % / +20 % / +30 %)", isOn: $settings.voiceAdaptiveRate)
                Toggle("Phát giọng đọc trên TV / điện thoại thay vì loa Mac", isOn: $settings.voiceOnRemote)
                Text("Gửi âm thanh (đúng giọng đang chọn ở trên) tới app Subtitle TV hoặc trang web đang mở qua máy chủ web. Không có máy nào đang xem thì đọc ra loa Mac như cũ.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Nghe thử") {
                    let s = Pipeline.shared.speaker
                    s.rate = Float(settings.voiceRate); s.voiceIdentifier = settings.voiceIdentifier; s.language = settings.targetLanguage
                    s.engine = settings.voiceEngine
                    s.edgeRatePercent = settings.edgeRatePercent
                    s.edgeVoice = settings.edgeVoice.isEmpty ? EdgeTTS.defaultVoice(for: settings.targetLanguage) : settings.edgeVoice
                    s.localVoiceID = settings.localVoiceID; s.localSpeed = settings.localSpeed
                    s.resetEdgeFailures()
                    s.speak(settings.targetLanguage == "vi" ? "Xin chào, đây là giọng đọc bản dịch của ScreenTranslator." : "Hello, this is the translation voice.")
                }
                Text("Giọng hay hơn: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices → tải giọng Enhanced/Premium.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func preview(local id: String) {
        settings.localVoiceID = id
        let s = Pipeline.shared.speaker
        s.language = settings.targetLanguage
        s.engine = .local
        s.localVoiceID = id
        s.localSpeed = settings.localSpeed
        s.speak("Xin chào, đây là giọng đọc bản dịch của ScreenTranslator.")
    }
}

struct OverlaySettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var pipeline: Pipeline
    var body: some View {
        Form {
            Section("Overlay phụ đề") {
                Toggle("Hiện bản dịch trên màn hình", isOn: $settings.overlayEnabled)
                Picker("Vị trí", selection: $settings.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Hiện cả câu gốc", isOn: $settings.overlayShowSource)
                HStack {
                    Text("Cỡ chữ")
                    Slider(value: $settings.overlayFontSize, in: 14...40, step: 1)
                    Text("\(Int(settings.overlayFontSize))").monospacedDigit()
                }
                HStack {
                    Text("Độ mờ nền")
                    Slider(value: $settings.overlayOpacity, in: 0.2...1, step: 0.05)
                    Text("\(Int(settings.overlayOpacity * 100))%").monospacedDigit()
                }
                HStack {
                    Text("Bề rộng tối đa")
                    Slider(value: $settings.overlayMaxWidth, in: 400...1600, step: 50)
                    Text("\(Int(settings.overlayMaxWidth)) pt").monospacedDigit()
                }
                HStack {
                    Text("Tự ẩn sau")
                    Slider(value: $settings.overlayHideAfter, in: 0...15, step: 1)
                    Text(settings.overlayHideAfter == 0 ? "không" : "\(Int(settings.overlayHideAfter))s").monospacedDigit()
                }
                Button("Xem thử overlay") { pipeline.previewOverlay() }
            }
        }
        .formStyle(.grouped)
    }
}

struct GlossarySettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        GlossaryEditor(entries: $settings.globalGlossary, fileName: "thuat-ngu-chung.csv",
                       note: "Thuật ngữ chung, dùng cho mọi game. Thuật ngữ riêng của từng game nằm ở tab Thuật ngữ trong cửa sổ chính và được ưu tiên khi trùng. Để trống bản dịch = giữ nguyên.")
    }
}

/// Bảng thuật ngữ dùng chung cho thuật ngữ chung (Cài đặt) và thuật ngữ của từng game (tab Thuật ngữ).
struct GlossaryEditor: View {
    @Binding var entries: [GlossaryEntry]
    let fileName: String
    let note: String
    @State private var selection = Set<UUID>()
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note).font(.caption).foregroundStyle(.secondary)
            Table($entries, selection: $selection) {
                TableColumn("Thuật ngữ gốc") { $e in TextField("", text: $e.term) }
                TableColumn("Dịch thành") { $e in TextField("(giữ nguyên)", text: $e.translation) }
                TableColumn("Giữ nguyên") { $e in Toggle("", isOn: $e.keepAsIs).labelsHidden() }.width(70)
            }
            HStack {
                Button { entries.append(GlossaryEntry(term: "")) } label: { Image(systemName: "plus") }
                Button { entries.removeAll { selection.contains($0.id) }; selection = [] } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                Text("\(entries.count) thuật ngữ").font(.caption).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Nhập CSV…") { importCSV() }
                Button("Xuất CSV…") { exportCSV() }
            }
        }
        .padding(.top, 8)
    }

    /// CSV `thuật ngữ,bản dịch` (bản dịch trống = giữ nguyên). Bỏ dòng tiêu đề và dòng chú thích `#`;
    /// thuật ngữ đã có thì được cập nhật, không thêm trùng.
    private func importCSV() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard p.runModal() == .OK, let url = p.url, let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        var added = 0, updated = 0
        for line in s.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let parts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard let term = parts.first, !term.isEmpty else { continue }
            if ["term", "thuật ngữ", "thuat ngu"].contains(term.lowercased()) { continue }
            let tr = parts.count > 1 ? parts[1] : ""
            if let i = entries.firstIndex(where: { $0.term.lowercased() == term.lowercased() }) {
                entries[i].translation = tr; entries[i].keepAsIs = tr.isEmpty; updated += 1
            } else {
                entries.append(GlossaryEntry(term: term, translation: tr, keepAsIs: tr.isEmpty)); added += 1
            }
        }
        message = "Đã nhập: \(added) mới, \(updated) cập nhật"
    }

    private func exportCSV() {
        let p = NSSavePanel(); p.nameFieldStringValue = fileName; p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        let s = entries.map { "\($0.term),\($0.keepAsIs ? "" : $0.translation)" }.joined(separator: "\n")
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct ProfileSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mỗi game có nguồn hình, vùng phụ đề, thuật ngữ và tên nhân vật riêng.").font(.caption).foregroundStyle(.secondary)
            List(selection: Binding(get: { settings.activeProfileID }, set: { id in
                if let id, let p = settings.profiles.first(where: { $0.id == id }) { AppNav.shared.switchProfile(p) }
            })) {
                ForEach(settings.profiles) { p in
                    HStack {
                        Image(systemName: p.source.icon)
                        Text(p.name)
                        Spacer()
                        Text("\(p.source.label) · \(p.glossary.count) thuật ngữ · \(p.speakers.count) nhân vật").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(p.id)
                }
            }
            HStack {
                Button("Game mới…") { WindowManager.shared.showMain(); AppNav.shared.showNewProfile = true }
                Button("Đổi tên") {
                    var p = settings.activeProfile
                    p.name = RegionActions.askName(default: p.name)
                    settings.activeProfile = p
                }
                Button("Nhân bản") {
                    var p = settings.activeProfile
                    p.id = UUID(); p.name += " (bản sao)"
                    p.regions = p.regions.map { var r = $0; r.id = UUID(); return r }
                    settings.profiles.append(p); settings.activeProfileID = p.id
                }
                Button("Xoá", role: .destructive) {
                    guard settings.profiles.count > 1 else { return }
                    let id = settings.activeProfile.id
                    Pipeline.shared.stop()
                    settings.profiles.removeAll { $0.id == id }
                    settings.activeProfileID = settings.profiles.first?.id
                }
                .disabled(settings.profiles.count <= 1)
            }
        }
        .padding(.top, 8)
    }
}

struct HotkeySettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Bật phím tắt toàn cục", isOn: $settings.hotkeysEnabled)
                LabeledContent("Bắt đầu / Dừng") { KeyRecorderView(combo: $settings.hotkeyToggle) }
                LabeledContent("Dịch màn hình (thủ công)") { KeyRecorderView(combo: $settings.hotkeyAnalyze) }
                LabeledContent("Bật / tắt voice") { KeyRecorderView(combo: $settings.hotkeyVoice) }
                LabeledContent("Bật / tắt overlay") { KeyRecorderView(combo: $settings.hotkeyOverlay) }
            } footer: {
                Text("Bấm vào ô rồi nhấn tổ hợp mới (cần ⌘, ⌥ hoặc ⌃). Hoạt động cả khi game đang fullscreen, không cần quyền Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct WebSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var server = WebServer.shared

    var body: some View {
        Form {
            Section {
                Toggle("Cho iPhone / iPad trong cùng mạng Wi‑Fi xem phụ đề", isOn: $settings.webServerEnabled)
                TextField("Cổng", value: $settings.webServerPort, format: .number.grouping(.never))
                    .onSubmit { server.apply() }
                HStack {
                    Text("Trạng thái:")
                    switch server.status {
                    case .off: Text("đang tắt").foregroundStyle(.secondary)
                    case .starting: Text("đang mở…").foregroundStyle(.secondary)
                    case .running: Text("đang chạy · \(server.clientCount) máy đang xem").foregroundStyle(.green)
                    case .failed(let e): Text(e).foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("Trang web có ba phần: phụ đề thời gian thực, nhật ký phụ đề và nút Dịch toàn màn hình. Chỉ máy trong mạng nội bộ mở được; không có mật khẩu, nên tắt khi dùng Wi‑Fi công cộng.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .running(let port) = server.status {
                let urls = WebServer.urls(port: port)
                Section("Mở trên iPhone") {
                    if let first = urls.first, let qr = Self.qr(first) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                                .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Quét mã bằng Camera của iPhone, hoặc gõ một trong các địa chỉ:")
                                ForEach(urls, id: \.self) { u in
                                    Text(u).font(.body.monospaced()).textSelection(.enabled)
                                }
                                Text("Trong Safari: Chia sẻ → Thêm vào MH chính để mở toàn màn hình như một app. Muốn màn hình iPhone luôn sáng: Cài đặt → Màn hình & Độ sáng → Tự động khoá → Không.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Máy Mac chưa nối mạng nội bộ nào.").foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.webServerEnabled) { _, _ in server.apply() }
    }

    private static func qr(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
