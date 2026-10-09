import Foundation
import Combine
import CoreGraphics
import AVFoundation

/// Property wrapper lưu vào UserDefaults và bắn objectWillChange của ObservableObject chứa nó.
@propertyWrapper
struct Stored<Value: Codable> {
    let key: String
    let defaultValue: Value

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
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(Value.self, from: data) else { return defaultValue }
        return v
    }
    private func write(_ v: Value) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: key) }
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
        if !UserDefaults.standard.bool(forKey: "voiceRateBumped") {
            if abs(voiceRate - 0.5) < 0.001 { voiceRate = 0.6 }
            UserDefaults.standard.set(true, forKey: "voiceRateBumped")
        }
        // v2.2: ngưỡng lọc trùng 0.9 quá chặt với biến thể OCR → 0.8 (một lần).
        if !UserDefaults.standard.bool(forKey: "dedupLowered") {
            if dedupSimilarity > 0.85 { dedupSimilarity = 0.8 }
            UserDefaults.standard.set(true, forKey: "dedupLowered")
        }
        // v2.1: nếu đang chọn giọng compact mà máy có giọng Enhanced/Premium → về "Mặc định" (tự chọn giọng tốt nhất).
        if !UserDefaults.standard.bool(forKey: "voiceEnhancedMigrated") {
            if voiceIdentifier.contains("compact"),
               let best = Speaker.bestVoice(for: targetLanguage), best.quality != .default {
                voiceIdentifier = ""
            }
            UserDefaults.standard.set(true, forKey: "voiceEnhancedMigrated")
        }
        // v3.2: giọng "deepman3909" đổi cao độ nhiều giữa các câu (nghe như nhiều người) → chuyển sang Minh Quang nếu đã tải.
        if !UserDefaults.standard.bool(forKey: "localVoiceStable") {
            if localVoiceID == "deepman3909", VoiceCatalog.isInstalled("minhquang") { localVoiceID = "minhquang" }
            UserDefaults.standard.set(true, forKey: "localVoiceStable")
        }
        // v3.3: đọc hết từng câu theo thứ tự (không ngắt, không bỏ câu), nhanh thêm 10 % khi bị tồn.
        if !UserDefaults.standard.bool(forKey: "readAllMigrated") {
            interruptSpeech = false
            queueMode = .fifo
            UserDefaults.standard.set(true, forKey: "readAllMigrated")
        }
        // 10/2026: model Gemini 2.x không còn cho tài khoản mới → chuyển sang 3.5 flash lite (một lần).
        if !UserDefaults.standard.bool(forKey: "gemini3Migrated") {
            if geminiModel.hasPrefix("gemini-2") { geminiModel = "gemini-3.5-flash-lite" }
            UserDefaults.standard.set(true, forKey: "gemini3Migrated")
        }
        // v3.1: "Ưu tiên tốc độ" trở thành lựa chọn engine dịch.
        if !UserDefaults.standard.bool(forKey: "engineMigrated") {
            if legacyPreferSpeed { translationEngine = .appleTranslation }
            UserDefaults.standard.set(true, forKey: "engineMigrated")
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
    var effectiveTranslationStyle: TranslationStyle {
        translationStyle == .auto ? TranslationStyle.guess(activeProfile.name) : translationStyle
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
            var p = Profile(name: "Mặc định")
            if let data = UserDefaults.standard.data(forKey: "regions"),
               let old = try? JSONDecoder().decode([Region].self, from: data) {
                p.regions = old
                UserDefaults.standard.removeObject(forKey: "regions")
            }
            profiles = [p]
            activeProfileID = p.id
        } else if activeProfileID == nil || !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles.first?.id
        }
    }

    // MARK: Capture
    @Stored("fps") var fps: Int = 4
    @Stored("captureScale") var captureScale: Double = 2.0
    @Stored("stableDelayMs") var stableDelayMs: Double = 250
    @Stored("diffThreshold") var diffThreshold: Double = 4.0

    // MARK: OCR
    @Stored("minTextHeight") var minTextHeight: Double = 0.0
    @Stored("ocrAccurate") var ocrAccurate: Bool = true
    @Stored("dedupSimilarity") var dedupSimilarity: Double = 0.8
    @Stored("adaptiveCapture") var adaptiveCapture: Bool = true   // nghỉ soi sau mỗi câu, dài theo độ dài câu
    @Stored("skipInterjections") var skipInterjections: Bool = true   // bỏ câu chỉ có từ cảm thán (hmm, haha, huh…)
    @Stored("centerOnlySubtitles") var centerOnlySubtitles: Bool = true   // chỉ nhận chữ canh giữa khung phụ đề (bỏ nút bấm ở mép)
    @Stored("skipSimpleLines") var skipSimpleLines: Bool = true   // bỏ câu 1–2 từ và câu toàn từ cơ bản (người chơi tự hiểu)
    @Stored("skipUIText") var skipUIText: Bool = true   // bỏ qua chữ giao diện (menu/cài đặt), chỉ đọc khi giống phụ đề

    // MARK: Dịch
    /// Email người dùng tự nhập (gửi kèm lên server duyệt máy để chủ app biết máy của ai).
    @Stored("userEmail") var userEmail: String = ""
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
    @Stored("screenEngine") var screenEngine: ScreenEngine = .gemini
    @Stored("analyzeSpeakSummary") var analyzeSpeakSummary: Bool = false
    @Stored("analyzeTimeout") var analyzeTimeout: Double = 20.0

    // MARK: Voice
    @Stored("voiceEnabled") var voiceEnabled: Bool = true
    @Stored("voiceIdentifier") var voiceIdentifier: String = ""
    @Stored("voiceRate") var voiceRate: Double = 0.6
    @Stored("interruptSpeech") var interruptSpeech: Bool = true
    @Stored("voiceEngine") var voiceEngine: Speaker.Engine = .apple
    @Stored("edgeVoice") var edgeVoice: String = ""
    @Stored("edgeRatePercent") var edgeRatePercent: Double = 40
    @Stored("ps5Resolution") var ps5Resolution: Int = 4      // 3 = 720p, 4 = 1080p
    @Stored("ps5FPS") var ps5FPS: Int = 30
    @Stored("ps5AutoTranslate") var ps5AutoTranslate: Bool = true
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

    // MARK: OpenAI (trả phí)
    @Stored("openAIModel") var openAIModel: String = "gpt-5.4-nano"
    @Stored("openAITimeout") var openAITimeout: Double = 4.0
    var openAIKey: String {
        get { SecretStore.get("openai-api-key") ?? "" }
        set { objectWillChange.send(); SecretStore.set(newValue, name: "openai-api-key") }
    }

    var geminiAPIKey: String {
        get { SecretStore.get("gemini-api-key") ?? "" }
        set { objectWillChange.send(); SecretStore.set(newValue, name: "gemini-api-key") }
    }

    var target: TargetLanguage { TargetLanguage.find(targetLanguage) }
    var voiceOn: Bool { voiceEnabled }
    var overlayOn: Bool { overlayEnabled && !forceNoOverlay }
}
