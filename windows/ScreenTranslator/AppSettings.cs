using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;

namespace ScreenTranslator;

/// Cài đặt của app. Mỗi khoá lưu dạng JSON trong %APPDATA%\ScreenTranslator\settings.json (thay UserDefaults).
/// Giá trị đọc ra luôn là bản sao (như struct của Swift): sửa xong phải gán lại để lưu.
public sealed class AppSettings : INotifyPropertyChanged
{
    static readonly Lazy<AppSettings> lazy = new(() => new AppSettings());
    public static AppSettings shared => lazy.Value;
    public event PropertyChangedEventHandler? PropertyChanged;
    /// Bắn khi bất kỳ cài đặt nào đổi (tên khoá).
    public event Action<string>? Changed;

    static readonly string FilePath = AppPaths.File("settings.json");
    readonly object lk = new();
    readonly JsonObject store;
    Timer? saveTimer;
    public static readonly JsonSerializerOptions Json = new() { WriteIndented = false };

    // Cờ runtime (không lưu)
    /// --mute tắt mọi âm thanh khi test.
    public bool forceMute;
    /// --quiet không hiện hộp thoại (chỉ log) khi test tự động.
    public bool suppressAlerts;
    /// --no-overlay không hiện overlay khi test.
    public bool forceNoOverlay;
    /// --voice-engine để test.
    public VoiceEngine? forceEngine;
    /// --translate-engine ghi đè engine khi test.
    public TranslationEngine? forceTranslationEngine;
    /// Cờ runtime (không lưu): --skip-readiness bỏ qua kiểm tra cài đặt dịch khi test tự động.
    public bool forceReady;
    /// --no-web / --web-port.
    public bool forceNoWeb;
    public int? forceWebPort;
    /// --story-interval <giây>: bật cốt truyện với chu kỳ ngắn để test.
    public double? forceStoryInterval;
    /// Vùng tạm (--test-region), chỉ tồn tại trong phiên, không lưu.
    public List<Region> ephemeralRegions = new();

    AppSettings()
    {
        JsonObject? loaded = null;
        try { if (File.Exists(FilePath)) loaded = JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject; }
        catch (Exception e) { Log.Error($"settings.json lỗi, dùng mặc định: {e.Message}"); }
        store = loaded ?? new JsonObject();
        MigrateIfNeeded();
        // v3.3: đọc hết từng câu theo thứ tự (không ngắt, không bỏ câu), nhanh thêm 10 % khi bị tồn.
        if (!GetFlag("readAllMigrated"))
        {
            interruptSpeech = false;
            queueMode = QueueMode.fifo;
            SetFlag("readAllMigrated");
        }
        // 10/2026: model Gemini 2.x không còn cho tài khoản mới → chuyển sang 3.5 flash lite (một lần).
        if (!GetFlag("gemini3Migrated"))
        {
            if (geminiModel.StartsWith("gemini-2")) geminiModel = "gemini-3.5-flash-lite";
            SetFlag("gemini3Migrated");
        }
        // Tóm tắt có engine riêng: trước đây đi theo engine "Dịch màn hình" → giữ lựa chọn đó (một lần).
        if (!GetFlag("summaryEngineMigrated"))
        {
            if (screenEngine == ScreenEngine.gemini) summaryEngine = SummaryEngine.gemini;
            else if (screenEngine == ScreenEngine.openAI) summaryEngine = SummaryEngine.openAI;
            SetFlag("summaryEngineMigrated");
        }
    }

    // MARK: lưu trữ

    public T Get<T>(string key, T def)
    {
        lock (lk)
        {
            if (!store.TryGetPropertyValue(key, out var node) || node == null) return def;
            try { return node.Deserialize<T>(Json) ?? def; } catch { return def; }
        }
    }

    public void Set<T>(string key, T value, [CallerMemberName] string? prop = null)
    {
        lock (lk) { store[key] = JsonSerializer.SerializeToNode(value, Json); }
        ScheduleSave();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop ?? key));
        Changed?.Invoke(prop ?? key);
    }

    public bool GetFlag(string key) => Get(key, false);
    public void SetFlag(string key, bool v = true) => Set(key, v, key);
    public void Remove(string key) { lock (lk) store.Remove(key); ScheduleSave(); }

    void ScheduleSave()
    {
        saveTimer?.Dispose();
        saveTimer = new Timer(_ => SaveNow(), null, 300, Timeout.Infinite);
    }

    public void SaveNow()
    {
        try
        {
            string text;
            lock (lk) text = store.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, text);
            File.Move(tmp, FilePath, true);
        }
        catch (Exception e) { Log.Error($"Lưu settings lỗi: {e.Message}"); }
    }

    /// Báo cho UI cập nhật lại mọi binding (sau khi đổi profile…).
    public void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));

    // MARK: Profile & vùng
    /// Danh sách game đã giải mã, giữ trong bộ nhớ: JSON của nó có thể vài trăm KB (thuật ngữ của mọi game) và bị đọc
    /// rất nhiều lần mỗi khi giao diện vẽ lại; giải mã lại mỗi lần làm đổi game bị khựng vài giây.
    /// Ra ngoài luôn là bản sao (code gọi có thể sửa trực tiếp đối tượng rồi mới gán lại).
    List<Profile>? profilesCache;
    List<Profile> ProfilesCache { get { lock (lk) return profilesCache ??= Get("profiles", new List<Profile>()); } }
    public List<Profile> profiles
    {
        get => ProfilesCache.Select(p => p.Clone()).ToList();
        set { lock (lk) profilesCache = value.Select(p => p.Clone()).ToList(); Set("profiles", value); }
    }
    public Guid? activeProfileID { get => Get<Guid?>("activeProfileID", null); set => Set("activeProfileID", value); }

    public Profile activeProfile
    {
        get
        {
            var ps = ProfilesCache;
            var id = activeProfileID;
            return (ps.FirstOrDefault(p => p.id == id) ?? ps.FirstOrDefault())?.Clone() ?? new Profile { name = "Mặc định" };
        }
        set
        {
            var ps = profiles;
            int i = ps.FindIndex(p => p.id == value.id);
            if (i >= 0) { ps[i] = value; profiles = ps; }
            else { ps.Add(value); profiles = ps; activeProfileID = value.id; }
            OnPropertyChanged(nameof(activeProfile));
        }
    }

    void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public List<Region> regions
    {
        get => activeProfile.regions.Concat(ephemeralRegions.Select(r => r.Clone())).ToList();
        set
        {
            var p = activeProfile;
            p.regions = value.Where(r => !ephemeralRegions.Any(e => e.id == r.id)).ToList();
            activeProfile = p;
            OnPropertyChanged(nameof(regions));
        }
    }
    /// Nguồn hình của profile đang dùng.
    public ProfileSource source
    {
        get => activeProfile.source;
        set { var p = activeProfile; p.source = value; activeProfile = p; OnPropertyChanged(nameof(source)); }
    }
    /// Chỉ các vùng thuộc nguồn hình đang chọn (PS5 nhúng hoặc app ngoài) mới tham gia dịch.
    List<Region> sourceRegions { get { var s = source; return regions.Where(r => r.embedded == (s == ProfileSource.ps5)).ToList(); } }
    public List<Region> subtitleRegions => sourceRegions.Where(r => r.kind == RegionKind.subtitle).ToList();
    public List<Region> manualRegions => sourceRegions.Where(r => r.kind == RegionKind.manual).Take(1).ToList();
    /// App ngoài: khung toàn bộ màn hình game và khung phụ đề.
    public Region? externalArea => regions.FirstOrDefault(r => !r.embedded && r.kind == RegionKind.manual);
    public Region? externalSubtitle => regions.FirstOrDefault(r => !r.embedded && r.kind == RegionKind.subtitle);
    /// Phong cách dịch của game đang chọn (tab Thuật ngữ).
    public TranslationStyle translationStyle
    {
        get => activeProfile.translationStyle;
        set { var p = activeProfile; p.translationStyle = value; activeProfile = p; OnPropertyChanged(nameof(translationStyle)); }
    }
    public string translationNote
    {
        get => activeProfile.translationNote;
        set { var p = activeProfile; p.translationNote = value; activeProfile = p; OnPropertyChanged(nameof(translationNote)); }
    }
    /// Phong cách thật sự dùng: "Tự động" thì đoán theo tên game.
    public TranslationStyle effectiveTranslationStyle =>
        translationStyle == TranslationStyle.auto ? TranslationStyles.Guess(activeProfile.name) : translationStyle;
    /// Thuật ngữ riêng của game đang chọn (tab Thuật ngữ ở cửa sổ chính).
    public List<GlossaryEntry> glossary
    {
        get => activeProfile.glossary;
        set { var p = activeProfile; p.glossary = value; activeProfile = p; OnPropertyChanged(nameof(glossary)); }
    }
    /// Thuật ngữ chung cho mọi game (Cài đặt → Thuật ngữ chung).
    public List<GlossaryEntry> globalGlossary { get => Get("globalGlossary", new List<GlossaryEntry>()); set => Set("globalGlossary", value); }
    /// Thuật ngữ áp dụng khi dịch: của game trước, rồi thuật ngữ chung chưa bị game định nghĩa lại.
    public List<GlossaryEntry> effectiveGlossary
    {
        get
        {
            var own = glossary.Where(g => g.term.Trim().Length > 0).ToList();
            var ownTerms = own.Select(g => g.term.Trim().ToLowerInvariant()).ToHashSet();
            return own.Concat(globalGlossary.Where(g => !ownTerms.Contains(g.term.Trim().ToLowerInvariant()))).ToList();
        }
    }
    /// Game hiện tên nhân vật ở dòng riêng phía trên câu thoại ("Footpad Leader" / "The Blessing of the Phoenix…?").
    public bool speakerAbove
    {
        get => activeProfile.speakerAbove;
        set { var p = activeProfile; p.speakerAbove = value; activeProfile = p; OnPropertyChanged(nameof(speakerAbove)); }
    }
    public bool showsSpeakerNames
    {
        get => activeProfile.showsSpeakerNames;
        set { var p = activeProfile; p.showsSpeakerNames = value; activeProfile = p; OnPropertyChanged(nameof(showsSpeakerNames)); }
    }
    public List<string> speakers
    {
        get => activeProfile.speakers;
        set { var p = activeProfile; p.speakers = value; activeProfile = p; OnPropertyChanged(nameof(speakers)); }
    }
    public void LearnSpeaker(string name)
    {
        var s = speakers;
        if (s.Any(x => x.ToLowerInvariant() == name.ToLowerInvariant())) return;
        s.Add(name);
        speakers = s;
        Log.Info($"Học tên nhân vật: {name}");
    }

    /// Lần đầu chạy: tạo profile "Mặc định".
    void MigrateIfNeeded()
    {
        var ps = profiles;
        if (ps.Count == 0)
        {
            // Lần đầu cài: tạo sẵn một profile cho mỗi game thông dụng (thuật ngữ đóng kèm app).
            var created = new List<Profile>();
            foreach (var g in GameGlossaries.Bundled())
                if (!created.Any(p => p.name.Equals(g.name, StringComparison.OrdinalIgnoreCase)))
                    created.Add(new Profile { name = g.name, glossary = g.entries });
            if (created.Count == 0) created.Add(new Profile { name = "Mặc định" });
            Log.Info($"Tạo {created.Count} profile lần đầu: {string.Join(", ", created.Select(p => p.name))}");
            profiles = created;
            activeProfileID = created[0].id;
        }
        else if (activeProfileID == null || !ps.Any(p => p.id == activeProfileID))
            activeProfileID = ps[0].id;
    }

    // MARK: Capture
    public int fps { get => Get("fps", 4); set => Set("fps", value); }
    /// Đổi cỡ ảnh phụ đề trước khi OCR (Windows chụp theo pixel thật; 1 = giữ nguyên, 0.5–0.75 nhanh hơn với phụ đề chữ to,
    /// 1.5–2 giúp đọc chữ nhỏ). Vùng PS5: so với ảnh gốc của luồng.
    public double captureScale { get => Get("winCaptureScale", 1.0); set => Set("winCaptureScale", value); }
    /// Phóng to riêng cho Dịch màn hình (chữ menu, nhật ký nhỏ hơn phụ đề nên cần nét hơn).
    public double screenCaptureScale { get => Get("winScreenCaptureScale", 2.0); set => Set("winScreenCaptureScale", value); }
    public double stableDelayMs { get => Get("stableDelayMs", 250.0); set => Set("stableDelayMs", value); }
    public double diffThreshold { get => Get("diffThreshold", 4.0); set => Set("diffThreshold", value); }

    // MARK: OCR
    public double minTextHeight { get => Get("minTextHeight", 0.0); set => Set("minTextHeight", value); }
    public double dedupSimilarity { get => Get("dedupSimilarity", 0.8); set => Set("dedupSimilarity", value); }
    /// Nghỉ soi sau mỗi câu, dài theo độ dài câu.
    public bool adaptiveCapture { get => Get("adaptiveCapture", true); set => Set("adaptiveCapture", value); }
    /// Bỏ câu chỉ có từ cảm thán (hmm, haha, huh…).
    public bool skipInterjections { get => Get("skipInterjections", true); set => Set("skipInterjections", value); }
    /// Chỉ nhận chữ canh giữa khung phụ đề (bỏ nút bấm ở mép).
    public bool centerOnlySubtitles { get => Get("centerOnlySubtitles", true); set => Set("centerOnlySubtitles", value); }
    /// Bỏ câu 1–2 từ và câu toàn từ cơ bản (người chơi tự hiểu).
    public bool skipSimpleLines { get => Get("skipSimpleLines", true); set => Set("skipSimpleLines", value); }
    /// Bỏ qua chữ giao diện (menu/cài đặt), chỉ đọc khi giống phụ đề.
    public bool skipUIText { get => Get("skipUIText", true); set => Set("skipUIText", value); }

    // MARK: Dịch
    /// Email người dùng tự nhập (gửi kèm lên server duyệt máy để chủ app biết máy của ai).
    public string userEmail { get => Get("userEmail", ""); set => Set("userEmail", value); }
    public string targetLanguage { get => Get("targetLanguage", "vi"); set => Set("targetLanguage", value); }
    public string geminiModel { get => Get("geminiModel", "gemini-3.5-flash-lite"); set => Set("geminiModel", value); }
    public string geminiBaseURL { get => Get("geminiBaseURL", "https://generativelanguage.googleapis.com/v1beta"); set => Set("geminiBaseURL", value); }
    public int rpm { get => Get("rpm", 10); set => Set("rpm", value); }
    public int rpd { get => Get("rpd", 500); set => Set("rpd", value); }
    public double geminiTimeout { get => Get("geminiTimeout", 4.0); set => Set("geminiTimeout", value); }
    public TranslationEngine translationEngine { get => Get("translationEngine", TranslationEngine.auto); set => Set("translationEngine", value); }
    /// Engine đang hiệu lực (cờ --translate-engine ghi đè khi test, không lưu).
    public TranslationEngine engine => forceTranslationEngine ?? translationEngine;
    public int contextPairs { get => Get("contextPairs", 5); set => Set("contextPairs", value); }
    public QueueMode queueMode { get => Get("queueMode", QueueMode.latestWins); set => Set("queueMode", value); }

    // MARK: Phân tích màn hình (thủ công)
    public ScreenEngine screenEngine { get => Get("screenEngine", ScreenEngine.sameAsSubtitle); set => Set("screenEngine", value); }
    /// Engine thật sự dùng cho "Dịch màn hình": chọn "Giống engine dịch phụ đề" thì suy từ engine phụ đề.
    public ScreenEngine effectiveScreenEngine => screenEngine != ScreenEngine.sameAsSubtitle ? screenEngine : engine switch
    {
        TranslationEngine.auto => ScreenEngine.gemini,
        TranslationEngine.openAI => ScreenEngine.openAI,
        TranslationEngine.anthropic => ScreenEngine.anthropic,
        TranslationEngine.custom => ScreenEngine.custom,
        TranslationEngine.shared => ScreenEngine.shared,
        _ => ScreenEngine.google,
    };
    public bool analyzeSpeakSummary { get => Get("analyzeSpeakSummary", false); set => Set("analyzeSpeakSummary", value); }
    public double analyzeTimeout { get => Get("analyzeTimeout", 20.0); set => Set("analyzeTimeout", value); }

    // MARK: Tóm tắt & cốt truyện
    public SummaryEngine summaryEngine { get => Get("summaryEngine", SummaryEngine.sameAsSubtitle); set => Set("summaryEngine", value); }
    /// Engine thật sự viết tóm tắt / cốt truyện. Engine phụ đề không tóm tắt được (Google Translate) thì dùng Gemini.
    public SummaryEngine effectiveSummaryEngine => summaryEngine != SummaryEngine.sameAsSubtitle ? summaryEngine
        : engine switch
        {
            TranslationEngine.openAI => SummaryEngine.openAI,
            TranslationEngine.anthropic => SummaryEngine.anthropic,
            TranslationEngine.custom => SummaryEngine.custom,
            TranslationEngine.shared => SummaryEngine.shared,
            _ => SummaryEngine.gemini,
        };
    /// Tự viết cốt truyện game từ phụ đề (nút trên thanh đầu cửa sổ chính; xem ở Nhật ký → Cốt truyện).
    public bool storyEnabled { get => Get("storyEnabled", false); set => Set("storyEnabled", value); }
    public int storyIntervalMin { get => Get("storyIntervalMin", 10); set => Set("storyIntervalMin", value); }
    public bool storyOn => storyEnabled || forceStoryInterval != null;

    // MARK: Voice
    public bool voiceEnabled { get => Get("voiceEnabled", false); set => Set("voiceEnabled", value); }
    /// Id giọng Windows (rỗng = tự chọn giọng của ngôn ngữ đích).
    public string voiceIdentifier { get => Get("voiceIdentifier", ""); set => Set("voiceIdentifier", value); }
    /// Tốc độ giọng Windows (1.0 = bình thường).
    public double voiceRate { get => Get("winVoiceRate", 1.25); set => Set("winVoiceRate", value); }
    public bool interruptSpeech { get => Get("interruptSpeech", true); set => Set("interruptSpeech", value); }
    public VoiceEngine voiceEngine { get => Get("voiceEngine", VoiceEngine.windows); set => Set("voiceEngine", value); }
    public string edgeVoice { get => Get("edgeVoice", ""); set => Set("edgeVoice", value); }
    public double edgeRatePercent { get => Get("edgeRatePercent", 40.0); set => Set("edgeRatePercent", value); }
    /// 3 = 720p, 4 = 1080p
    public int ps5Resolution { get => Get("ps5Resolution", 4); set => Set("ps5Resolution", value); }
    public int ps5FPS { get => Get("ps5FPS", 30); set => Set("ps5FPS", value); }
    public bool ps5AutoTranslate { get => Get("ps5AutoTranslate", true); set => Set("ps5AutoTranslate", value); }
    /// Mất kết nối PS5 khi đang chơi: tự kết nối lại (ở lại màn hình chính) thay vì quay về màn hình Bắt đầu.
    public bool ps5AutoReconnect { get => Get("ps5AutoReconnect", true); set => Set("ps5AutoReconnect", value); }
    public int ps5ReconnectAttempts { get => Get("ps5ReconnectAttempts", 10); set => Set("ps5ReconnectAttempts", value); }
    /// Chữ ký (băm) của các cặp nhà cung cấp + model + key đã "Test key" thành công; không lưu key thô (xem Readiness).
    public List<string> aiVerified { get => Get("aiVerified", new List<string>()); set => Set("aiVerified", value); }
    public double catchUpPercent { get => Get("catchUpPercent", 10.0); set => Set("catchUpPercent", value); }
    public string localVoiceID { get => Get("localVoiceID", "minhquang"); set => Set("localVoiceID", value); }
    public double localSpeed { get => Get("localSpeed", 1.15); set => Set("localSpeed", value); }
    public bool voiceSkipSpeaker { get => Get("voiceSkipSpeaker", true); set => Set("voiceSkipSpeaker", value); }
    public bool voiceAdaptiveRate { get => Get("voiceAdaptiveRate", true); set => Set("voiceAdaptiveRate", value); }
    /// Phát giọng đọc trên TV / điện thoại đang mở trang hoặc app xem phụ đề (qua máy chủ web) thay vì loa máy này.
    public bool voiceOnRemote { get => Get("voiceOnRemote", false); set => Set("voiceOnRemote", value); }

    // MARK: Overlay
    public bool overlayEnabled { get => Get("overlayEnabled", true); set => Set("overlayEnabled", value); }
    public double overlayHideAfter { get => Get("overlayHideAfter", 6.0); set => Set("overlayHideAfter", value); }
    public double overlayFontSize { get => Get("overlayFontSize", 22.0); set => Set("overlayFontSize", value); }
    public OverlayPosition overlayPosition { get => Get("overlayPosition", OverlayPosition.belowRegion); set => Set("overlayPosition", value); }
    public double overlayOpacity { get => Get("overlayOpacity", 0.7); set => Set("overlayOpacity", value); }
    public bool overlayShowSource { get => Get("overlayShowSource", true); set => Set("overlayShowSource", value); }
    public double overlayMaxWidth { get => Get("overlayMaxWidth", 900.0); set => Set("overlayMaxWidth", value); }

    // MARK: Web (xem trên điện thoại / máy tính bảng)
    public bool webServerEnabled { get => Get("webServerEnabled", true); set => Set("webServerEnabled", value); }
    public int webServerPort { get => Get("webServerPort", 8787); set => Set("webServerPort", value); }
    public bool webServerOn => webServerEnabled && !forceNoWeb;
    public int webPort => forceWebPort ?? webServerPort;

    // MARK: Phím tắt (Ctrl+Alt+S/T/V/O)
    public KeyCombo hotkeyToggle { get => Get("hotkeyToggle", new KeyCombo(0x53, KeyCombo.Control | KeyCombo.Alt)); set => Set("hotkeyToggle", value); }
    public KeyCombo hotkeyAnalyze { get => Get("hotkeyAnalyze", new KeyCombo(0x54, KeyCombo.Control | KeyCombo.Alt)); set => Set("hotkeyAnalyze", value); }
    public KeyCombo hotkeyVoice { get => Get("hotkeyVoice", new KeyCombo(0x56, KeyCombo.Control | KeyCombo.Alt)); set => Set("hotkeyVoice", value); }
    public KeyCombo hotkeyOverlay { get => Get("hotkeyOverlay", new KeyCombo(0x4F, KeyCombo.Control | KeyCombo.Alt)); set => Set("hotkeyOverlay", value); }
    public bool hotkeysEnabled { get => Get("hotkeysEnabled", true); set => Set("hotkeysEnabled", value); }

    // MARK: Cửa sổ
    public double[]? mainWindowFrame { get => Get<double[]?>("mainWindowFrame", null); set => Set("mainWindowFrame", value); }

    // MARK: AI (Cài đặt → AI: key và model của từng nhà cung cấp)
    public string openAIModel { get => Get("openAIModel", "gpt-5.4-nano"); set => Set("openAIModel", value); }
    public double openAITimeout { get => Get("openAITimeout", 4.0); set => Set("openAITimeout", value); }
    public string openAIKey
    {
        get => SecretStore.Get("openai-api-key") ?? "";
        set { SecretStore.Set(value, "openai-api-key"); OnPropertyChanged(nameof(openAIKey)); Changed?.Invoke(nameof(openAIKey)); }
    }

    public string anthropicModel { get => Get("anthropicModel", "claude-haiku-5-5"); set => Set("anthropicModel", value); }
    public double anthropicTimeout { get => Get("anthropicTimeout", 5.0); set => Set("anthropicTimeout", value); }
    public string anthropicKey
    {
        get => SecretStore.Get("anthropic-api-key") ?? "";
        set { SecretStore.Set(value, "anthropic-api-key"); OnPropertyChanged(nameof(anthropicKey)); Changed?.Invoke(nameof(anthropicKey)); }
    }

    /// API tuỳ chỉnh: máy chủ bất kỳ nói giao thức Chat Completions của OpenAI (OpenRouter, Ollama, LM Studio…).
    public string customBaseURL { get => Get("customBaseURL", ""); set => Set("customBaseURL", value); }
    public string customModel { get => Get("customModel", ""); set => Set("customModel", value); }
    public double customTimeout { get => Get("customTimeout", 6.0); set => Set("customTimeout", value); }
    public string customKey
    {
        get => SecretStore.Get("custom-api-key") ?? "";
        set { SecretStore.Set(value, "custom-api-key"); OnPropertyChanged(nameof(customKey)); Changed?.Invoke(nameof(customKey)); }
    }
    /// Máy chủ chạy trên máy (Ollama…) không cần key, nên chỉ cần địa chỉ và model.
    public bool customReady => customBaseURL.Trim().Length > 0 && customModel.Length > 0;

    /// AI share: token do chủ server cấp (dán ở Cài đặt → AI). Key thật nằm trên server; app chỉ gửi token qua proxy
    /// và chỉ dùng được các model trong `aiShare.models` (server cũng chặn model khác).
    public AIShareInfo? aiShare { get => Get<AIShareInfo?>("aiShare", null); set => Set("aiShare", value); }
    public string aiShareToken
    {
        get => SecretStore.Get("ai-share-token") ?? "";
        set { SecretStore.Set(value, "ai-share-token"); OnPropertyChanged(nameof(aiShareToken)); Changed?.Invoke(nameof(aiShareToken)); }
    }
    /// Cờ runtime (không lưu): --share-server <url> trỏ AI share tới server khác (test với server chạy trên máy).
    public string? forceShareServer;

    /// Model riêng cho từng việc, chọn ở Cài đặt → Dịch. Khoá "<việc>.<nhà cung cấp>" (ví dụ "summary.anthropic");
    /// không có hoặc trống = dùng model mặc định của nhà cung cấp đó ở Cài đặt → AI.
    public Dictionary<string, string> taskModels { get => Get("taskModels", new Dictionary<string, string>()); set => Set("taskModels", value); }
    public string? TaskModel(AITask task, string provider) =>
        taskModels.TryGetValue($"{task}.{provider}", out var m) && m.Length > 0
        // AI share chỉ dùng được model đã share (admin có thể bớt model sau khi đã chọn).
        && (provider != "shared" || aiShare?.models.Contains(m) == true) ? m : null;
    /// Model mặc định của một nhà cung cấp (gemini / openAI / anthropic / custom).
    public string DefaultModel(string provider) => provider switch
    {
        "gemini" => geminiModel, "openAI" => openAIModel, "anthropic" => anthropicModel, "custom" => customModel,
        "shared" => aiShare?.models.FirstOrDefault() ?? "", _ => "",
    };

    /// Danh sách model đã tải về bằng nút "Tải model" của từng nhà cung cấp (giữ lại giữa các lần mở app).
    public Dictionary<string, List<string>> aiModelLists { get => Get("aiModelLists", new Dictionary<string, List<string>>()); set => Set("aiModelLists", value); }

    /// Gemini miễn phí nên cho lưu nhiều key (mỗi dòng một key trong file bí mật) và dùng xoay vòng.
    public List<string> geminiAPIKeys
    {
        get => (SecretStore.Get("gemini-api-key") ?? "").Split('\n', '\r').Select(k => k.Trim()).Where(k => k.Length > 0).Distinct().ToList();
        set
        {
            SecretStore.Set(string.Join("\n", value.Select(k => k.Trim()).Where(k => k.Length > 0).Distinct()), "gemini-api-key");
            OnPropertyChanged(nameof(geminiAPIKeys)); Changed?.Invoke(nameof(geminiAPIKeys));
        }
    }
    /// Key đầu tiên (đặt = thay toàn bộ danh sách bằng một key; dùng cho cờ --gemini-key).
    public string geminiAPIKey
    {
        get => geminiAPIKeys.FirstOrDefault() ?? "";
        set => geminiAPIKeys = value.Length == 0 ? new List<string>() : new List<string> { value };
    }
    /// Quota mỗi phút / mỗi ngày tính gộp trên mọi key.
    public int geminiRPM => rpm * Math.Max(1, geminiAPIKeys.Count);
    public int geminiRPD => rpd * Math.Max(1, geminiAPIKeys.Count);

    public TargetLanguage target => TargetLanguage.Find(targetLanguage);
    public bool voiceOn => voiceEnabled;
    public bool overlayOn => overlayEnabled && !forceNoOverlay;
}

/// Thông tin một AI share (server trả về theo token).
public sealed class AIShareInfo
{
    public string label { get; set; } = "";
    /// Nhà cung cấp phía server: openai | anthropic | gemini | custom.
    public string provider { get; set; } = "";
    public List<string> models { get; set; } = new();
    /// Server báo token đã bị thu hồi / không hợp lệ ở lần kiểm tra gần nhất.
    public bool revoked { get; set; }

    public bool SameAs(AIShareInfo? o) =>
        o != null && o.label == label && o.provider == provider && o.revoked == revoked && o.models.SequenceEqual(models);
}
