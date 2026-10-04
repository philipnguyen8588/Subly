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
    /// --no-web / --web-port.
    public bool forceNoWeb;
    public int? forceWebPort;
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
    public List<Profile> profiles { get => Get("profiles", new List<Profile>()); set => Set("profiles", value); }
    public Guid? activeProfileID { get => Get<Guid?>("activeProfileID", null); set => Set("activeProfileID", value); }

    public Profile activeProfile
    {
        get
        {
            var ps = profiles;
            var id = activeProfileID;
            return ps.FirstOrDefault(p => p.id == id) ?? ps.FirstOrDefault() ?? new Profile { name = "Mặc định" };
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
    public List<GlossaryEntry> glossary
    {
        get => activeProfile.glossary;
        set { var p = activeProfile; p.glossary = value; activeProfile = p; OnPropertyChanged(nameof(glossary)); }
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
            var p = new Profile { name = "Mặc định" };
            profiles = new List<Profile> { p };
            activeProfileID = p.id;
        }
        else if (activeProfileID == null || !ps.Any(p => p.id == activeProfileID))
            activeProfileID = ps[0].id;
    }

    // MARK: Capture
    public int fps { get => Get("fps", 4); set => Set("fps", value); }
    /// Phóng to ảnh trước khi OCR (Windows chụp theo pixel thật; 1 = giữ nguyên, 1.5–2 giúp đọc chữ nhỏ).
    public double captureScale { get => Get("winCaptureScale", 1.0); set => Set("winCaptureScale", value); }
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
    public string targetLanguage { get => Get("targetLanguage", "vi"); set => Set("targetLanguage", value); }
    public string geminiModel { get => Get("geminiModel", "gemini-2.5-flash-lite"); set => Set("geminiModel", value); }
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
    public bool analyzeSpeakSummary { get => Get("analyzeSpeakSummary", false); set => Set("analyzeSpeakSummary", value); }
    public double analyzeTimeout { get => Get("analyzeTimeout", 20.0); set => Set("analyzeTimeout", value); }

    // MARK: Voice
    public bool voiceEnabled { get => Get("voiceEnabled", true); set => Set("voiceEnabled", value); }
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

    public string geminiAPIKey
    {
        get => SecretStore.Get("gemini-api-key") ?? "";
        set { SecretStore.Set(value, "gemini-api-key"); OnPropertyChanged(nameof(geminiAPIKey)); Changed?.Invoke(nameof(geminiAPIKey)); }
    }

    public TargetLanguage target => TargetLanguage.Find(targetLanguage);
    public bool voiceOn => voiceEnabled;
    public bool overlayOn => overlayEnabled && !forceNoOverlay;
}
