using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

public class GeminiException : Exception
{
    public enum Kind { noKey, rateLimited, http, empty, badJSON, timeout }
    public readonly Kind kind;
    public readonly int code;
    public readonly double? retryAfter;
    public GeminiException(Kind kind, string msg, int code = 0, double? retryAfter = null) : base(msg)
    { this.kind = kind; this.code = code; this.retryAfter = retryAfter; }

    public static GeminiException NoKey() => new(Kind.noKey, "Chưa có Gemini API key");
    public static GeminiException RateLimited(double? r) => new(Kind.rateLimited, $"Gemini 429 rate limited (retry {(int)(r ?? 60)}s)", 429, r);
    public static GeminiException Http(int c, string m) => new(Kind.http, $"Gemini HTTP {c}: {m}", c);
    public static GeminiException Empty() => new(Kind.empty, "Gemini trả về rỗng");
    public static GeminiException BadJSON() => new(Kind.badJSON, "Gemini trả về JSON không hợp lệ");
    public static GeminiException Timeout() => new(Kind.timeout, "Gemini quá thời gian chờ");
}

public sealed class GeminiBackend : ITranslationBackend
{
    public BackendKind kind => BackendKind.gemini;

    public static readonly string[] models =
    {
        "gemini-2.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-3.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-3.5-flash",
    };
    /// Thứ tự thử khi model đã chọn bị 503/404/timeout.
    public static readonly string[] fallbackModels = { "gemini-2.5-flash-lite", "gemini-flash-lite-latest", "gemini-2.5-flash", "gemini-3.1-flash-lite" };

    public string apiKey;
    public string model;
    public double timeout;
    public string baseURL = "https://generativelanguage.googleapis.com/v1beta";
    public string targetName = "Vietnamese";
    public List<GlossaryEntry> glossary = new();
    public List<string> speakers = new();
    /// Model đang thực sự dùng (có thể là model dự phòng) + hạn "dính" 5 phút.
    public string? activeModel { get; private set; }
    DateTime activeUntil = DateTime.MinValue;
    public string? lastError { get; private set; }
    /// Model người dùng chọn trả 404 (không tồn tại với key này) → Router sẽ đổi cài đặt sang model dự phòng.
    public bool chosenModelMissing { get; set; }

    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(90) };

    public GeminiBackend(string apiKey, string model, double timeout)
    {
        this.apiKey = apiKey; this.model = model; this.timeout = timeout;
    }

    /// Danh sách model để thử theo thứ tự cho một request.
    List<string> CandidateModels(int maxAttempts)
    {
        var list = new List<string>();
        if (activeModel != null && DateTime.UtcNow < activeUntil) list.Add(activeModel);
        list.Add(model);
        list.AddRange(fallbackModels);
        return list.Distinct().Take(maxAttempts).ToList();
    }

    static bool IsRetryable(Exception e) => e is GeminiException g &&
        (g.kind == GeminiException.Kind.timeout || (g.kind == GeminiException.Kind.http && (g.code == 503 || g.code == 404 || g.code == 500 || g.code == 502)));

    // MARK: prompts

    string speakersBlock => speakers.Count == 0 ? "" :
        "\nCharacter names (keep exactly as written, never translate; keep the \"Name: \" prefix when the input has it): " + string.Join(", ", speakers) + "\n";

    string glossaryBlock
    {
        get
        {
            var items = glossary.Where(g => g.term.Trim().Length > 0).ToList();
            if (items.Count == 0) return speakersBlock;
            var rows = items.Select(g => g.keepAsIs || g.translation.Trim().Length == 0
                ? $"- \"{g.term}\" → keep exactly as \"{g.term}\""
                : $"- \"{g.term}\" → \"{g.translation}\"");
            return "\nGlossary (always apply, case-insensitive match):\n" + string.Join("\n", rows) + "\n" + speakersBlock;
        }
    }

    public string subtitleSystemPrompt =>
        $"You translate English subtitles from movies and video games into natural, concise {targetName}.\n" +
        "Keep the tone of the speaker (casual, rude, formal). Keep character names and game terms as-is unless the glossary says otherwise.\n" +
        $"Output ONLY the {targetName} translation, with no quotes, notes or explanations.\n" +
        glossaryBlock;

    public string analysisSystemPrompt =>
        "You are helping a player understand a video game screen. The user gives you numbered lines of English text " +
        "extracted by OCR from one screenshot (UI labels, dialog, quest text, stats). OCR may contain small errors; infer the intent.\n" +
        "Return JSON with:\n" +
        $"- \"summary\": 2–4 sentences in {targetName} explaining what is on screen and what the player should do or know now.\n" +
        $"- \"lines\": an array of {{\"i\": line number, \"t\": {targetName} translation}}. Translate every line; keep names, numbers, keys and game terms as-is unless the glossary says otherwise.\n" +
        glossaryBlock;

    // MARK: subtitle translate

    public async Task<string> Translate(string text, IList<TranslationPair> context, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(apiKey)) throw GeminiException.NoKey();
        var contents = new JsonArray();
        foreach (var p in context)
        {
            contents.Add(Turn("user", p.source));
            contents.Add(Turn("model", p.target));
        }
        contents.Add(Turn("user", text));
        var gen = new JsonObject { ["temperature"] = 0.2, ["maxOutputTokens"] = 256 };
        var raw = await SendWithFallback(subtitleSystemPrompt, contents, gen, timeout, 2, ct);
        var cleaned = Clean(raw);
        if (cleaned.Length == 0) throw GeminiException.Empty();
        return cleaned;
    }

    static JsonObject Turn(string role, string text) =>
        new() { ["role"] = role, ["parts"] = new JsonArray(new JsonObject { ["text"] = text }) };

    // MARK: screen analysis (JSON mode)

    public record AnalysisResult(string summary, Dictionary<int, string> translations);

    public async Task<AnalysisResult> Analyze(IList<string> lines, double timeout, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(apiKey)) throw GeminiException.NoKey();
        var numbered = string.Join("\n", lines.Select((l, i) => $"{i + 1}. {l}"));
        var contents = new JsonArray(Turn("user", numbered));
        var schema = JsonNode.Parse("""
        {"type":"OBJECT","properties":{"summary":{"type":"STRING"},
         "lines":{"type":"ARRAY","items":{"type":"OBJECT","properties":{"i":{"type":"INTEGER"},"t":{"type":"STRING"}},"required":["i","t"]}}},
         "required":["summary","lines"]}
        """);
        var gen = new JsonObject
        {
            ["temperature"] = 0.3, ["maxOutputTokens"] = 4096,
            ["responseMimeType"] = "application/json", ["responseSchema"] = schema,
        };
        var raw = await SendWithFallback(analysisSystemPrompt, contents, gen, timeout, 3, ct);
        JsonObject? obj;
        try { obj = JsonNode.Parse(raw) as JsonObject; } catch { throw GeminiException.BadJSON(); }
        if (obj == null) throw GeminiException.BadJSON();
        var summary = obj["summary"]?.GetValue<string>() ?? "";
        var map = new Dictionary<int, string>();
        if (obj["lines"] is JsonArray arr)
            foreach (var l in arr)
            {
                try
                {
                    var i = l?["i"]?.GetValue<int>(); var t = l?["t"]?.GetValue<string>();
                    if (i != null && t != null) map[i.Value] = t;
                }
                catch { }
            }
        return new AnalysisResult(TextUtils.Normalize(summary), map);
    }

    // MARK: transport

    /// Thử lần lượt các model; 503/404/timeout → model tiếp theo. Model thành công được "dính" 5 phút.
    async Task<string> SendWithFallback(string system, JsonArray contents, JsonObject generation, double timeout, int maxAttempts, CancellationToken ct)
    {
        Exception lastErr = GeminiException.Empty();
        foreach (var m in CandidateModels(maxAttempts))
        {
            try
            {
                var outp = await Send(m, system, contents, generation, timeout, ct);
                if (m != model && m != activeModel) Log.Warn($"Gemini chuyển sang model dự phòng {m} (model đã chọn: {model})");
                activeModel = m;
                activeUntil = DateTime.UtcNow.AddSeconds(300);
                lastError = null;
                return outp;
            }
            catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                lastErr = e;
                lastError = $"{m}: {e.Message}";
                if (m == model && e is GeminiException { kind: GeminiException.Kind.http, code: 404 }) chosenModelMissing = true;
                if (IsRetryable(e))
                {
                    Log.Warn($"Gemini {m} lỗi ({Trunc(e.Message, 60)}) → thử model khác");
                    if (m == activeModel) activeModel = null;
                    continue;
                }
                throw;
            }
        }
        throw lastErr;
    }

    static string Trunc(string s, int n) => s.Length > n ? s[..n] : s;

    async Task<string> Send(string model, string system, JsonArray contents, JsonObject generation, double timeout, CancellationToken ct)
    {
        try { return await Request(model, system, contents, generation, timeout, true, ct); }
        catch (GeminiException e) when (e.kind == GeminiException.Kind.http && e.code == 400 && e.Message.ToLowerInvariant().Contains("thinking"))
        {
            return await Request(model, system, contents, generation, timeout, false, ct);
        }
    }

    async Task<string> Request(string model, string system, JsonArray contents, JsonObject generation, double timeout, bool thinking, CancellationToken ct)
    {
        var gen = (JsonObject)generation.DeepClone();
        if (thinking)
            gen["thinkingConfig"] = model.StartsWith("gemini-2.5") ? new JsonObject { ["thinkingBudget"] = 0 } : new JsonObject { ["thinkingLevel"] = "low" };
        var body = new JsonObject
        {
            ["systemInstruction"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = system }) },
            ["contents"] = contents.DeepClone(),
            ["generationConfig"] = gen,
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, $"{baseURL}/models/{model}:generateContent");
        req.Headers.Add("x-goog-api-key", apiKey);
        req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(timeout));
        HttpResponseMessage resp;
        string data;
        try
        {
            resp = await http.SendAsync(req, cts.Token);
            data = await resp.Content.ReadAsStringAsync(cts.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw GeminiException.Timeout(); }
        int code = (int)resp.StatusCode;
        JsonObject? json = null;
        try { json = JsonNode.Parse(data) as JsonObject; } catch { }

        if (code == 429) throw GeminiException.RateLimited(RetryDelay(json));
        if (code < 200 || code >= 300)
        {
            var msg = json?["error"]?["message"]?.GetValue<string>() ?? data;
            throw GeminiException.Http(code, msg);
        }
        if (json?["candidates"] is not JsonArray cands || cands.Count == 0 || cands[0]?["content"]?["parts"] is not JsonArray parts)
            throw GeminiException.Empty();
        var sb = new StringBuilder();
        foreach (var p in parts)
        {
            if (p?["thought"] is JsonValue tv && tv.TryGetValue<bool>(out var th) && th) continue;
            if (p?["text"] is JsonValue txt && txt.TryGetValue<string>(out var s)) sb.Append(s);
        }
        if (sb.Length == 0) throw GeminiException.Empty();
        return sb.ToString();
    }

    static double? RetryDelay(JsonObject? json)
    {
        if (json?["error"]?["details"] is not JsonArray details) return null;
        foreach (var d in details)
        {
            var t = d?["@type"]?.GetValue<string>();
            var s = d?["retryDelay"]?.GetValue<string>();
            if (t != null && t.EndsWith("RetryInfo") && s != null &&
                double.TryParse(s.Trim('s'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v)) return v;
        }
        return null;
    }

    static string Clean(string s)
    {
        var t = TextUtils.Normalize(s);
        const string q = "\"“”'";
        if (t.Length >= 2 && q.Contains(t[0]) && q.Contains(t[^1])) t = t[1..^1];
        return t;
    }

    /// GET /models: các model hỗ trợ generateContent, ưu tiên flash/lite.
    public static async Task<List<string>> ListModels(string apiKey, string baseURL)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseURL}/models?pageSize=200");
        req.Headers.Add("x-goog-api-key", apiKey);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var resp = await http.SendAsync(req, cts.Token);
        var data = await resp.Content.ReadAsStringAsync();
        JsonObject? json = null;
        try { json = JsonNode.Parse(data) as JsonObject; } catch { }
        int code = (int)resp.StatusCode;
        if (code < 200 || code >= 300) throw GeminiException.Http(code, json?["error"]?["message"]?.GetValue<string>() ?? "");
        var names = new List<string>();
        if (json?["models"] is JsonArray ms)
            foreach (var m in ms)
            {
                var n = m?["name"]?.GetValue<string>();
                if (n == null || m?["supportedGenerationMethods"] is not JsonArray methods) continue;
                if (!methods.Any(x => x?.GetValue<string>() == "generateContent")) continue;
                var id = n.Split('/').Last();
                if (id.Contains("tts") || id.Contains("image") || id.Contains("embedding") || id.Contains("live") || id.Contains("omni")) continue;
                names.Add(id);
            }
        names.Sort((a, b) =>
        {
            bool la = a.Contains("lite"), lb = b.Contains("lite");
            if (la != lb) return la ? -1 : 1;
            return string.CompareOrdinal(b, a);
        });
        return names;
    }

    /// Nút "Test key" trong Cài đặt.
    public static async Task<(bool ok, string message)> Test(string apiKey, string model)
    {
        var b = new GeminiBackend(apiKey, model, 10)
        {
            baseURL = AppSettings.shared.geminiBaseURL,
            targetName = AppSettings.shared.target.englishName,
        };
        try
        {
            var t0 = DateTime.UtcNow;
            var r = await b.Translate("Hello, how are you?", Array.Empty<TranslationPair>());
            return (true, $"{r}  ({(int)(DateTime.UtcNow - t0).TotalMilliseconds} ms)");
        }
        catch (Exception e) { return (false, e.Message); }
    }
}
