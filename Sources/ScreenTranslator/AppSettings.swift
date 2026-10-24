import Foundation
import Combine
import CoreGraphics
import AVFoundation

/// Property wrapper lưu vào UserDefaults và bắn objectWillChange của ObservableObject chứa nó.
/// Giá trị đã giải mã được giữ trong bộ nhớ: danh sách game (kèm thuật ngữ) có thể vài trăm KB JSON và bị đọc
/// hàng chục lần mỗi lần giao diện vẽ lại, giải mã lại mỗi lần làm đổi game bị khựng vài giây.
@propertyWrapper
struct Stored<Value: Codable> {
    let key: String
    let defaultValue: Value
    private let cache = Cache()

    /// Hộp tham chiếu để cập nhật bộ nhớ đệm ngay trong getter; khoá vì cài đặt có thể được đọc từ luồng nền.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var value: Value?
    }

    init(wrappedValue: Value, _ key: String) { self.key = key; self.defaultValue = wrappedValue }

    static subscript<T: ObservableObject>(
        _enclosingInstance instance: T,
        wrapped _: ReferenceWritableKeyPath<T, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
    ) -> Value where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { instance[keyPath: storageKeyPath].read() }
        set {
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].write(newValue)
        }
    }

    @available(*, unavailable, message: "Chỉ dùng trong class ObservableObject")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    private func read() -> Value {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if ProcessInfo.processInfo.environment["NOCACHE_TMP"] == nil, let v = cache.value { return v }
        let v: Value
        if let data = AppPaths.defaults.data(forKey: key), let d = try? JSONDecoder().decode(Value.self, from: data) { v = d }
        else { v = defaultValue }
        cache.value = v
        return v
    }
    private func write(_ v: Value) {
        cache.lock.lock(); cache.value = v; cache.lock.unlock()
        if let data = try? JSONEncoder().encode(v) { AppPaths.defaults.set(data, forKey: key) }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Cờ runtime (không lưu): --mute tắt mọi âm thanh khi test.
    var forceMute = false
    /// Cờ runtime (không lưu): --quiet không hiện NSAlert (chỉ log) khi test tự động.
    var suppressAlerts = false
    /// Cờ runtime (không lưu): --no-overlay không hiện overlay khi test.
    var forceNoOverlay = false
    /// Cờ runtime (không lưu): --voice-engine edge|apple để test.
    var forceEngine: Speaker.Engine? = nil

    private init() {
        migrateIfNeeded()
        // v2.1: tốc độ đọc mặc định 0.5 quá chậm → nâng lên 0.6 một lần cho người đã lưu giá trị cũ.
        if !AppPaths.defaults.bool(forKey: "voiceRateBumped") {
            if abs(voiceRate - 0.5) < 0.001 { voiceRate = 0.6 }
            AppPaths.defaults.set(true, forKey: "voiceRateBumped")
        }
        // v2.2: ngưỡng lọc trùng 0.9 quá chặt với biến thể OCR → 0.8 (một lần).
        if !AppPaths.defaults.bool(forKey: "dedupLowered") {
            if dedupSimilarity > 0.85 { dedupSimilarity = 0.8 }
            AppPaths.defaults.set(true, forKey: "dedupLowered")
        }
        // v2.1: nếu đang chọn giọng compact mà máy có giọng Enhanced/Premium → về "Mặc định" (tự chọn giọng tốt nhất).
        if !AppPaths.defaults.bool(forKey: "voiceEnhancedMigrated") {
            if voiceIdentifier.contains("compact"),
               let best = Speaker.bestVoice(for: targetLanguage), best.quality != .default {
                voiceIdentifier = ""
            }
            AppPaths.defaults.set(true, forKey: "voiceEnhancedMigrated")
        }
        // v3.2: giọng "deepman3909" đổi cao độ nhiều giữa các câu (nghe như nhiều người) → chuyển sang Minh Quang nếu đã tải.
        if !AppPaths.defaults.bool(forKey: "localVoiceStable") {
            if localVoiceID == "deepman3909", VoiceCatalog.isInstalled("minhquang") { localVoiceID = "minhquang" }
            AppPaths.defaults.set(true, forKey: "localVoiceStable")
        }
        // v3.3: đọc hết từng câu theo thứ tự (không ngắt, không bỏ câu), nhanh thêm 10 % khi bị tồn.
        if !AppPaths.defaults.bool(forKey: "readAllMigrated") {
            interruptSpeech = false
            queueMode = .fifo
            AppPaths.defaults.set(true, forKey: "readAllMigrated")
        }
        // 10/2026: model Gemini 2.x không còn cho tài khoản mới → chuyển sang 3.5 flash lite (một lần).
        if !AppPaths.defaults.bool(forKey: "gemini3Migrated") {
            if geminiModel.hasPrefix("gemini-2") { geminiModel = "gemini-3.5-flash-lite" }
            AppPaths.defaults.set(true, forKey: "gemini3Migrated")
        }
        // v3.1: "Ưu tiên tốc độ" trở thành lựa chọn engine dịch.
        if !AppPaths.defaults.bool(forKey: "engineMigrated") {
            if legacyPreferSpeed { translationEngine = .appleTranslation }
            AppPaths.defaults.set(true, forKey: "engineMigrated")
        }
        // Tóm tắt có engine riêng: trước đây đi theo engine "Dịch màn hình" → giữ lựa chọn đó (một lần).
        if !AppPaths.defaults.bool(forKey: "summaryEngineMigrated") {
            switch screenEngine {
            case .gemini: summaryEngine = .gemini
            case .openAI: summaryEngine = .openAI
            case .appleIntelligence: summaryEngine = .appleIntelligence
            case .sameAsSubtitle, .appleTranslation, .anthropic, .custom, .shared: break
            }
            AppPaths.defaults.set(true, forKey: "summaryEngineMigrated")
        }
    }

    // MARK: Profile & vùng
    @Stored("profiles") var profiles: [Profile] = []
    @Stored("activeProfileID") var activeProfileID: UUID? = nil

    var activeProfile: Profile {
        get {
            if let id = activeProfileID, let p = profiles.first(where: { $0.id == id }) { return p }
            if let p = profiles.first { return p }
            return Profile(name: "Mặc định")
        }
        set {
            if let i = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[i] = newValue
            } else {
                profiles.append(newValue)
                activeProfileID = newValue.id
            }
        }
    }

    /// Vùng tạm (--test-region), chỉ tồn tại trong phiên, không lưu.
    var ephemeralRegions: [Region] = []

    var regions: [Region] {
        get { activeProfile.regions + ephemeralRegions }
        set { var p = activeProfile; p.regions = newValue.filter { r in !ephemeralRegions.contains { $0.id == r.id } }; activeProfile = p }
    }
    /// Nguồn hình của profile đang dùng.
    var source: ProfileSource {
        get { activeProfile.source }
        set { var p = activeProfile; p.source = newValue; activeProfile = p }
    }
    /// Chỉ các vùng thuộc nguồn hình đang chọn (PS5 nhúng hoặc app ngoài) mới tham gia dịch.
    private var sourceRegions: [Region] { regions.filter { $0.embedded == (source == .ps5) } }
    var subtitleRegions: [Region] { sourceRegions.filter { $0.kind == .subtitle } }
    var manualRegions: [Region] { Array(sourceRegions.filter { $0.kind == .manual }.prefix(1)) }
    /// App ngoài: khung toàn bộ màn hình game và khung phụ đề.
    var externalArea: Region? { regions.first { !$0.embedded && $0.kind == .manual } }
    var externalSubtitle: Region? { regions.first { !$0.embedded && $0.kind == .subtitle } }
    /// Phong cách dịch của game đang chọn (tab Thuật ngữ).
    var translationStyle: TranslationStyle {
        get { activeProfile.translationStyle }
        set { var p = activeProfile; p.translationStyle = newValue; activeProfile = p }
    }
    var translationNote: String {
        get { activeProfile.translationNote }
        set { var p = activeProfile; p.translationNote = newValue; activeProfile = p }
    }
    /// Phong cách thật sự dùng: "Tự động" thì đoán theo tên game.
    @MainActor var effectiveTranslationStyle: TranslationStyle {
        translationStyle == .auto ? TranslationStyle.resolveAuto(activeProfile.name) : translationStyle
    }
    /// Thuật ngữ riêng của game đang chọn (tab Thuật ngữ ở cửa sổ chính).
    var glossary: [GlossaryEntry] {
        get { activeProfile.glossary }
        set { var p = activeProfile; p.glossary = newValue; activeProfile = p }
    }
    /// Thuật ngữ chung cho mọi game (Cài đặt → Thuật ngữ).
    @Stored("globalGlossary") var globalGlossary: [GlossaryEntry] = []
    /// Thuật ngữ áp dụng khi dịch: của game trước, rồi thuật ngữ chung chưa bị game định nghĩa lại.
    var effectiveGlossary: [GlossaryEntry] {
        let own = glossary.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
        let ownTerms = Set(own.map { $0.term.lowercased().trimmingCharacters(in: .whitespaces) })
        return own + globalGlossary.filter { !ownTerms.contains($0.term.lowercased().trimmingCharacters(in: .whitespaces)) }
    }
    var showsSpeakerNames: Bool {
        get { activeProfile.showsSpeakerNames }
        set { var p = activeProfile; p.showsSpeakerNames = newValue; activeProfile = p }
    }
    /// Game hiện tên nhân vật ở dòng riêng phía trên câu thoại ("Footpad Leader" / "The Blessing of the Phoenix…?").
    var speakerAbove: Bool {
        get { activeProfile.speakerAbove }
        set { var p = activeProfile; p.speakerAbove = newValue; activeProfile = p }
    }
    var speakers: [String] {
        get { activeProfile.speakers }
        set { var p = activeProfile; p.speakers = newValue; activeProfile = p }
    }
    func learnSpeaker(_ name: String) {
        guard !speakers.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        speakers.append(name)
        Log.info("Học tên nhân vật: \(name)")
    }

    /// Chuyển dữ liệu v1 (key "regions") sang profile "Mặc định".
    private func migrateIfNeeded() {
        if profiles.isEmpty {
            var created: [Profile] = []
            // Dữ liệu v1 (key "regions") → giữ thành profile "Mặc định".
            if let data = AppPaths.defaults.data(forKey: "regions"),
               let old = try? JSONDecoder().decode([Region].self, from: data) {
                created.append(Profile(name: "Mặc định", regions: old))
                AppPaths.defaults.removeObject(forKey: "regions")
            }
            // Lần đầu cài: tạo sẵn một profile cho mỗi game mẫu đóng kèm app (thuật ngữ, phong cách dịch…).
            for g in GameCatalog.bundled() where !created.contains(where: { $0.name.lowercased() == g.name.lowercased() }) {
                created.append(g.makeProfile())
            }
            if created.isEmpty { created = [Profile(name: "Mặc định")] }
            Log.info("Tạo \(created.count) profile lần đầu: \(created.map(\.name).joined(separator: ", "))")
            profiles = created
            activeProfileID = created.first?.id
        } else if activeProfileID == nil || !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles.first?.id
        }
    }

    // MARK: Capture
    @Stored("fps") var fps: Int = 4
    /// Độ phân giải khi quét phụ đề (pixel/point; vùng PS5: so với ảnh gốc của luồng). Phụ đề chữ to nên 0.5–0.75× vẫn đọc được.
    @Stored("captureScale") var captureScale: Double = 2.0
    /// Độ phân giải riêng cho Dịch màn hình (chữ menu, nhật ký nhỏ hơn phụ đề nên cần nét hơn).
    @Stored("screenCaptureScale") var screenCaptureScale: Double = 2.0
    @Stored("stableDelayMs") var stableDelayMs: Double = 250
    @Stored("diffThreshold") var diffThreshold: Double = 4.0

    // MARK: OCR
    @Stored("minTextHeight") var minTextHeight: Double = 0.0
    @Stored("ocrAccurate") var ocrAccurate: Bool = true
    @Stored("dedupSimilarity") var dedupSimilarity: Double = 0.8
    @Stored("adaptiveCapture") var adaptiveCapture: Bool = true   // nghỉ soi sau mỗi câu, dài theo độ dài câu
    @Stored("skipInterjections") var skipInterjections: Bool = true   // bỏ câu chỉ có từ cảm thán (hmm, haha, huh…)
    @Stored("centerOnlySubtitles") var centerOnlySubtitles: Bool = true   // chỉ nhận chữ canh giữa khung phụ đề (bỏ nút bấm ở mép)
    @Stored("skipSimpleLines") var skipSimpleLines: Bool = true   // bỏ câu ngắn toàn từ cơ bản / tên nhân vật (người chơi tự hiểu)
    @Stored("skipUIText") var skipUIText: Bool = true   // bỏ qua chữ giao diện (menu/cài đặt), chỉ đọc khi giống phụ đề

    // MARK: Dịch
    /// Email người dùng tự nhập (gửi kèm lên server duyệt máy để chủ app biết máy của ai).
    @Stored("userEmail") var userEmail: String = ""
    /// Tên đăng nhập tài khoản sao lưu (token nằm trong SecretStore "account-token"). Không đi theo bản sao lưu.
    @Stored("accountUser") var accountUser: String = ""
    @Stored("targetLanguage") var targetLanguage: String = "vi"
    @Stored("geminiModel") var geminiModel: String = "gemini-3.5-flash-lite"
    @Stored("geminiBaseURL") var geminiBaseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    @Stored("rpm") var rpm: Int = 10
    @Stored("rpd") var rpd: Int = 500
    @Stored("geminiTimeout") var geminiTimeout: Double = 4.0
    @Stored("preferSpeed") private var legacyPreferSpeed: Bool = false
    @Stored("translationEngine") var translationEngine: TranslationEngine = .auto
    @Stored("aiTimeout") var aiTimeout: Double = 3.0
    /// Chỉ dùng Apple Translation, không gọi Gemini / Apple Intelligence.
    var preferSpeed: Bool { engine == .appleTranslation }
    /// Engine đang hiệu lực (cờ --translate-engine ghi đè khi test, không lưu).
    var engine: TranslationEngine { forceTranslationEngine ?? translationEngine }
    var forceTranslationEngine: TranslationEngine? = nil
    @Stored("contextPairs") var contextPairs: Int = 5
    @Stored("queueMode") var queueMode: QueueMode = .latestWins

    // MARK: Phân tích màn hình (thủ công)
    @Stored("screenEngine") var screenEngine: ScreenEngine = .sameAsSubtitle
    /// Engine thật sự dùng cho "Dịch màn hình": chọn "Giống engine dịch phụ đề" thì suy từ engine phụ đề.
    var effectiveScreenEngine: ScreenEngine {
        guard screenEngine == .sameAsSubtitle else { return screenEngine }
        switch engine {
        case .auto: return .gemini
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .custom: return .custom
        case .shared: return .shared
        case .appleIntelligence: return .appleIntelligence
        case .appleTranslation: return .appleTranslation
        }
    }
    @Stored("analyzeSpeakSummary") var analyzeSpeakSummary: Bool = false
    @Stored("analyzeTimeout") var analyzeTimeout: Double = 20.0

    // MARK: Tóm tắt & cốt truyện
    @Stored("summaryEngine") var summaryEngine: SummaryEngine = .sameAsSubtitle
    /// Engine thật sự viết tóm tắt / cốt truyện. Engine phụ đề không tóm tắt được (Apple Translation) thì dùng Gemini.
    var effectiveSummaryEngine: SummaryEngine {
        guard summaryEngine == .sameAsSubtitle else { return summaryEngine }
        switch engine {
        case .auto, .appleTranslation: return .gemini
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .custom: return .custom
        case .shared: return .shared
        case .appleIntelligence: return .appleIntelligence
        }
    }
    /// Tự viết cốt truyện game từ phụ đề (nút trên thanh đầu cửa sổ chính; xem ở tab Cốt truyện).
    @Stored("storyEnabled") var storyEnabled: Bool = false
    @Stored("storyIntervalMin") var storyIntervalMin: Int = 10
    /// Cờ runtime (không lưu): --story-interval <giây> bật cốt truyện với chu kỳ ngắn để test.
    var forceStoryInterval: TimeInterval? = nil
    var storyOn: Bool { storyEnabled || forceStoryInterval != nil }

    // MARK: Voice
    @Stored("voiceEnabled") var voiceEnabled: Bool = false
    @Stored("voiceIdentifier") var voiceIdentifier: String = ""
    @Stored("voiceRate") var voiceRate: Double = 0.6
    @Stored("interruptSpeech") var interruptSpeech: Bool = true
    @Stored("voiceEngine") var voiceEngine: Speaker.Engine = .apple
    @Stored("edgeVoice") var edgeVoice: String = ""
    @Stored("edgeRatePercent") var edgeRatePercent: Double = 40
    @Stored("ps5Resolution") var ps5Resolution: Int = 4      // 3 = 720p, 4 = 1080p
    @Stored("ps5FPS") var ps5FPS: Int = 30
    @Stored("ps5AutoTranslate") var ps5AutoTranslate: Bool = true
    /// Mất kết nối PS5 khi đang chơi: tự kết nối lại (ở lại màn hình chính) thay vì quay về màn hình Bắt đầu.
    @Stored("ps5AutoReconnect") var ps5AutoReconnect: Bool = true
    @Stored("ps5ReconnectAttempts") var ps5ReconnectAttempts: Int = 10
    @Stored("catchUpPercent") var catchUpPercent: Double = 10
    @Stored("localVoiceID") var localVoiceID: String = "minhquang"
    @Stored("localSpeed") var localSpeed: Double = 1.15
    @Stored("voiceSkipSpeaker") var voiceSkipSpeaker: Bool = true
    @Stored("voiceAdaptiveRate") var voiceAdaptiveRate: Bool = true
    /// Phát giọng đọc trên TV / điện thoại đang mở trang hoặc app xem phụ đề (qua máy chủ web) thay vì loa máy này.
    @Stored("voiceOnRemote") var voiceOnRemote: Bool = false

    // MARK: Overlay
    @Stored("overlayEnabled") var overlayEnabled: Bool = true
    @Stored("overlayHideAfter") var overlayHideAfter: Double = 6.0
    @Stored("overlayFontSize") var overlayFontSize: Double = 22.0
    @Stored("overlayPosition") var overlayPosition: OverlayPosition = .belowRegion
    @Stored("overlayOpacity") var overlayOpacity: Double = 0.7
    @Stored("overlayShowSource") var overlayShowSource: Bool = true
    @Stored("overlayMaxWidth") var overlayMaxWidth: Double = 900

    // MARK: Web (xem trên iPhone / iPad)
    @Stored("webServerEnabled") var webServerEnabled: Bool = true
    @Stored("webServerPort") var webServerPort: Int = 8787
    /// IP của TV Samsung lần cài app gần nhất (cửa sổ "Cài app lên TV").
    @Stored("tvInstallIp") var tvInstallIp: String = ""
    /// Cờ runtime (không lưu): --no-web tắt máy chủ web, --web-port N đổi cổng khi test.
    var forceNoWeb = false
    var forceWebPort: Int? = nil
    var webServerOn: Bool { webServerEnabled && !forceNoWeb }
    var webPort: Int { forceWebPort ?? webServerPort }

    // MARK: Phím tắt
    @Stored("hotkeyToggle") var hotkeyToggle: KeyCombo = KeyCombo(keyCode: 1, modifiers: KeyCombo.cmd | KeyCombo.option)    // ⌥⌘S
    @Stored("hotkeyAnalyze") var hotkeyAnalyze: KeyCombo = KeyCombo(keyCode: 17, modifiers: KeyCombo.cmd | KeyCombo.option)  // ⌥⌘T
    @Stored("hotkeyVoice") var hotkeyVoice: KeyCombo = KeyCombo(keyCode: 9, modifiers: KeyCombo.cmd | KeyCombo.option)      // ⌥⌘V
    @Stored("hotkeyOverlay") var hotkeyOverlay: KeyCombo = KeyCombo(keyCode: 31, modifiers: KeyCombo.cmd | KeyCombo.option)  // ⌥⌘O
    @Stored("hotkeysEnabled") var hotkeysEnabled: Bool = true

    // MARK: AI (Cài đặt → AI: key và model của từng nhà cung cấp)
    @Stored("openAIModel") var openAIModel: String = "gpt-5.4-nano"
    @Stored("openAITimeout") var openAITimeout: Double = 4.0
    var openAIKey: String {
        get { SecretStore.get("openai-api-key") ?? "" }
        set { objectWillChange.send(); SecretStore.set(newValue, name: "openai-api-key") }
    }

    @Stored("anthropicModel") var anthropicModel: String = "claude-haiku-5-5"
    @Stored("anthropicTimeout") var anthropicTimeout: Double = 5.0
    var anthropicKey: String {
        get { SecretStore.get("anthropic-api-key") ?? "" }
        set { objectWillChange.send(); SecretStore.set(newValue, name: "anthropic-api-key") }
    }

    /// API tuỳ chỉnh: máy chủ bất kỳ nói giao thức Chat Completions của OpenAI (OpenRouter, Ollama, LM Studio…).
    @Stored("customBaseURL") var customBaseURL: String = ""
    @Stored("customModel") var customModel: String = ""
    @Stored("customTimeout") var customTimeout: Double = 6.0
    var customKey: String {
        get { SecretStore.get("custom-api-key") ?? "" }
        set { objectWillChange.send(); SecretStore.set(newValue, name: "custom-api-key") }
    }
    /// Máy chủ chạy trên máy (Ollama…) không cần key, nên chỉ cần địa chỉ và model.
    var customReady: Bool { !customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty && !customModel.isEmpty }

    /// AI share: token do chủ server cấp (dán ở Cài đặt → AI). Key thật nằm trên server; app chỉ gửi token qua proxy
    /// và chỉ dùng được các model trong `aiShare.models` (server cũng chặn model khác).
    struct AIShareInfo: Codable, Equatable {
        var label: String
        /// Nhà cung cấp phía server: openai | anthropic | gemini | custom.
        var provider: String
        var models: [String]
        /// Server báo token đã bị thu hồi / không hợp lệ ở lần kiểm tra gần nhất.
        var revoked: Bool = false
    }
    @Stored("aiShare") var aiShare: AIShareInfo? = nil
    var aiShareToken: String {
        get { SecretStore.get("ai-share-token") ?? "" }
        set { objectWillChange.send(); SecretStore.set(newValue, name: "ai-share-token") }
    }
    /// Cờ runtime (không lưu): --server <url> dùng server khác cho AI share và game mẫu (test với server chạy trên máy).
    var forceServer: String? = nil

    /// Model riêng cho từng việc, chọn ở Cài đặt → Dịch. Khoá "<việc>.<nhà cung cấp>" (ví dụ "summary.anthropic");
    /// không có hoặc trống = dùng model mặc định của nhà cung cấp đó ở Cài đặt → AI.
    @Stored("taskModels") var taskModels: [String: String] = [:]
    func taskModel(_ task: AITask, _ provider: String) -> String? {
        guard let m = taskModels["\(task.rawValue).\(provider)"], !m.isEmpty else { return nil }
        // AI share chỉ dùng được model đã share (admin có thể bớt model sau khi đã chọn).
        if provider == "shared", aiShare?.models.contains(m) != true { return nil }
        return m
    }
    /// Model mặc định của một nhà cung cấp (gemini / openAI / anthropic / custom).
    func defaultModel(_ provider: String) -> String {
        switch provider {
        case "gemini": return geminiModel
        case "openAI": return openAIModel
        case "anthropic": return anthropicModel
        case "custom": return customModel
        case "shared": return aiShare?.models.first ?? ""
        default: return ""
        }
    }

    /// Chữ ký (băm) của các cặp nhà cung cấp + model + key đã "Test key" thành công; không lưu key thô.
    /// Engine dịch qua mạng chỉ được Bắt đầu khi cặp đang dùng có trong danh sách này (xem Readiness).
    @Stored("aiVerified") var aiVerified: [String] = []
    /// Cờ runtime (không lưu): --skip-readiness bỏ qua kiểm tra cài đặt dịch khi test tự động.
    var forceReady = false

    /// Danh sách model đã tải về bằng nút "Tải model" của từng nhà cung cấp (giữ lại giữa các lần mở app).
    @Stored("aiModelLists") var aiModelLists: [String: [String]] = [:]

    /// Gemini miễn phí nên cho lưu nhiều key (mỗi dòng một key trong file bí mật) và dùng xoay vòng.
    var geminiAPIKeys: [String] {
        get {
            (SecretStore.get("gemini-api-key") ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        set {
            objectWillChange.send()
            var seen = Set<String>()
            SecretStore.set(newValue.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n"), name: "gemini-api-key")
        }
    }
    /// Key đầu tiên (đặt = thay toàn bộ danh sách bằng một key; dùng cho cờ --gemini-key).
    var geminiAPIKey: String {
        get { geminiAPIKeys.first ?? "" }
        set { geminiAPIKeys = newValue.isEmpty ? [] : [newValue] }
    }
    /// Quota mỗi phút / mỗi ngày tính gộp trên mọi key.
    var geminiRPM: Int { rpm * max(1, geminiAPIKeys.count) }
    var geminiRPD: Int { rpd * max(1, geminiAPIKeys.count) }

    var target: TargetLanguage { TargetLanguage.find(targetLanguage) }
    var voiceOn: Bool { voiceEnabled }
    var overlayOn: Bool { overlayEnabled && !forceNoOverlay }
}
