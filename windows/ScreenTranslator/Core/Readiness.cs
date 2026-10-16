using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Windows;

namespace ScreenTranslator;

/// Kiểm tra cài đặt AI trước khi cho Bắt đầu, riêng cho từng việc (dịch phụ đề, dịch màn hình, tóm tắt & cốt truyện):
/// đã chọn AI, có model, có key và key đã "Kiểm tra" thành công với đúng model đó (tương đương Readiness.swift).
/// Google Translate không cần key (tương đương engine offline của bản macOS).
public static class Readiness
{
    public record Issue(string title, string detail, string tab);

    /// Engine đang dùng cho một việc: tên ngắn, nhà cung cấp qua mạng (null = Google Translate, không cần key) và model.
    public record TaskEngine(AITask task, string name, string? provider)
    {
        public string model => provider == null ? "" : Model(task, provider);
        public bool keyless => provider == null;
    }

    public static readonly AITask[] allTasks = { AITask.subtitle, AITask.screen, AITask.summary };

    static AppSettings S => AppSettings.shared;

    // MARK: tên

    /// Nhà cung cấp AI qua mạng của engine dịch phụ đề; null = Google Translate.
    public static string? Provider(TranslationEngine e) => e switch
    {
        TranslationEngine.auto => "gemini",
        TranslationEngine.openAI => "openAI",
        TranslationEngine.anthropic => "anthropic",
        TranslationEngine.custom => "custom",
        TranslationEngine.shared => "shared",
        _ => null,
    };

    public static string ProviderName(string p) => p switch
    {
        "gemini" => "Gemini", "openAI" => "OpenAI", "anthropic" => "Anthropic Claude", "custom" => "API tuỳ chỉnh", "shared" => "AI share", _ => p,
    };

    public static string ShortEngine(TranslationEngine e) => Provider(e) is string p ? ProviderName(p) : "Google Translate";

    public static string TaskTitle(AITask t) => t switch
    {
        AITask.subtitle => "Dịch phụ đề", AITask.screen => "Dịch màn hình", _ => "Tóm tắt & cốt truyện",
    };

    public static string TaskGlyph(AITask t) => t switch
    {
        AITask.subtitle => "", AITask.screen => "", _ => "",
    };

    /// Model thật sự dùng cho một việc với nhà cung cấp này (model riêng của việc, không có thì model mặc định ở mục AI).
    public static string Model(AITask task, string p) => S.TaskModel(task, p) ?? S.DefaultModel(p);

    public static TaskEngine Engine(AITask t)
    {
        switch (t)
        {
            case AITask.subtitle:
            {
                var p = Provider(S.engine);
                return new(t, p == null ? "Google Translate" : ProviderName(p), p);
            }
            case AITask.screen:
            {
                var e = S.effectiveScreenEngine;
                if (e == ScreenEngine.google) return new(t, "Google Translate", null);
                var p = e.ToString();
                return new(t, ProviderName(p), p);
            }
            default:
            {
                var p = S.effectiveSummaryEngine.ToString();
                return new(t, ProviderName(p), p);
            }
        }
    }

    public static List<string> SavedKeys(string p) => p switch
    {
        "gemini" => S.geminiAPIKeys,
        "openAI" => S.openAIKey.Length == 0 ? new() : new() { S.openAIKey },
        "anthropic" => S.anthropicKey.Length == 0 ? new() : new() { S.anthropicKey },
        "custom" => new() { S.customKey },
        "shared" => S.aiShareToken.Length == 0 || S.aiShare == null ? new() : new() { S.aiShareToken },
        _ => new(),
    };

    /// Việc nào đang dùng nhà cung cấp này (để hiện ở mục AI).
    public static List<AITask> TasksUsing(string p) => allTasks.Where(t => Engine(t).provider == p).ToList();

    // MARK: kết quả test

    static string Signature(string p, string model, string key)
    {
        var baseUrl = p == "custom" ? S.customBaseURL.Trim() : "";
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{p}|{model}|{baseUrl}|{key}"));
        return Convert.ToHexString(hash, 0, 12).ToLowerInvariant();
    }

    /// Ghi nhận một lần test: thành công thì nhớ, lỗi thì quên cặp này.
    public static void Record(string p, string model, string key, bool ok)
    {
        var sig = Signature(p, model, key);
        var cur = S.aiVerified;
        var list = cur.Where(x => x != sig).ToList();
        if (ok) list.Add(sig);
        if (list.Count > 64) list.RemoveRange(0, list.Count - 64);
        if (!list.SequenceEqual(cur)) S.aiVerified = list;
    }

    public static bool IsVerified(string p, string model, string key) => S.aiVerified.Contains(Signature(p, model, key));

    /// Nhà cung cấp đã có ít nhất một key (đang lưu) test thành công với model này.
    public static bool IsVerified(string p, string model) => SavedKeys(p).Any(k => IsVerified(p, model, k));

    /// Gọi thử một key với một model.
    public static Task<(bool ok, string message)> Call(string p, string key, string model) => p switch
    {
        "gemini" => GeminiBackend.Test(key, model),
        "openAI" => OpenAIBackend.Test(key, model),
        "anthropic" => AnthropicBackend.Test(key, model),
        "shared" => AIShareClient.Test(model),
        _ => OpenAIBackend.Test(key, model, OpenAIBackend.NormalizeBaseURL(S.customBaseURL), requiresKey: false),
    };

    /// Test một cặp nhà cung cấp + model bằng mọi key đã lưu, ghi nhận kết quả từng key.
    public static async Task<(bool ok, string message)> Test(string p, string model)
    {
        var keys = SavedKeys(p);
        if (model.Length == 0) return (false, $"Chưa chọn model cho {ProviderName(p)}");
        if (p != "custom" && keys.All(k => k.Length == 0)) return (false, $"Chưa có key {ProviderName(p)}");
        (bool ok, string message) last = (false, "Chưa có key");
        int okCount = 0;
        foreach (var k in keys.Where(k => p == "custom" || k.Length > 0))
        {
            var r = await Call(p, k, model);
            if (r.ok) okCount++;
            Record(p, model, k, r.ok);
            last = r;
        }
        if (okCount > 0 && keys.Count > 1) return (true, $"{okCount}/{keys.Count} key dùng được");
        return last;
    }

    /// Test một việc (nút "Kiểm tra" của khối đó).
    public static Task<(bool ok, string message)> Test(AITask t)
    {
        var e = Engine(t);
        return e.provider == null ? Task.FromResult((true, "Google Translate, không cần key")) : Test(e.provider, e.model);
    }

    /// Test mọi việc dùng AI qua mạng mà chưa kiểm tra (mỗi cặp nhà cung cấp + model một lần). Trả về lỗi đầu tiên (null = OK).
    public static async Task<string?> TestAll()
    {
        var done = new HashSet<string>();
        string? firstError = null;
        foreach (var t in allTasks)
        {
            var e = Engine(t);
            if (e.provider is not string p || !done.Add($"{p}|{e.model}") || IsVerified(p, e.model)) continue;
            var r = await Test(p, e.model);
            if (!r.ok && firstError == null) firstError = $"{TaskTitle(t)}: {r.message}";
        }
        return firstError;
    }

    // MARK: kiểm tra

    /// Việc còn thiếu của một việc (null = sẵn sàng). Tiêu đề ngắn để hiện trong nhãn trạng thái.
    public static Issue? IssueOf(AITask t)
    {
        var e = Engine(t);
        var what = TaskTitle(t);
        if (e.provider is not string p) return null;
        var name = ProviderName(p);
        if (p == "shared")
        {
            if (S.aiShare is not AIShareInfo info || S.aiShareToken.Length == 0)
                return new("Chưa nhập AI share", $"{what}: dán token AI share trong Cài đặt → AI, hoặc chọn AI khác.", "ai");
            if (info.revoked)
                return new("AI share bị thu hồi", $"{what}: token AI share không còn dùng được. Xin token mới hoặc chọn AI khác.", "ai");
        }
        else if (p == "custom")
        {
            if (S.customBaseURL.Trim().Length == 0) return new("Chưa có địa chỉ API", $"{what}: nhập địa chỉ máy chủ API tuỳ chỉnh trong Cài đặt → AI.", "ai");
        }
        else if (SavedKeys(p).Count == 0) return new($"Chưa có key {name}", $"{what}: nhập và lưu key {name} trong Cài đặt → AI.", "ai");
        if (e.model.Length == 0) return new("Chưa chọn model", $"{what}: chọn model {name} trong Cài đặt → Dịch.", "translate");
        if (!IsVerified(p, e.model))
            return new("Chưa kiểm tra", $"{what}: bấm “Kiểm tra” để thử {name} · {e.model}. Đổi key hoặc model thì cần kiểm tra lại.", "translate");
        return null;
    }

    /// Tóm tắt & cốt truyện chỉ bắt buộc khi bật tự viết cốt truyện.
    public static bool IsRequired(AITask t) => t != AITask.summary || S.storyOn;

    /// Danh sách việc còn thiếu (chỉ các việc bắt buộc); rỗng = được bắt đầu.
    public static List<Issue> Check() =>
        S.forceReady ? new() : allTasks.Where(IsRequired).Select(IssueOf).OfType<Issue>().ToList();

    /// Báo việc còn thiếu, có nút mở đúng trang Cài đặt.
    public static void Alert(List<Issue> issues)
    {
        if (issues.Count == 0) return;
        Log.Warn($"Chưa sẵn sàng để bắt đầu: {string.Join("; ", issues.Select(i => i.detail))}");
        if (S.suppressAlerts) return;
        var r = MessageBox.Show(string.Join("\n\n", issues.Select(i => i.detail)) + "\n\nMở Cài đặt ngay?", "Chưa cài đặt xong phần dịch",
            MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (r == MessageBoxResult.Yes) App.ShowSettings(issues[0].tab);
    }

    /// Kiểm tra và báo; true = được bắt đầu.
    public static bool Ensure()
    {
        var issues = Check();
        if (issues.Count > 0) Alert(issues);
        return issues.Count == 0;
    }
}
