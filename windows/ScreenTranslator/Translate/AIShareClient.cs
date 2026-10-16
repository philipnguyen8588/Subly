using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// AI share: dùng API key do chủ server chia sẻ mà không bao giờ thấy key. App chỉ giữ một token; mọi request AI đi
/// qua proxy `/v1/ai/<nhà cung cấp>` của server, server kiểm tra model rồi tự gắn key thật (xem server/share.go).
public static class AIShareClient
{
    public sealed class ShareException : Exception
    {
        public readonly int code;
        public ShareException(int code, string message) : base(message) { this.code = code; }
    }

    static AppSettings S => AppSettings.shared;
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(15) };

    /// Bản build có server (hoặc đang test với --share-server).
    public static bool Available => S.forceShareServer != null || RuntimeConfig.Enabled;

    static string? ServerURL => S.forceShareServer ?? (RuntimeConfig.Enabled ? RuntimeConfig.BaseURL : null);

    /// Địa chỉ gốc mà backend của nhà cung cấp gọi tới (thay cho api.openai.com…).
    public static string ProxyBase(string provider) => (ServerURL ?? "") + "/v1/ai/" + provider;

    public static string ProviderName(string p) => p switch
    {
        "openai" => "OpenAI", "anthropic" => "Anthropic Claude", "gemini" => "Gemini", "custom" => "API tuỳ chỉnh", _ => p,
    };

    /// Hỏi server token này dùng nhà cung cấp nào, những model nào.
    public static async Task<AIShareInfo> Info(string token)
    {
        if (ServerURL is not string server) throw new ShareException(0, "Bản app này không có server AI share");
        if (!token.StartsWith("sts_") || token.Length >= 100) throw new ShareException(0, "Token không đúng dạng (bắt đầu bằng sts_)");
        using var req = new HttpRequestMessage(HttpMethod.Get, server + "/v1/share/info");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
        using var resp = await http.SendAsync(req);
        var body = await resp.Content.ReadAsStringAsync();
        JsonNode? obj = null;
        try { obj = JsonNode.Parse(body); } catch { }
        int code = (int)resp.StatusCode;
        if (!resp.IsSuccessStatusCode)
        {
            var msg = obj?["error"]?["message"]?.GetValue<string>() ?? "";
            throw new ShareException(code, msg.Length > 0 ? msg : $"AI share: HTTP {code}");
        }
        var provider = obj?["provider"]?.GetValue<string>();
        var models = obj?["models"]?.AsArray().Select(m => m?.GetValue<string>() ?? "").Where(m => m.Length > 0).ToList();
        if (provider == null || models == null || models.Count == 0) throw new ShareException(code, "Server trả về dữ liệu không hợp lệ");
        return new AIShareInfo { label = obj?["label"]?.GetValue<string>() ?? "", provider = provider, models = models };
    }

    /// Lưu token mới sau khi server xác nhận.
    public static async Task<AIShareInfo> ImportToken(string raw)
    {
        var token = raw.Trim();
        var info = await Info(token);
        S.aiShareToken = token;
        S.aiShare = info;
        Log.Info($"AI share: đã nhập \"{info.label}\" ({ProviderName(info.provider)}, {info.models.Count} model)");
        return info;
    }

    public static void Remove()
    {
        S.aiShareToken = "";
        S.aiShare = null;
    }

    /// Cập nhật danh sách model từ server (admin sửa model / thu hồi). Lỗi mạng thì giữ nguyên thông tin cũ.
    public static async Task<Exception?> Refresh()
    {
        var token = S.aiShareToken;
        var cur = S.aiShare;
        if (token.Length == 0 || cur == null || !Available) return null;
        try
        {
            var fresh = await Info(token);
            if (!fresh.SameAs(cur)) S.aiShare = fresh;
            return null;
        }
        catch (ShareException e) when (e.code == 403)
        {
            if (!cur.revoked) Log.Warn($"AI share: {e.Message}");
            cur.revoked = true;
            S.aiShare = cur;
            return e;
        }
        catch (Exception e) { return e; }
    }

    /// Backend gọi qua proxy cho nhà cung cấp của share (router và nút Kiểm tra dùng chung).
    public static ICloudChatBackend MakeBackend(AIShareInfo info, string token)
    {
        var baseUrl = ProxyBase(info.provider);
        var first = info.models.FirstOrDefault() ?? "";
        return info.provider switch
        {
            "anthropic" => new AnthropicBackend { apiKey = token, baseURL = baseUrl, model = first },
            "gemini" => new GeminiBackend(token, first, 6) { baseURL = baseUrl, fallbacks = info.models.ToArray() },
            _ => new OpenAIBackend { apiKey = token, baseURL = baseUrl, model = first, official = info.provider == "openai" },
        };
    }

    /// Nút "Kiểm tra": dịch thử một câu bằng model này qua proxy.
    public static async Task<(bool ok, string message)> Test(string model)
    {
        await Refresh();
        var info = S.aiShare;
        var token = S.aiShareToken;
        if (info == null || token.Length == 0) return (false, "Chưa nhập AI share");
        if (info.revoked) return (false, "AI share đã bị thu hồi hoặc token không còn hợp lệ");
        if (!info.models.Contains(model)) return (false, $"Model {model} không nằm trong AI share");
        var b = MakeBackend(info, token);
        var prompt = $"Translate the English subtitle into natural {S.target.englishName}. Output only the translation.";
        switch (b)
        {
            case OpenAIBackend o: o.timeout = 15; o.subtitlePrompt = () => prompt; break;
            case AnthropicBackend a: a.timeout = 15; a.subtitlePrompt = () => prompt; break;
            case GeminiBackend g: g.timeout = 15; g.targetName = S.target.englishName; break;
        }
        try
        {
            var t0 = DateTime.UtcNow;
            var r = await b.Translate("Hello, how are you?", Array.Empty<TranslationPair>(), modelOverride: model);
            return (true, $"{r}  ({(int)(DateTime.UtcNow - t0).TotalMilliseconds} ms)");
        }
        catch (Exception e) { return (false, e.Message); }
    }
}
