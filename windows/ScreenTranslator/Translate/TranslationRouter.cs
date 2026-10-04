using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Chọn backend: Gemini nếu có key, còn quota, không cooldown, có mạng; ngược lại Google Translate.
public sealed class TranslationRouter : INotifyPropertyChanged
{
    public enum StateKind { gemini, googleQuota, googleNoKey, offline, googleOnly, googleError }

    public record State(StateKind kind, string detail = "")
    {
        public bool isGemini => kind == StateKind.gemini;
        /// 0 xanh, 1 vàng, 2 đỏ
        public int level => kind switch
        {
            StateKind.gemini or StateKind.googleOnly => 0,
            StateKind.googleQuota or StateKind.googleError or StateKind.googleNoKey => 1,
            _ => 2,
        };
        public string label => kind switch
        {
            StateKind.gemini => "Gemini",
            StateKind.googleQuota => $"Google · Gemini {detail}",
            StateKind.googleNoKey => "Google · chưa có Gemini key",
            StateKind.offline => "Offline · không dịch được",
            StateKind.googleOnly => "Google Translate",
            _ => $"Google · Gemini lỗi: {detail}",
        };
    }

    public record Output(string text, BackendKind backend, int ms);
    public record AnalysisOutput(string summary, List<string> translations, BackendKind backend, int ms);

    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

    State _state = new(StateKind.googleNoKey);
    public State state { get => _state; private set { if (_state != value) { _state = value; Raise(nameof(state)); } } }
    int _used;
    public int usedToday { get => _used; private set { if (_used != value) { _used = value; Raise(nameof(usedToday)); } } }
    public bool online { get; private set; } = true;
    string? _lastError;
    public string? lastError { get => _lastError; private set { _lastError = value; Raise(nameof(lastError)); } }
    string? _activeModel;
    public string? activeModel { get => _activeModel; private set { _activeModel = value; Raise(nameof(activeModel)); } }

    public readonly GeminiBackend gemini;
    public readonly GoogleFreeBackend google = new();
    public readonly RateLimiter limiter;
    readonly AppSettings settings = AppSettings.shared;
    readonly List<TranslationPair> context = new();
    readonly object ctxLock = new();
    string lastTarget;
    Timer? applyTimer;

    public TranslationRouter()
    {
        gemini = new GeminiBackend(settings.geminiAPIKey, settings.geminiModel, settings.geminiTimeout);
        limiter = new RateLimiter(settings.rpm, settings.rpd);
        lastTarget = settings.targetLanguage;
        ApplyGeminiSettings();
        online = NetworkInterface.GetIsNetworkAvailable();
        NetworkChange.NetworkAvailabilityChanged += (_, e) => { online = e.IsAvailable; RefreshState(); };
        settings.Changed += key =>
        {
            if (key == "rpdUsed") return;
            applyTimer?.Dispose();
            applyTimer = new Timer(_ => ApplySettings(), null, 200, Timeout.Infinite);
        };
        usedToday = limiter.usedToday;
        RefreshState();
    }

    void ApplyGeminiSettings()
    {
        gemini.apiKey = settings.geminiAPIKey;
        gemini.model = settings.geminiModel;
        gemini.timeout = settings.geminiTimeout;
        gemini.baseURL = settings.geminiBaseURL;
        gemini.targetName = settings.target.englishName;
        gemini.glossary = settings.glossary;
        gemini.speakers = settings.showsSpeakerNames ? settings.speakers : new List<string>();
        google.targetCode = settings.target.googleCode;
    }

    /// Số câu nên dịch cùng lúc. Gemini (qua mạng) chạy song song được; Google cũng nhanh nên chỉ 1 để giữ thứ tự gọn.
    public int parallelism => state.kind == StateKind.gemini ? 3 : 1;

    public void ApplySettings()
    {
        ApplyGeminiSettings();
        if (settings.targetLanguage != lastTarget)
        {
            lastTarget = settings.targetLanguage;
            ResetContext();
        }
        limiter.Configure(settings.rpm, settings.rpd);
        RefreshState();
    }

    public void ResetContext() { lock (ctxLock) context.Clear(); }

    void RefreshState()
    {
        if (!online) { state = new State(StateKind.offline); return; }
        if (settings.engine == TranslationEngine.google) { state = new State(StateKind.googleOnly); return; }
        if (string.IsNullOrEmpty(gemini.apiKey)) { state = new State(StateKind.googleNoKey); return; }
        if (state.kind is StateKind.googleQuota or StateKind.googleError) return;
        state = new State(StateKind.gemini);
    }

    /// Có được phép gọi Gemini cho request tiếp theo không (trừ token nếu có).
    bool AcquireGemini()
    {
        if (settings.engine != TranslationEngine.auto || string.IsNullOrEmpty(gemini.apiKey) || !online) return false;
        var denial = limiter.Acquire();
        if (denial != null)
        {
            state = denial.kind switch
            {
                RateLimiter.DenialKind.cooldown => new State(StateKind.googleQuota, $"cooldown {(int)denial.seconds}s"),
                RateLimiter.DenialKind.minute => new State(StateKind.googleQuota, "hết quota/phút"),
                _ => new State(StateKind.googleQuota, "hết quota/ngày"),
            };
            return false;
        }
        return true;
    }

    void HandleGeminiError(Exception error)
    {
        if (error is GeminiException { kind: GeminiException.Kind.rateLimited } g)
        {
            limiter.ReportRateLimited(g.retryAfter);
            var msg = $"429, chờ {(int)(g.retryAfter ?? 60)}s";
            state = new State(StateKind.googleQuota, msg);
            lastError = $"Gemini hết quota ({msg})";
            Log.Warn("Gemini 429 → Google");
        }
        else
        {
            state = new State(StateKind.googleError, Short(error));
            lastError = $"Gemini lỗi: {error.Message}";
            Log.Warn($"Gemini error → Google: {error.Message}");
        }
    }

    List<TranslationPair> RecentContext()
    {
        lock (ctxLock) return context.Skip(Math.Max(0, context.Count - settings.contextPairs)).ToList();
    }

    // MARK: subtitle

    public async Task<Output?> Translate(string text)
    {
        var t0 = DateTime.UtcNow;
        if (AcquireGemini())
        {
            try
            {
                var outp = await gemini.Translate(text, RecentContext());
                usedToday = limiter.usedToday;
                state = new State(StateKind.gemini);
                lastError = null;
                activeModel = gemini.activeModel;
                AdoptFallbackModelIfNeeded();
                Remember(text, outp);
                return new Output(outp, BackendKind.gemini, Ms(t0));
            }
            catch (Exception e) { HandleGeminiError(e); }
        }
        if (!online) { RefreshState(); return null; }
        try
        {
            var outp = await google.Translate(text, Array.Empty<TranslationPair>());
            if (settings.engine == TranslationEngine.google) { state = new State(StateKind.googleOnly); lastError = null; }
            Remember(text, outp);
            return new Output(outp, BackendKind.google, Ms(t0));
        }
        catch (Exception e)
        {
            Log.Error($"Google Translate failed: {e.Message}");
            lastError = $"Google Translate lỗi: {e.Message}";
            return null;
        }
    }

    static int Ms(DateTime t0) => (int)(DateTime.UtcNow - t0).TotalMilliseconds;

    // MARK: screen analysis

    public async Task<AnalysisOutput?> Analyze(IList<string> lines)
    {
        var t0 = DateTime.UtcNow;
        if (AcquireGemini())
        {
            try
            {
                var r = await gemini.Analyze(lines, settings.analyzeTimeout);
                usedToday = limiter.usedToday;
                state = new State(StateKind.gemini);
                lastError = null;
                activeModel = gemini.activeModel;
                AdoptFallbackModelIfNeeded();
                var translations = lines.Select((_, i) => r.translations.GetValueOrDefault(i + 1) ?? "").ToList();
                return new AnalysisOutput(r.summary, translations, BackendKind.gemini, Ms(t0));
            }
            catch (Exception e) { HandleGeminiError(e); }
        }
        // Không có Gemini: dịch từng dòng bằng Google Translate, không có tóm tắt.
        try
        {
            var outp = await google.TranslateBatch(lines);
            return new AnalysisOutput("", outp, BackendKind.google, Ms(t0));
        }
        catch (Exception e)
        {
            Log.Error($"Google batch failed: {e.Message}");
            return null;
        }
    }

    /// Model đã chọn không tồn tại → lưu model dự phòng đang chạy làm mặc định để khỏi thử lại mãi.
    void AdoptFallbackModelIfNeeded()
    {
        if (gemini.chosenModelMissing && gemini.activeModel is string a && a != settings.geminiModel)
        {
            Log.Warn($"Model {settings.geminiModel} không tồn tại → đổi cài đặt sang {a}");
            gemini.chosenModelMissing = false;
            settings.geminiModel = a;
        }
    }

    void Remember(string s, string t)
    {
        lock (ctxLock)
        {
            context.Add(new TranslationPair(s, t));
            if (context.Count > 20) context.RemoveRange(0, context.Count - 20);
        }
    }

    static string Short(Exception e)
    {
        if (e is GeminiException g)
        {
            if (g.kind == GeminiException.Kind.http)
                return g.code switch
                {
                    503 => "503 quá tải",
                    404 => "404 model không có",
                    400 => "400 request sai",
                    401 or 403 => $"{g.code} key không hợp lệ",
                    _ => $"HTTP {g.code}",
                };
            if (g.kind == GeminiException.Kind.timeout) return "timeout";
        }
        var s = e.Message;
        return s.Length > 40 ? s[..40] + "…" : s;
    }
}
