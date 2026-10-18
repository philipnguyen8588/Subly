using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;

namespace ScreenTranslator;

/// Đóng gói / khôi phục toàn bộ dữ liệu app thành một file zip, cùng định dạng với bản macOS (BackupArchive.swift)
/// nên khôi phục chéo Mac ↔ Windows được.
///
/// Zip gồm: manifest.json, settings.json ({khoá: giá trị JSON}), secrets/&lt;tên&gt;.txt, history.sqlite, shots/*.jpg.
/// Không gồm: khoá thiết bị, vé, token tài khoản, giọng đọc (tải lại được), log, cache game mẫu.
/// Khôi phục: tải zip → giải nén vào restore-staging\ → khởi động lại app → lúc mở app (trước mọi thứ khác) thay dữ liệu.
public static class BackupArchive
{
    public const int Format = 1;

    /// Key được sao lưu (chữ thường, không mã hoá — người dùng đã chọn vậy). device-key/session/account-token không bao giờ đi theo.
    static readonly string[] SecretNames = { "gemini-api-key", "openai-api-key", "anthropic-api-key", "custom-api-key", "ai-share-token", "ps5host" };

    /// Khoá cài đặt riêng của máy: không sao lưu, khi khôi phục thì giữ giá trị của máy đang dùng.
    static bool IsMachineKey(string k) =>
        new[] { "NS", "Apple", "com.apple.", "WebKit", "rpd." }.Any(k.StartsWith) || k is "runtimeHighWater" or "accountUser" or "mainWindowFrame";

    /// Khoá cùng tên nhưng khác nghĩa giữa Mac và Windows: khôi phục từ hệ điều hành khác thì giữ giá trị của máy này.
    static readonly HashSet<string> PlatformKeys = new()
    {
        "hotkeyToggle", "hotkeyAnalyze", "hotkeyVoice", "hotkeyOverlay", "voiceIdentifier", "voiceEngine",
        "captureScale", "screenCaptureScale", "winCaptureScale", "winScreenCaptureScale", "winVoiceRate",
    };

    static string StagingDir => AppPaths.File("restore-staging");
    static string StagedMarker => Path.Combine(StagingDir, ".ready");
    public static string PreviousDir => AppPaths.File("before-restore");
    static string DoneNote => AppPaths.File("restore-done.json");
    static string ShotsDir => AppPaths.File("shots");   // không dùng AppPaths.Shots (tự tạo thư mục)

    public sealed class Manifest
    {
        public int format { get; set; }
        public string platform { get; set; } = "";
        public string appVersion { get; set; } = "";
        public string machine { get; set; } = "";
        public string machineName { get; set; } = "";
        public double created { get; set; }
        public int profiles { get; set; }
        public int historyRows { get; set; }
        public int shots { get; set; }
        public List<string>? plainKeys { get; set; }
    }

    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    // MARK: sao lưu

    /// Tạo file zip sao lưu trong thư mục tạm. Trả về đường dẫn zip (người gọi xoá thư mục chứa nó sau khi tải lên).
    /// Gọi trên UI thread (chụp DB và cài đặt), phần chép ảnh và nén chạy nền.
    public static async Task<string> Export()
    {
        var work = Path.Combine(Path.GetTempPath(), "subly-backup-" + Guid.NewGuid().ToString("N"));
        var content = Path.Combine(work, "data");
        Directory.CreateDirectory(Path.Combine(content, "secrets"));
        int rows = HistoryStore.shared.Snapshot(Path.Combine(content, "history.sqlite"));
        var settings = AppSettings.shared.Snapshot();
        foreach (var k in settings.Select(p => p.Key).Where(IsMachineKey).ToList()) settings.Remove(k);
        int profileCount = AppSettings.shared.profiles.Count;
        string machine = BackupClient.MachineID, name = HostIdentity.Name;

        return await Task.Run(() =>
        {
            var shotsOut = Directory.CreateDirectory(Path.Combine(content, "shots")).FullName;
            int shots = 0;
            if (Directory.Exists(ShotsDir))
                foreach (var f in Directory.EnumerateFiles(ShotsDir, "*.jpg"))
                {
                    try { File.Copy(f, Path.Combine(shotsOut, Path.GetFileName(f))); shots++; } catch { }
                }
            File.WriteAllText(Path.Combine(content, "settings.json"), settings.ToJsonString(Pretty));
            foreach (var s in SecretNames)
                if (SecretStore.Get(s) is string v && v.Length > 0) File.WriteAllText(Path.Combine(content, "secrets", s + ".txt"), v);
            var m = new Manifest
            {
                format = Format, platform = "win", appVersion = AppInfo.Version, machine = machine, machineName = name,
                created = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0, profiles = profileCount, historyRows = rows, shots = shots,
            };
            File.WriteAllText(Path.Combine(content, "manifest.json"), JsonSerializer.Serialize(m, Pretty));
            var zip = Path.Combine(work, "subly-backup.zip");
            ZipFile.CreateFromDirectory(content, zip, CompressionLevel.Fastest, false);
            try { Directory.Delete(content, true); } catch { }
            return zip;
        });
    }

    // MARK: khôi phục

    static bool AllowedEntry(string name)
    {
        var n = name.Replace('\\', '/');
        if (n is "manifest.json" or "settings.json" or "history.sqlite") return true;
        static bool Flat(string rest, string ext) => rest.Length > ext.Length && rest.EndsWith(ext) && !rest.Contains('/') && !rest.Contains("..");
        return (n.StartsWith("secrets/") && Flat(n[8..], ".txt")) || (n.StartsWith("shots/") && Flat(n[6..], ".jpg"));
    }

    /// Giải nén bản sao lưu đã tải về vào restore-staging\ và kiểm tra; lần mở app tới sẽ áp dụng.
    public static Manifest Stage(string zip)
    {
        if (Directory.Exists(StagingDir)) Directory.Delete(StagingDir, true);
        Directory.CreateDirectory(StagingDir);
        try
        {
            using (var archive = ZipFile.OpenRead(zip))
            {
                foreach (var e in archive.Entries)
                {
                    if (e.FullName.EndsWith("/")) continue;   // mục thư mục
                    if (!AllowedEntry(e.FullName)) throw new BackupClient.BackupException($"File sao lưu không hợp lệ ({e.FullName})");
                    var dest = Path.GetFullPath(Path.Combine(StagingDir, e.FullName.Replace('/', Path.DirectorySeparatorChar)));
                    if (!dest.StartsWith(Path.GetFullPath(StagingDir) + Path.DirectorySeparatorChar)) throw new BackupClient.BackupException("File sao lưu không hợp lệ");
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                    e.ExtractToFile(dest, true);
                }
            }
            var mp = Path.Combine(StagingDir, "manifest.json");
            var m = File.Exists(mp) ? JsonSerializer.Deserialize<Manifest>(File.ReadAllText(mp)) : null;
            if (m == null) throw new BackupClient.BackupException("File sao lưu thiếu manifest.json");
            if (m.format > Format) throw new BackupClient.BackupException("Bản sao lưu được tạo bởi phiên bản app mới hơn, hãy cập nhật app");
            if (!File.Exists(Path.Combine(StagingDir, "settings.json"))) throw new BackupClient.BackupException("File sao lưu thiếu settings.json");
            File.WriteAllText(StagedMarker, "");
            return m;
        }
        catch
        {
            try { Directory.Delete(StagingDir, true); } catch { }
            throw;
        }
    }

    /// Gọi đầu tiên khi mở app (trước khi đọc cài đặt hay mở DB): có bản đã giải nén chờ sẵn thì thay dữ liệu bằng nó.
    public static void ApplyStagedIfAny()
    {
        if (!File.Exists(StagedMarker)) return;
        try { Apply(); }
        catch (Exception e) { Log.Error($"Khôi phục lỗi: {e.Message}"); }
        finally { try { Directory.Delete(StagingDir, true); } catch { } }
    }

    static void Apply()
    {
        var m = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(Path.Combine(StagingDir, "manifest.json")))!;
        var restored = JsonNode.Parse(File.ReadAllText(Path.Combine(StagingDir, "settings.json"))) as JsonObject
                       ?? throw new InvalidDataException("settings.json hỏng");
        bool cross = m.platform != "win";
        Log.Info($"Khôi phục dữ liệu từ {m.machineName} ({m.platform}, {DateTimeOffset.FromUnixTimeSeconds((long)m.created).LocalDateTime})");

        var settingsPath = AppPaths.File("settings.json");
        JsonObject current = new();
        try { if (File.Exists(settingsPath)) current = JsonNode.Parse(File.ReadAllText(settingsPath)) as JsonObject ?? new(); } catch { }

        // 1. Cất dữ liệu hiện tại vào before-restore\ (chỉ giữ một bản) để còn đường lui.
        if (Directory.Exists(PreviousDir)) Directory.Delete(PreviousDir, true);
        Directory.CreateDirectory(Path.Combine(PreviousDir, "secrets"));
        if (File.Exists(settingsPath)) File.Copy(settingsPath, Path.Combine(PreviousDir, "settings.json"));
        foreach (var s in SecretNames)
            if (SecretStore.Get(s) is string v) File.WriteAllText(Path.Combine(PreviousDir, "secrets", s + ".txt"), v);
        foreach (var name in new[] { "history.sqlite", "history.sqlite-wal", "history.sqlite-shm" })
            if (File.Exists(AppPaths.File(name))) File.Move(AppPaths.File(name), Path.Combine(PreviousDir, name));
        if (Directory.Exists(ShotsDir)) Directory.Move(ShotsDir, Path.Combine(PreviousDir, "shots"));

        // 2. Lịch sử + ảnh.
        var db = Path.Combine(StagingDir, "history.sqlite");
        if (File.Exists(db)) File.Move(db, AppPaths.File("history.sqlite"));
        var shots = Path.Combine(StagingDir, "shots");
        if (Directory.Exists(shots)) Directory.Move(shots, ShotsDir);

        // 3. Cài đặt: giữ khoá riêng của máy (và khoá khác nghĩa nếu khác hệ điều hành), còn lại thay bằng bản sao lưu.
        var next = new JsonObject();
        foreach (var (k, v) in current)
            if (IsMachineKey(k) || (cross && PlatformKeys.Contains(k))) next[k] = v?.DeepClone();
        if (cross && restored["profiles"] is JsonArray profiles)
        {
            // Vùng chụp màn hình / cửa sổ app của máy kia không dùng được ở đây; vùng PS5 (toạ độ tỉ lệ) thì giữ.
            foreach (var p in profiles.OfType<JsonObject>())
                if (p["regions"] is JsonArray regions)
                    p["regions"] = new JsonArray(regions.Where(r => r?["embedded"]?.GetValueKind() == JsonValueKind.True).Select(r => r!.DeepClone()).ToArray());
        }
        foreach (var (k, v) in restored)
            if (!IsMachineKey(k) && !(cross && PlatformKeys.Contains(k)) && v != null) next[k] = v.DeepClone();
        var tmp = settingsPath + ".tmp";
        File.WriteAllText(tmp, next.ToJsonString(Pretty));
        File.Move(tmp, settingsPath, true);

        // 4. Key: thay hết bằng bản sao lưu (key không có trong bản sao lưu thì xoá).
        foreach (var s in SecretNames)
        {
            var f = Path.Combine(StagingDir, "secrets", s + ".txt");
            SecretStore.Set(File.Exists(f) ? File.ReadAllText(f).Trim() : "", s);
        }

        File.WriteAllText(DoneNote, JsonSerializer.Serialize(new { name = m.machineName, platform = m.platform, created = m.created }));
        Log.Info($"Khôi phục xong: {m.profiles} game, {m.historyRows} dòng phụ đề, {m.shots} ảnh");
    }

    /// Sau khi mở app: báo đã khôi phục xong (nếu vừa khôi phục).
    public static void AnnounceIfRestored(bool silent)
    {
        if (!File.Exists(DoneNote)) return;
        string name = "?"; double created = 0;
        try
        {
            var o = JsonNode.Parse(File.ReadAllText(DoneNote));
            name = o?["name"]?.GetValue<string>() ?? "?";
            created = o?["created"]?.GetValue<double>() ?? 0;
        }
        catch { }
        try { File.Delete(DoneNote); } catch { }
        var msg = $"Đã khôi phục dữ liệu từ {name} (sao lưu lúc {DateTimeOffset.FromUnixTimeSeconds((long)created).LocalDateTime:dd/MM/yyyy HH:mm}).";
        Log.Info(msg);
        if (!silent)
            MessageBox.Show(msg + "\n\nDữ liệu cũ của máy này được cất ở thư mục before-restore trong thư mục dữ liệu của app.",
                "Khôi phục xong", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    // MARK: khởi động lại

    /// Chờ bản app cũ thoát hẳn (cờ `--after-pid`, do Relaunch() truyền) để kiểm tra "chỉ một bản" không chặn bản mới.
    public static void WaitForPreviousInstance(string[] args)
    {
        int i = Array.IndexOf(args, "--after-pid");
        if (i < 0 || i + 1 >= args.Length || !int.TryParse(args[i + 1], out var pid)) return;
        try { using var p = Process.GetProcessById(pid); p.WaitForExit(15000); }
        catch (ArgumentException) { }   // đã thoát
    }

    /// Mở lại app (bản mới chờ bản này thoát) rồi thoát. Cờ test được truyền tiếp để bản mới vẫn ở chế độ test.
    public static void Relaunch(string[] args)
    {
        var psi = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
        psi.ArgumentList.Add("--after-pid");
        psi.ArgumentList.Add(Environment.ProcessId.ToString());
        foreach (var f in new[] { "--multi", "--mute", "--quiet", "--hidden", "--no-web" })
            if (args.Contains(f)) psi.ArgumentList.Add(f);
        foreach (var o in new[] { "--data-dir", "--server", "--machine-id", "--web-port", "--quit-after" })
        {
            int i = Array.IndexOf(args, o);
            if (i >= 0 && i + 1 < args.Length) { psi.ArgumentList.Add(o); psi.ArgumentList.Add(args[i + 1]); }
        }
        try { Process.Start(psi); } catch (Exception e) { Log.Error($"Không mở lại được app: {e.Message}"); }
        App.Quit();
    }
}
