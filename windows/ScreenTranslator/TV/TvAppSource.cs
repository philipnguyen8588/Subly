using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Mã nguồn app Subtitle TV để ký và cài lên TV: bản mới nhất trên server (GET /v1/tv/app, zip chưa ký, có ETag nên
/// không đổi thì không tải lại), lưu ở %APPDATA%\ScreenTranslator\tv-app. Không tải được thì dùng bản đã tải lần trước,
/// rồi tới bản đóng kèm app. Cập nhật app TV chỉ cần nạp zip mới lên server (server/tvapp.go), không cần build lại Subly.
/// SUBLY_TV_BUNDLED_APP=1: luôn dùng bản đóng kèm. Giống Sources/ScreenTranslator/TV/TvAppSource.swift.
public static class TvAppSource
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(30) };
    static string CacheDir => Path.Combine(AppPaths.Root, "tv-app");
    static string CachedApp => Path.Combine(CacheDir, "SubtitleTV");
    static string EtagFile => Path.Combine(CacheDir, "etag");

    /// Thư mục mã nguồn app TV sẽ cài; null = không có bản nào (không tải được và bản build không kèm sẵn).
    public static async Task<string?> Resolve(string bundled, Action<string> log, CancellationToken ct)
    {
        bool hasCache = File.Exists(Path.Combine(CachedApp, "config.xml"));
        bool hasBundled = File.Exists(Path.Combine(bundled, "config.xml"));
        if (Environment.GetEnvironmentVariable("SUBLY_TV_BUNDLED_APP") != null)
        {
            log("App TV: dùng bản đóng kèm Subly (SUBLY_TV_BUNDLED_APP)" + Version(bundled));
            return hasBundled ? bundled : null;
        }
        if (RuntimeConfig.Server is string server)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, server + "/v1/tv/app");
                if (hasCache && File.Exists(EtagFile)) req.Headers.TryAddWithoutValidation("If-None-Match", File.ReadAllText(EtagFile).Trim());
                using var resp = await http.SendAsync(req, ct);
                if (resp.StatusCode == HttpStatusCode.NotModified)
                {
                    log("App TV: bản mới nhất trên server (đã tải trước đó)" + Version(CachedApp));
                    return CachedApp;
                }
                if (resp.StatusCode == HttpStatusCode.NotFound)
                {
                    log("App TV: server chưa có app TV → dùng bản đóng kèm Subly" + Version(bundled));
                    return hasBundled ? bundled : null;
                }
                if (!resp.IsSuccessStatusCode) throw new InvalidOperationException($"server trả HTTP {(int)resp.StatusCode}");
                Store(await resp.Content.ReadAsByteArrayAsync(ct), resp.Headers.ETag?.ToString());
                log("App TV: đã tải bản mới nhất từ server" + Version(CachedApp));
                Log.Info("TV: đã tải app TV từ server" + Version(CachedApp));
                return CachedApp;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception e)
            {
                Log.Warn($"TV: không tải được app TV từ server: {e.Message}");
                log($"Không tải được app TV từ server ({e.Message}).");
            }
        }
        if (hasCache)
        {
            log("App TV: dùng bản đã tải từ server lần trước" + Version(CachedApp));
            return CachedApp;
        }
        if (hasBundled) log("App TV: dùng bản đóng kèm Subly" + Version(bundled));
        return hasBundled ? bundled : null;
    }

    /// Giải nén vào thư mục tạm, kiểm tra xong mới thay bản cũ (lỗi giữa chừng thì bản cũ vẫn còn).
    static void Store(byte[] zip, string? etag)
    {
        Directory.CreateDirectory(CacheDir);
        var stage = Path.Combine(CacheDir, "new-" + Guid.NewGuid().ToString("N"));
        try
        {
            Extract(zip, stage);
            if (Directory.Exists(CachedApp)) Directory.Delete(CachedApp, true);
            Directory.Move(stage, CachedApp);
            if (etag != null) File.WriteAllText(EtagFile, etag); else File.Delete(EtagFile);
        }
        finally { if (Directory.Exists(stage)) Directory.Delete(stage, true); }
    }

    /// Chỉ nhận tên file an toàn (không ..\, không đường dẫn tuyệt đối), phải có config.xml ở gốc.
    static void Extract(byte[] zip, string dir)
    {
        using var za = new ZipArchive(new MemoryStream(zip), ZipArchiveMode.Read);
        var root = Path.GetFullPath(dir) + Path.DirectorySeparatorChar;
        foreach (var e in za.Entries)
        {
            if (e.FullName.EndsWith("/")) continue;
            var parts = e.FullName.Split('/');
            if (e.FullName.StartsWith("/") || e.FullName.Contains('\\') || e.FullName.Contains(':') || parts.Any(p => p is "" or "." or ".."))
                throw new InvalidOperationException("zip app TV có tên file không hợp lệ: " + e.FullName);
            var dst = Path.GetFullPath(Path.Combine(dir, e.FullName));
            if (!dst.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("zip app TV có tên file không hợp lệ: " + e.FullName);
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            e.ExtractToFile(dst, true);
        }
        if (!File.Exists(Path.Combine(dir, "config.xml"))) throw new InvalidOperationException("zip app TV không có config.xml ở thư mục gốc");
    }

    /// " (version 1.0.0)" theo config.xml, rỗng nếu không đọc được.
    static string Version(string app)
    {
        try
        {
            var m = Regex.Match(File.ReadAllText(Path.Combine(app, "config.xml")), "<widget\\b[^>]*?\\bversion=\"([^\"]+)\"");
            return m.Success ? $" (version {m.Groups[1].Value})" : "";
        }
        catch { return ""; }
    }
}
