using System;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Gọi server để lấy vé. Tên trường ngắn và trung tính (khớp server/api.go).
/// Tương đương SessionClient.swift của bản macOS; nền tảng gửi "win".
public static class SessionClient
{
    public enum ResultKind { Ticket, Denied, Unreachable }

    public readonly struct Result
    {
        public readonly ResultKind Kind;
        public readonly string? Ticket;
        Result(ResultKind kind, string? ticket) { Kind = kind; Ticket = ticket; }
        public static Result OfTicket(string t) => new(ResultKind.Ticket, t);
        public static readonly Result Denied = new(ResultKind.Denied, null);
        public static readonly Result Unreachable = new(ResultKind.Unreachable, null);
    }

    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(12) };

    public static async Task<Result> FetchTicket()
    {
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var hash = HostIdentity.Hash;
        var pub = HostKey.PublicKeyB64;
        var sig = HostKey.Sign($"s1|{hash}|{pub}|{ts}");
        var body = new
        {
            h = hash, k = pub, n = HostIdentity.Name, e = AppSettings.shared.userEmail,
            u = HostIdentity.User, m = HostIdentity.Model,
            p = "win", o = HostIdentity.OsVersion, v = AppInfo.Version, ts, s = sig,
        };

        try
        {
            var json = JsonSerializer.Serialize(body);
            using var req = new HttpRequestMessage(HttpMethod.Post, RuntimeConfig.Endpoint)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json"),
            };
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return Result.Denied;
            var data = await resp.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            if (root.TryGetProperty("c", out var c) && c.GetInt32() == 0
                && root.TryGetProperty("t", out var t) && t.GetString() is string ticket && ticket.Length > 0)
                return Result.OfTicket(ticket);
            return Result.Denied;
        }
        catch { return Result.Unreachable; }
    }
}

public static class AppInfo
{
    public static string Version
    {
        get
        {
            var v = Assembly.GetEntryAssembly()?.GetName().Version;
            return v == null ? "0" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    /// Nhãn phiên bản hiện ở header / màn email, ví dụ "v1.0.0".
    public static string VersionLabel => $"v{Version}";

    // Hỗ trợ: app miễn phí, liên hệ Telegram (khớp bản macOS).
    public const string TelegramGroup = "subly_ps";
    public const string TelegramOwner = "lipnguyen";
    public static string SupportLine =>
        $"Đây là app miễn phí. Cần hỗ trợ cài đặt, liên hệ Telegram @{TelegramGroup} hoặc @{TelegramOwner}.";
}
