using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Một bản sao lưu trên server (mỗi máy một bản).
public sealed class BackupInfo
{
    public string machine { get; set; } = "";
    public string name { get; set; } = "";
    public string platform { get; set; } = "";
    public string appVersion { get; set; } = "";
    public string ip { get; set; } = "";
    public long size { get; set; }
    public string sha256 { get; set; } = "";
    public double created { get; set; }
    public DateTime Date => DateTimeOffset.FromUnixTimeMilliseconds((long)(created * 1000)).LocalDateTime;
    public string PlatformLabel => platform == "win" ? "Windows" : platform == "mac" ? "Mac" : "?";
}

/// Gọi API tài khoản / sao lưu của server (server/backup.go). Token đăng nhập giữ trong SecretStore "account-token".
public static class BackupClient
{
    public sealed class BackupException : Exception
    {
        public readonly bool unauthorized;
        public BackupException(string message, bool unauthorized = false) : base(message) { this.unauthorized = unauthorized; }
    }

    public const string TokenName = "account-token";
    public static string Token => SecretStore.Get(TokenName) ?? "";
    public static bool Available => RuntimeConfig.Server != null;
    static readonly HttpClient http = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// Mã máy: HostIdentity.Hash. `--machine-id <64 hex>` thay mã khi test (giả làm máy khác).
    public static string MachineID
    {
        get
        {
            var a = Environment.GetCommandLineArgs();
            int i = Array.IndexOf(a, "--machine-id");
            return i >= 0 && i + 1 < a.Length && a[i + 1].Length == 64 ? a[i + 1].ToLowerInvariant() : HostIdentity.Hash;
        }
    }

    static HttpRequestMessage Request(HttpMethod method, string path)
    {
        if (RuntimeConfig.Server is not string server) throw new BackupException("Bản app này không có server sao lưu");
        var req = new HttpRequestMessage(method, server + path);
        var t = Token;
        if (t.Length > 0) req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + t);
        return req;
    }

    static async Task Check(HttpResponseMessage resp)
    {
        if (resp.IsSuccessStatusCode) return;
        string? msg = null;
        try { msg = JsonNode.Parse(await resp.Content.ReadAsStringAsync())?["error"]?.GetValue<string>(); } catch { }
        int code = (int)resp.StatusCode;
        throw new BackupException(msg ?? $"Lỗi server (HTTP {code})", code == 401);
    }

    static async Task<HttpResponseMessage> Send(HttpRequestMessage req, TimeSpan timeout, HttpCompletionOption opt = HttpCompletionOption.ResponseContentRead)
    {
        using var cts = new CancellationTokenSource(timeout);
        try { return await http.SendAsync(req, opt, cts.Token); }
        catch (TaskCanceledException) { throw new BackupException("Hết thời gian chờ server"); }
        catch (HttpRequestException) { throw new BackupException("Không kết nối được server"); }
    }

    /// Đăng nhập; trả về tên đăng nhập (đã chuẩn hoá) và lưu token.
    public static async Task<string> Login(string username, string password)
    {
        using var req = Request(HttpMethod.Post, "/v1/account/login");
        req.Headers.Remove("Authorization");
        var body = JsonSerializer.Serialize(new { username, password, device = HostIdentity.Name });
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        using var resp = await Send(req, TimeSpan.FromSeconds(20));
        await Check(resp);
        var obj = JsonNode.Parse(await resp.Content.ReadAsStringAsync());
        var tok = obj?["token"]?.GetValue<string>() ?? throw new BackupException("Server trả về dữ liệu không hợp lệ");
        SecretStore.Set(tok, TokenName);
        return obj?["username"]?.GetValue<string>() ?? username;
    }

    public static async Task Logout()
    {
        try
        {
            using var req = Request(HttpMethod.Post, "/v1/account/logout");
            using var _ = await Send(req, TimeSpan.FromSeconds(8));
        }
        catch { }
        SecretStore.Set("", TokenName);
    }

    public static async Task<List<BackupInfo>> List()
    {
        using var req = Request(HttpMethod.Get, "/v1/backups");
        using var resp = await Send(req, TimeSpan.FromSeconds(20));
        await Check(resp);
        var obj = JsonNode.Parse(await resp.Content.ReadAsStringAsync());
        return obj?["backups"]?.Deserialize<List<BackupInfo>>() ?? new();
    }

    public static async Task Delete(string machine)
    {
        using var req = Request(HttpMethod.Delete, "/v1/backups/" + machine);
        using var resp = await Send(req, TimeSpan.FromSeconds(20));
        await Check(resp);
    }

    /// Tải file zip lên làm bản sao lưu của máy này (ghi đè bản cũ).
    public static async Task<BackupInfo> Upload(string file, Action<double> progress)
    {
        var q = $"?name={Uri.EscapeDataString(HostIdentity.Name)}&platform=win&v={Uri.EscapeDataString(AppInfo.Version)}";
        using var req = Request(HttpMethod.Put, "/v1/backups/" + MachineID + q);
        await using var fs = File.OpenRead(file);
        req.Content = new ProgressContent(fs, progress);
        req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/zip");
        req.Content.Headers.ContentLength = fs.Length;
        using var resp = await Send(req, TimeSpan.FromMinutes(10));
        await Check(resp);
        return JsonSerializer.Deserialize<BackupInfo>(await resp.Content.ReadAsStringAsync()) ?? throw new BackupException("Server trả về dữ liệu không hợp lệ");
    }

    /// Tải bản sao lưu của một máy về file `dest`.
    public static async Task Download(string machine, string dest, Action<double> progress)
    {
        using var req = Request(HttpMethod.Get, "/v1/backups/" + machine);
        using var resp = await Send(req, TimeSpan.FromMinutes(10), HttpCompletionOption.ResponseHeadersRead);
        await Check(resp);
        long total = resp.Content.Headers.ContentLength ?? 0, done = 0;
        await using var src = await resp.Content.ReadAsStreamAsync();
        await using var dst = File.Create(dest);
        var buf = new byte[81920];
        int n;
        while ((n = await src.ReadAsync(buf)) > 0)
        {
            await dst.WriteAsync(buf.AsMemory(0, n));
            done += n;
            if (total > 0) progress((double)done / total);
        }
    }

    /// Nội dung tải lên có báo tiến độ.
    sealed class ProgressContent : HttpContent
    {
        readonly Stream src;
        readonly Action<double> progress;
        public ProgressContent(Stream src, Action<double> progress) { this.src = src; this.progress = progress; }

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            var buf = new byte[81920];
            long done = 0, total = src.Length;
            int n;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await stream.WriteAsync(buf.AsMemory(0, n));
                done += n;
                if (total > 0) progress((double)done / total);
            }
        }

        protected override bool TryComputeLength(out long length) { length = src.Length; return true; }
    }
}
