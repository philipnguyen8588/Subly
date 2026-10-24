using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Xml.Linq;

namespace ScreenTranslator;

/// Cài app Subtitle TV lên TV Samsung (Tizen) ngay từ app Windows, không cần Tizen Studio.
/// Port từ windows\tizen\auto-install.ps1 (đã chạy thật):
///   1. Kết nối TV bằng sdb.exe (TV bật Developer Mode, Host PC IP = máy này), lấy DUID.
///   2. Tìm các bộ chứng chỉ có DUID này (%APPDATA%\ScreenTranslator\tv-certs, %USERPROFILE%\SamsungCertificate).
///      Không có → đăng nhập Samsung, xin chứng chỉ vào tv-certs\Subly-Auto (SamsungCert).
///   3. Lấy mã nguồn app TV mới nhất trên server (TvAppSource; mất mạng thì bản đã tải / bản đóng kèm),
///      ký (WgtSigner) rồi cài. TV báo "Author certificate not match" (app đã cài bằng chứng chỉ tác giả khác) →
///      thử bộ kế; hết bộ → hỏi gỡ app cũ rồi cài lại.
public static class TvInstaller
{
    static string TvDir => Path.Combine(AppPaths.AppDir, "tv");
    static string Sdb => Path.Combine(TvDir, "sdb.exe");
    /// Bản app TV đóng kèm, chỉ để dự phòng: bản dùng để cài lấy từ server (TvAppSource).
    static string BundledApp => Path.Combine(TvDir, "SubtitleTV");
    static string CaDir => Path.Combine(TvDir, "ca");
    public static string CertRoot => Path.Combine(AppPaths.Root, "tv-certs");
    static string SharedCertRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "SamsungCertificate");
    const string Remote = "/home/owner/share/tmp/sdk_tools/tmp/SubtitleTV.wgt";

    /// null = đủ file để cài; khác null = lý do không cài được (bản build thiếu file). Mã nguồn app TV kiểm tra lúc cài
    /// (có thể tải từ server).
    public static string? MissingFiles() =>
        !File.Exists(Sdb) ? "Bản Subly này thiếu sdb.exe (công cụ kết nối TV) nên không cài được app lên TV." : null;

    /// Cài + mở app trên TV. `confirmUninstall`: hỏi người dùng có gỡ app cũ không (chạy trên UI thread).
    public static async Task Install(string ip, Action<string> log, Func<bool> confirmUninstall, CancellationToken ct)
    {
        if (MissingFiles() is string miss) throw new InvalidOperationException(miss);
        var appSrc = await TvAppSource.Resolve(BundledApp, log, ct)
            ?? throw new InvalidOperationException("Không tải được app TV từ server và bản Subly này không kèm sẵn app TV. Kiểm tra mạng rồi thử lại.");
        var cfg = XDocument.Load(Path.Combine(appSrc, "config.xml"));
        var appEl = cfg.Descendants().First(e => e.Name.LocalName == "application");
        string appId = (string)appEl.Attribute("id")!, pkgId = (string)appEl.Attribute("package")!;
        var serial = $"{ip}:26101";

        log($"Kết nối TV {ip}…");
        var c = await Run(ct, "connect", ip);
        if (!c.Contains("connected", StringComparison.OrdinalIgnoreCase) || c.Contains("failed", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Không kết nối được TV {ip}. Kiểm tra: TV bật Developer Mode (Apps → bấm 1 2 3 4 5), " +
                "Host PC IP là IP máy này, đã tắt rồi mở lại TV, TV và máy tính cùng mạng.\n" + c.Trim());
        var duid = (await Run(ct, "-s", serial, "shell", "0", "getduid")).Trim();
        if (!Regex.IsMatch(duid, "^[A-Z0-9]{8,}$")) throw new InvalidOperationException($"Không đọc được mã DUID của TV (nhận được: '{duid}')");
        log("Mã TV (DUID): " + duid);

        var sets = CertSets().Where(s => s.duids.Contains(duid)).ToList();
        if (sets.Count > 0) log("TV đã có chứng chỉ (" + string.Join(", ", sets.Select(s => s.name)) + ") → không cần đăng nhập Samsung.");
        else
        {
            log("TV này chưa có chứng chỉ → xin chứng chỉ Samsung (cần đăng nhập Samsung Account).");
            var dir = Path.Combine(CertRoot, "Subly-Auto");
            await SamsungCert.Request(dir, new[] { duid }, CaDir, log, ct);
            sets = CertSets().Where(s => s.dir == dir && s.duids.Contains(duid)).ToList();
            if (sets.Count == 0) throw new InvalidOperationException("Đã xin chứng chỉ nhưng không đọc lại được.");
        }

        var wgt = Path.Combine(Path.GetTempPath(), "SubtitleTV.wgt");
        async Task<string> InstallWith(CertSet s)
        {
            log($"Ký app bằng chứng chỉ '{s.name}' và cài lên TV…");
            WgtSigner.Sign(appSrc, wgt, Path.Combine(s.dir, "author.p12"), s.authorPassword, Path.Combine(s.dir, "distributor.p12"), s.distributorPassword);
            await Run(ct, "-s", serial, "push", wgt, Remote);
            var res = await Run(ct, "-s", serial, "shell", "0", "vd_appinstall", pkgId, Remote);
            var line = res.Split('\n').Select(l => l.Trim()).LastOrDefault(l => Regex.IsMatch(l, "install (failed|completed)")) ?? res.Trim();
            log(line);
            return res;
        }

        bool done = false, authorMismatch = false;
        foreach (var s in sets)
        {
            var res = await InstallWith(s);
            if (res.Contains("install completed")) { done = true; break; }
            if (res.Contains("Author certificate not match")) { authorMismatch = true; continue; }   // thử bộ kế
            break;
        }
        if (!done && authorMismatch && confirmUninstall())
        {
            log("Gỡ app cũ trên TV…");
            await Run(ct, "-s", serial, "shell", "0", "vd_appuninstall", pkgId);
            done = (await InstallWith(sets[0])).Contains("install completed");
        }
        if (!done) throw new InvalidOperationException(authorMismatch
            ? "TV đã có Subtitle TV cài bằng chứng chỉ khác nên không cài đè được (cần gỡ app cũ)."
            : "TV không nhận gói cài (xem dòng 'install failed' ở trên).");
        await Run(ct, "-s", serial, "shell", "0", "was_kill", appId);
        await Run(ct, "-s", serial, "shell", "0", "execute", appId);
        log("Xong: Subtitle TV đã cài và mở trên TV.");
        Log.Info($"TV: đã cài Subtitle TV lên {ip} (DUID {duid})");
    }

    // ---------- Bộ chứng chỉ ----------
    sealed record CertSet(string name, string dir, HashSet<string> duids, string authorPassword, string distributorPassword);

    /// Bộ chứng chỉ dùng được: có author.p12 + distributor.p12 + mật khẩu đọc được. Bộ của app trước, rồi của
    /// Certificate Manager (máy có Tizen Studio). SUBLY_TV_NO_SHARED_CERTS=1 bỏ qua bộ dùng chung (kiểm thử).
    static IEnumerable<CertSet> CertSets()
    {
        var roots = new List<string> { CertRoot };
        if (Environment.GetEnvironmentVariable("SUBLY_TV_NO_SHARED_CERTS") == null) roots.Add(SharedCertRoot);
        foreach (var root in roots.Where(Directory.Exists))
            foreach (var dir in Directory.GetDirectories(root))
            {
                if (!File.Exists(Path.Combine(dir, "author.p12")) || !File.Exists(Path.Combine(dir, "distributor.p12"))) continue;
                var a = Password(dir, "author"); var d = Password(dir, "distributor") ?? a;
                if (a == null || d == null) continue;
                yield return new CertSet(Path.GetFileName(dir), dir, Duids(dir), a, d);
            }
    }

    static HashSet<string> Duids(string dir)
    {
        var set = new HashSet<string>();
        var txt = Path.Combine(dir, "duids.txt");
        if (File.Exists(txt)) foreach (var l in File.ReadAllLines(txt)) if (l.Trim().Length > 0) set.Add(l.Trim());
        var xml = Path.Combine(dir, "device-profile.xml");
        if (File.Exists(xml)) foreach (Match m in Regex.Matches(File.ReadAllText(xml), "<TestDevice>([^<]+)</TestDevice>")) set.Add(m.Groups[1].Value);
        return set;
    }

    /// password.txt / <which>.password.txt, hoặc <which>.pwd của Certificate Manager (DPAPI tài khoản Windows này,
    /// 4 byte đầu là độ dài).
    static string? Password(string dir, string which)
    {
        foreach (var f in new[] { $"{which}.password.txt", "password.txt" })
            if (File.Exists(Path.Combine(dir, f))) return File.ReadAllText(Path.Combine(dir, f)).Trim();
        var pwd = Path.Combine(dir, $"{which}.pwd");
        if (!File.Exists(pwd)) return null;
        try
        {
            var b = File.ReadAllBytes(pwd);
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(b[4..], null, DataProtectionScope.CurrentUser));
        }
        catch { return null; }
    }

    // ---------- sdb ----------
    static async Task<string> Run(CancellationToken ct, params string[] args)
    {
        var psi = new ProcessStartInfo(Sdb) { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var outTask = p.StandardOutput.ReadToEndAsync(ct);
        var errTask = p.StandardError.ReadToEndAsync(ct);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(3));
        try { await p.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch { }
            ct.ThrowIfCancellationRequested();
            throw new TimeoutException("sdb không trả lời (TV mất kết nối?)");
        }
        return (await outTask) + (await errTask);
    }
}
