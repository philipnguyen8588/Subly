using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Xin chứng chỉ Samsung (author + distributor có DUID của TV) mà không cần Certificate Manager.
/// Port từ windows\tizen\samsung-cert.ps1 (cách làm theo tool mã nguồn mở Apps2Samsung, MIT; đã chạy thật):
///   1. Mở trang đăng nhập Samsung Account trên trình duyệt; người dùng tự đăng nhập.
///   2. Samsung POST token về http://localhost:4794/signin/callback (máy này nghe cổng đó).
///   3. Tạo khoá RSA + CSR, gửi svdca.samsungqbe.com ký; CSR distributor ghi DUID của các TV.
///   4. Ghép author.p12 / distributor.p12 (kèm CA trung gian) để ký app.
/// Thư mục chứng chỉ cộng dồn DUID (tối đa 10); lần sau chỉ xin lại distributor, author giữ nguyên khoá → app đã cài
/// trên TV cũ vẫn cập nhật được.
public static class SamsungCert
{
    const string SignIn = "https://account.samsung.com/accounts/be1dce529476c1a6d407c4c7578c31bd/signInGate";
    const string ClientId = "v285zxnl3h";   // client id của Tizen Studio
    const string State = "accountcheckdogeneratedstatetext";
    const int Port = 4794;                   // Samsung chỉ chấp nhận redirect về đúng cổng này
    const int MaxDuids = 10;
    /// Đổi được khi kiểm thử với máy chủ giả (biến môi trường SUBLY_TV_CERT_API).
    static string Api => Environment.GetEnvironmentVariable("SUBLY_TV_CERT_API") ?? "https://svdca.samsungqbe.com/apis";
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(60) };

    public sealed record Auth(string accessToken, string userId, string email);

    /// Xin (hoặc xin lại) chứng chỉ vào `dir` cho các DUID (cộng với DUID đã có trong dir). `caDir`: CA của Samsung.
    public static async Task Request(string dir, IEnumerable<string> newDuids, string caDir, Action<string> log, CancellationToken ct)
    {
        Directory.CreateDirectory(dir);
        string P(string n) => Path.Combine(dir, n);
        var duids = File.Exists(P("duids.txt")) ? File.ReadAllLines(P("duids.txt")).Select(l => l.Trim()).Where(l => l.Length > 0).ToList() : new List<string>();
        foreach (var d in newDuids) if (!duids.Contains(d)) duids.Add(d);
        if (duids.Count > MaxDuids) duids = duids.Skip(duids.Count - MaxDuids).ToList();

        var auth = await Login(log, ct);

        RSA key; string password;
        if (File.Exists(P("author.p12")) && File.Exists(P("password.txt")))
        {
            password = File.ReadAllText(P("password.txt")).Trim();
            var col = new X509Certificate2Collection();
            col.Import(P("author.p12"), password, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet);
            // Khoá đọc từ .p12 chỉ cho xuất dạng mã hoá (không xuất trần được) → CopyWithPrivateKey lỗi. Chép sang khoá
            // mới trong bộ nhớ qua PKCS#8 có mã hoá.
            var src = col.First(c => c.HasPrivateKey).GetRSAPrivateKey()!;
            var pbe = new PbeParameters(PbeEncryptionAlgorithm.TripleDes3KeyPkcs12, HashAlgorithmName.SHA1, 2048);
            key = RSA.Create();
            key.ImportEncryptedPkcs8PrivateKey(password, src.ExportEncryptedPkcs8PrivateKey(password, pbe), out _);
            log("Dùng lại chứng chỉ tác giả có sẵn, chỉ xin lại chứng chỉ phân phối.");
        }
        else
        {
            password = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18)).Replace('+', 'x').Replace('/', 'y');
            key = RSA.Create(2048);
            log("Xin chứng chỉ tác giả…");
            var author = await Post("v3/authors", auth, Csr(key, "CN=Subly", null), "author.csr", null, ct);
            File.WriteAllBytes(P("signed_author.cer"), author);
            WriteP12(P("author.p12"), key, author, Path.Combine(caDir, "vd_tizen_dev_author_ca.cer"), password);
            File.WriteAllText(P("password.txt"), password);
        }

        log("Xin chứng chỉ phân phối cho TV: " + string.Join(", ", duids));
        var csr = Csr(key, $"E={auth.email}, CN=TizenSDK", new[] { "URN:tizen:packageid=" }.Concat(duids.Select(d => "URN:tizen:deviceid=" + d)));
        var extra = new Dictionary<string, string> { ["privilege_level"] = "public", ["developer_type"] = "Individual" };
        File.WriteAllBytes(P("device-profile.xml"), await Post("v1/distributors", auth, csr, "distributor.csr", extra, ct));
        var dist = await Post("v3/distributors", auth, csr, "distributor.csr", extra, ct);
        File.WriteAllBytes(P("signed_distributor.cer"), dist);
        WriteP12(P("distributor.p12"), key, dist, Path.Combine(caDir, "vd_tizen_dev_public2.crt"), password);
        File.WriteAllLines(P("duids.txt"), duids);
        log("Đã có chứng chỉ Samsung cho TV này.");
    }

    // ---------- 1–2. Đăng nhập Samsung Account ----------
    static async Task<Auth> Login(Action<string> log, CancellationToken ct)
    {
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://localhost:{Port}/");
        try { listener.Start(); }
        catch (Exception e) { throw new InvalidOperationException($"Không mở được cổng {Port} để nhận đăng nhập Samsung (Certificate Manager / Tizen Studio đang mở?): {e.Message}"); }
        var redirect = Uri.EscapeDataString($"http://localhost:{Port}/signin/callback");
        var url = $"{SignIn}?locale=&clientId={ClientId}&redirect_uri={redirect}&state={State}&tokenType=TOKEN";
        log("Đang mở trang đăng nhập Samsung Account trên trình duyệt — đăng nhập để tiếp tục…");
        if (Environment.GetEnvironmentVariable("SUBLY_TV_CERT_NOBROWSER") == null)
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { log("Không tự mở được trình duyệt. Mở link này: " + url); }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        using var reg = timeout.Token.Register(() => { try { listener.Stop(); } catch { } });
        while (true)
        {
            HttpListenerContext c;
            try { c = await listener.GetContextAsync(); }
            catch when (timeout.IsCancellationRequested)
            {
                ct.ThrowIfCancellationRequested();
                throw new TimeoutException("Hết thời gian chờ đăng nhập Samsung (10 phút).");
            }
            Auth? auth = null;
            if (c.Request.HttpMethod == "POST" && c.Request.Url?.AbsolutePath == "/signin/callback")
            {
                var raw = await new StreamReader(c.Request.InputStream, Encoding.UTF8).ReadToEndAsync();
                var form = raw.Split('&').Select(kv => kv.Split('=', 2)).Where(kv => kv.Length == 2)
                    .ToDictionary(kv => Uri.UnescapeDataString(kv[0]), kv => Uri.UnescapeDataString(kv[1].Replace('+', ' ')));
                if (form.GetValueOrDefault("state") == State && form.TryGetValue("code", out var code))
                {
                    try
                    {
                        var j = JsonDocument.Parse(code).RootElement;
                        string S(string k) => j.TryGetProperty(k, out var v) ? v.GetString() ?? "" : "";
                        if (S("access_token").Length > 0) auth = new Auth(S("access_token"), S("userId"), S("inputEmailID"));
                    }
                    catch (JsonException) { }
                }
            }
            var msg = auth != null ? "✅ Đã đăng nhập Samsung. Đóng trang này và quay lại Subly." : "Phản hồi đăng nhập không hợp lệ.";
            var html = Encoding.UTF8.GetBytes($"<html><meta charset=\"utf-8\"><body style=\"font:20px sans-serif;padding:40px\">{msg}</body></html>");
            c.Response.StatusCode = auth != null ? 200 : 400;
            c.Response.ContentType = "text/html; charset=utf-8";
            await c.Response.OutputStream.WriteAsync(html, ct);
            c.Response.Close();
            if (auth == null) continue;
            if (auth.email.Length == 0) throw new InvalidOperationException("Tài khoản Samsung không trả về email; chứng chỉ phân phối cần email.");
            log("Đã đăng nhập Samsung: " + auth.email);
            return auth;
        }
    }

    // ---------- 3. CSR + gửi Samsung ký ----------
    static byte[] Csr(RSA key, string subject, IEnumerable<string>? sanUris)
    {
        var req = new CertificateRequest(subject, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        if (sanUris != null)
        {
            // SAN tự mã hoá DER (mỗi DUID là URI "URN:tizen:deviceid=…"): SubjectAlternativeNameBuilder đổi "URN:" thành chữ thường.
            var items = sanUris.SelectMany(u => Tlv(0x86, Encoding.ASCII.GetBytes(u))).ToArray();
            req.CertificateExtensions.Add(new X509Extension("2.5.29.17", Tlv(0x30, items), false));
        }
        var b64 = Convert.ToBase64String(req.CreateSigningRequest(), Base64FormattingOptions.InsertLineBreaks).Replace("\r", "");
        return Encoding.ASCII.GetBytes($"-----BEGIN CERTIFICATE REQUEST-----\n{b64}\n-----END CERTIFICATE REQUEST-----\n");
    }

    static byte[] Tlv(byte tag, byte[] content)
    {
        var n = content.Length;
        byte[] len = n < 0x80 ? new[] { (byte)n } : n < 0x100 ? new byte[] { 0x81, (byte)n } : new byte[] { 0x82, (byte)(n >> 8), (byte)n };
        return new[] { tag }.Concat(len).Concat(content).ToArray();
    }

    static async Task<byte[]> Post(string path, Auth auth, byte[] csr, string fileName, Dictionary<string, string>? extra, CancellationToken ct)
    {
        using var form = new MultipartFormDataContent
        {
            { new StringContent(auth.accessToken), "access_token" },
            { new StringContent(auth.userId), "user_id" },
        };
        if (extra != null) foreach (var kv in extra) form.Add(new StringContent(kv.Value), kv.Key);
        form.Add(new StringContent("VD"), "platform");
        form.Add(new ByteArrayContent(csr), "csr", fileName);
        using var res = await http.PostAsync($"{Api}/{path}", form, ct);
        var body = await res.Content.ReadAsByteArrayAsync(ct);
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException($"Samsung từ chối ({path}): HTTP {(int)res.StatusCode} {Encoding.UTF8.GetString(body)}");
        return body;
    }

    static X509Certificate2 ReadCert(byte[] data)
    {
        var m = Regex.Match(Encoding.ASCII.GetString(data), "-----BEGIN CERTIFICATE-----([\\s\\S]+?)-----END CERTIFICATE-----");
        return new X509Certificate2(m.Success ? Convert.FromBase64String(Regex.Replace(m.Groups[1].Value, "\\s", "")) : data);
    }

    static void WriteP12(string path, RSA key, byte[] signed, string caFile, string password)
    {
        using var leaf = ReadCert(signed).CopyWithPrivateKey(key);
        var col = new X509Certificate2Collection { leaf, ReadCert(File.ReadAllBytes(caFile)) };
        File.WriteAllBytes(path, col.Export(X509ContentType.Pkcs12, password)!);
    }
}
