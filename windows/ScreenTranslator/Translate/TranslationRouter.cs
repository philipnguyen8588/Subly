using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Net.NetworkInformation;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Chọn backend: Gemini nếu có key, còn quota, không cooldown, có mạng; ngược lại Google Translate.
public sealed class TranslationRouter : INotifyPropertyChanged
{
    public enum StateKind { gemini, googleQuota, googleNoKey, offline, googleOnly, googleError, openAI, openAIFallback }

    public record State(StateKind kind, string detail = "")
    {
        public bool isGemini => kind == StateKind.gemini;
        /// 0 xanh, 1 vàng, 2 đỏ
        public int level => kind switch
        {
            StateKind.gemini or StateKind.googleOnly or StateKind.openAI => 0,
            StateKind.googleQuota or StateKind.googleError or StateKind.googleNoKey or StateKind.openAIFallback => 1,
            _ => 2,
        };
        public string label => kind switch
        {
            StateKind.gemini => "Gemini",
            StateKind.openAI => "OpenAI",
            StateKind.openAIFallback => $"Google · OpenAI {detail}",
            StateKind.googleQuota => $"Google · Gemini {detail}",
            StateKind.googleNoKey => "Google · chưa có Gemini key",
            StateKind.offline => "Offline · không dịch được",
            StateKind.googleOnly => "Google Translate",
            _ => $"Google · Gemini lỗi: {detail}",
        };
    }

    public record Output(string text, BackendKind backend, int ms);
    public record AnalysisOutput(string summary, List<string> translations, BackendKind backend, int ms);
    public record StoryOutput(string title, string summary, BackendKind backend, int ms);

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
    public readonly OpenAIBackend openai = new();
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
        openai.subtitlePrompt = () => gemini.subtitleSystemPrompt;
        openai.analysisPrompt = () => gemini.analysisSystemPrompt;
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
        gemini.glossary = settings.effectiveGlossary;
        gemini.speakers = settings.showsSpeakerNames ? settings.speakers : new List<string>();
        gemini.gameName = settings.activeProfile.name;
        gemini.translationStyle = settings.effectiveTranslationStyle;
        gemini.translationNote = settings.translationNote;
        google.targetCode = settings.target.googleCode;
        openai.apiKey = settings.openAIKey;
        openai.model = settings.openAIModel;
        openai.timeout = settings.openAITimeout;
    }

    bool useOpenAI => settings.engine == TranslationEngine.openAI;

    /// Số câu nên dịch cùng lúc. Gemini / OpenAI (qua mạng) chạy song song được; Google cũng nhanh nên chỉ 1 để giữ thứ tự gọn.
    public int parallelism => state.kind is StateKind.gemini or StateKind.openAI ? 3 : 1;

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

    /// Bắt đầu lại sau khi Dừng: lấy các câu vừa dịch trong 10 phút gần nhất của game đang chơi (nhật ký chỉ chứa game đó)
    /// làm ngữ cảnh, để những câu đầu sau khi tiếp tục vẫn giữ mạch hội thoại và cách xưng hô. Gọi trên UI thread.
    public void SeedContextFromHistory()
    {
        var now = DateTime.Now;
        var recent = HistoryStore.shared.entries
            .TakeWhile(e => (now - e.timestamp).TotalSeconds < 600)
            .Where(e => e.backend != BackendKind.skipped.ToString() && e.kind == RegionKind.subtitle && e.targetLang == settings.targetLanguage)
            .Take(10).Reverse()
            .Select(e => new TranslationPair(e.source, e.translated)).ToList();
        lock (ctxLock) { context.Clear(); context.AddRange(recent); }
        if (recent.Count > 0) Log.Info($"Ngữ cảnh dịch: nạp lại {recent.Count} câu gần đây từ nhật ký");
    }

    void RefreshState()
    {
        if (useOpenAI)
        {
            if (openai.apiKey.Length == 0) { state = new State(StateKind.openAIFallback, "chưa có key"); return; }
            if (!online) { state = new State(StateKind.openAIFallback, "offline"); return; }
            if (state.kind == StateKind.openAIFallback && lastError != null) return;
            state = new State(StateKind.openAI);
            return;
        }
        if (!online) { state = new State(StateKind.offline); return; }
        if (settings.engine == TranslationEngine.google) { state = new State(StateKind.googleOnly); return; }
        if (string.IsNullOrEmpty(gemini.apiKey)) { state = new State(StateKind.googleNoKey); return; }
        if (state.kind is StateKind.googleQuota or StateKind.googleError) return;
        state = new State(StateKind.gemini);
    }

    /// Có được phép gọi Gemini cho request tiếp theo không (trừ token nếu có).
    /// `forScreen`: lần "Dịch màn hình" dùng engine riêng (Cài đặt → Dịch → Dịch màn hình), không theo engine phụ đề.
    bool AcquireGemini(bool forScreen = false)
    {
        bool wanted = forScreen ? settings.screenEngine == ScreenEngine.gemini : settings.engine == TranslationEngine.auto;
        if (!wanted || string.IsNullOrEmpty(gemini.apiKey) || !online) return false;
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

    /// Bối cảnh cốt truyện = tóm tắt "Dịch màn hình" gần nhất có nội dung của game đang chơi (bỏ tóm tắt menu, vốn chỉ
    /// một câu ngắn). Gọi trước mỗi câu vì lần dịch màn hình mới không làm đổi cài đặt.
    void RefreshStory()
    {
        string story = "";
        try { story = HistoryStore.shared.analyses.FirstOrDefault(a => a.summary.Length >= 80 && !a.summary.StartsWith("("))?.summary ?? ""; }
        catch { }
        gemini.storyContext = story.Length > 500 ? story[..500] : story;
    }

    public async Task<Output?> Translate(string text)
    {
        if (!SessionCheck.shared.Valid()) return null;
        var t0 = DateTime.UtcNow;
        RefreshStory();
        var ctx = RecentContext();
        gemini.glossaryFocus = string.Join("\n", new[] { text }.Concat(ctx.Select(p => p.source)));
        if (useOpenAI && openai.apiKey.Length > 0 && online)
        {
            try
            {
                var outp = await openai.Translate(text, ctx);
                state = new State(StateKind.openAI);
                lastError = null;
                var fixedText = FixSpeaker(text, outp);
                Remember(text, fixedText);
                return new Output(fixedText, BackendKind.openAI, Ms(t0));
            }
            catch (Exception e)
            {
                state = new State(StateKind.openAIFallback, "lỗi");
                lastError = e.Message;
                Log.Warn($"OpenAI lỗi → Google: {e.Message}");
            }
        }
        if (AcquireGemini())
        {
            try
            {
                var outp = await gemini.Translate(text, ctx);
                usedToday = limiter.usedToday;
                state = new State(StateKind.gemini);
                lastError = null;
                activeModel = gemini.activeModel;
                AdoptFallbackModelIfNeeded();
                var fixedText = FixSpeaker(text, outp);
                Remember(text, fixedText);
                return new Output(fixedText, BackendKind.gemini, Ms(t0));
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
        gemini.glossaryFocus = string.Join("\n", lines);
        if (settings.screenEngine == ScreenEngine.openAI && openai.apiKey.Length > 0 && online)
        {
            try
            {
                var r = await openai.Analyze(lines, settings.analyzeTimeout);
                Log.Info($"Dịch màn hình bằng OpenAI ({openai.model})");
                var translations = lines.Select((_, i) => r.translations.GetValueOrDefault(i + 1) ?? "").ToList();
                return new AnalysisOutput(r.summary, translations, BackendKind.openAI, Ms(t0));
            }
            catch (Exception e) { Log.Warn($"OpenAI (dịch màn hình) lỗi → Google: {e.Message}"); }
        }
        if (AcquireGemini(forScreen: true))
        {
            try
            {
                var r = await gemini.Analyze(lines, settings.analyzeTimeout);
                usedToday = limiter.usedToday;
                activeModel = gemini.activeModel;
                AdoptFallbackModelIfNeeded();
                Log.Info($"Dịch màn hình bằng Gemini ({gemini.activeModel ?? settings.geminiModel})");
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

    // MARK: story summary

    /// Tóm tắt các câu phụ đề người dùng chọn trong nhật ký. Dùng engine của "Dịch màn hình" trước (OpenAI / Gemini),
    /// lỗi hoặc không có thì thử engine trên mạng còn lại (Windows không có model trên máy như Apple Intelligence).
    public async Task<StoryOutput> SummarizeStory(IList<string> lines)
    {
        var t0 = DateTime.UtcNow;
        gemini.glossaryFocus = string.Join("\n", lines);
        var system = gemini.storySummaryPrompt;
        const string jsonRule = "\nReply with JSON only, no code fences and no other text, exactly in this shape:\n{\"title\": \"…\", \"summary\": \"…\"}";
        var input = string.Join("\n", lines);
        double timeout = Math.Max(settings.analyzeTimeout, 60);
        Exception lastErr = new InvalidOperationException("Không có engine nào tóm tắt được (cần OpenAI hoặc Gemini API key)");
        StoryOutput Out(string raw, BackendKind backend)
        {
            var (title, summary) = ParseStory(raw);
            if (summary.Length == 0) throw new InvalidOperationException("Model trả về tóm tắt rỗng");
            return new StoryOutput(title, summary, backend, Ms(t0));
        }
        var order = settings.screenEngine == ScreenEngine.openAI ? new[] { BackendKind.openAI, BackendKind.gemini } : new[] { BackendKind.gemini, BackendKind.openAI };
        foreach (var b in order)
        {
            if (b == BackendKind.openAI && openai.apiKey.Length > 0 && online)
            {
                try { return Out(await openai.Complete(system + jsonRule, input, true, 2500, timeout), BackendKind.openAI); }
                catch (Exception e) { Log.Warn($"OpenAI (tóm tắt) lỗi → engine khác: {e.Message}"); lastErr = e; }
            }
            if (b == BackendKind.gemini && !string.IsNullOrEmpty(gemini.apiKey) && online && limiter.Acquire() == null)
            {
                try
                {
                    var raw = await gemini.Generate(system + jsonRule, input, timeout);
                    usedToday = limiter.usedToday;
                    activeModel = gemini.activeModel;
                    return Out(raw, BackendKind.gemini);
                }
                catch (Exception e) { HandleGeminiError(e); lastErr = e; }
            }
        }
        throw lastErr;
    }

    /// Đọc {"title", "summary"} (hoặc văn bản thường: dòng đầu là tiêu đề), giữ xuống đoạn.
    public static (string title, string summary) ParseStory(string raw)
    {
        static string Clean(string s) => string.Join("\n\n",
            string.Join("\n", s.Split('\n').Select(l => TextUtils.Normalize(l)))
                .Split("\n\n", StringSplitOptions.None)
                .Select(p => string.Join(" ", p.Split('\n', StringSplitOptions.RemoveEmptyEntries)).Trim())
                .Where(p => p.Length > 0));
        if (GeminiBackend.ParseObject(raw) is JsonObject obj)
        {
            string Get(string k) { try { return obj[k]?.GetValue<string>() ?? ""; } catch { return ""; } }
            return (TextUtils.Normalize(Get("title")), Clean(Get("summary")));
        }
        var rows = raw.Replace("\r", "").Split('\n').ToList();
        while (rows.Count > 0 && rows[0].Trim().Length == 0) rows.RemoveAt(0);
        if (rows.Count == 0) return ("", "");
        var title = rows[0].Trim(); rows.RemoveAt(0);
        foreach (var p in new[] { "#", "*", "Title:", "Tiêu đề:" }) while (title.StartsWith(p)) title = title[p.Length..].Trim();
        title = title.Trim('*', '"', '“', '”');
        var summary = Clean(string.Join("\n", rows));
        return summary.Length == 0 ? ("", Clean(title)) : (title, summary);
    }

    /// Tên người nói trong bản dịch phải khớp câu gốc. Model có lúc chép nguyên chữ "Name:" của lời dặn, gắn tên của câu
    /// trước vào câu không có người nói ("Call Elevator" → "Mechanic: …"), hoặc dịch mất tên.
    public static string FixSpeaker(string source, string translated)
    {
        var pattern = new Regex(@"^\s*[^:：\n]{1,30}[:：]\s+");
        System.Text.RegularExpressions.Match? Head(string s)
        {
            var m = pattern.Match(s);
            return m.Success && m.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 6 ? m : null;
        }
        var outp = translated.Trim(' ');
        // Câu gốc chỉ có người nói khi phần trước dấu hai chấm đúng dạng tên ("Jackie", "Coach Fred", "V"), không phải nhãn
        // như "Warning:", "Note:".
        string? srcName = null;
        if (Head(source) is { } sm && SpeakerNames.Learn(source) != null) srcName = sm.Value.Trim(' ');
        // Chỉ xoá tiền tố trông như tên tiếng Anh do model chèn vào ("Name:", "Mechanic:"); nhãn đã dịch ("Cảnh báo:") giữ nguyên.
        static bool Injected(string h)
        {
            var n = h[..^1].Trim(' ').ToLowerInvariant();
            return n == "name" || n == "tên" || SpeakerNames.Learn(h + " x") != null;
        }
        int guardCount = 0;
        while (guardCount < 3 && Head(outp) is { } m)
        {
            var h = m.Value.Trim(' ');
            bool isSrc = srcName != null && h.ToLowerInvariant().StartsWith(srcName[..^1].ToLowerInvariant());
            // Câu gốc có người nói mà bản dịch mở đầu bằng tên khác → model đã dịch tên ("Mechanic:" → "Thợ máy:"): thay lại.
            bool translatedName = srcName != null && guardCount == 0;
            if (!(isSrc || Injected(h) || translatedName)) break;
            outp = outp[(m.Index + m.Length)..].Trim(' ');
            guardCount++;
            if (isSrc) break;
        }
        if (outp.Length == 0) return translated;
        return srcName != null ? srcName + " " + outp : outp;
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
