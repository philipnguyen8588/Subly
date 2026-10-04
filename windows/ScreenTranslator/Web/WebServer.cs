using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;

namespace ScreenTranslator;

/// Máy chủ web nhỏ trong mạng nội bộ: điện thoại/máy tính bảng mở bằng trình duyệt để xem phụ đề thời gian thực, xem lại nhật ký
/// và bấm "Dịch màn hình". HTTP thuần trên TcpListener (không cần quyền admin); sự kiện đẩy xuống bằng Server-Sent Events (GET /events).
public sealed class WebServer : INotifyPropertyChanged
{
    static readonly Lazy<WebServer> lazy = new(() => new WebServer());
    public static WebServer shared => lazy.Value;
    public event PropertyChangedEventHandler? PropertyChanged;

    public enum StatusKind { off, starting, running, failed }
    public record Status(StatusKind kind, int port = 0, string message = "");

    Status _status = new(StatusKind.off);
    public Status status { get => _status; private set { _status = value; App.RunOnUI(() => PropertyChanged?.Invoke(this, new(nameof(status)))); } }
    int _clients;
    public int clientCount { get => _clients; private set { _clients = value; App.RunOnUI(() => PropertyChanged?.Invoke(this, new(nameof(clientCount)))); } }

    TcpListener? listener;
    CancellationTokenSource? cts;
    int port;
    bool observing;
    readonly object lk = new();
    readonly List<Stream> streams = new();      // các máy đang mở /events
    Timer? heartbeat;
    byte[]? lastSubtitle, lastState, icon;
    string? sentState, sentProfileID;

    static readonly JsonSerializerOptions Json = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
    static byte[] J(object v) => JsonSerializer.SerializeToUtf8Bytes(v, Json);
    static double Unix(DateTime t) => new DateTimeOffset(t).ToUnixTimeMilliseconds() / 1000.0;

    static object EntryDTO(TranslationEntry e) => new
    {
        id = e.id, at = Unix(e.timestamp), source = e.source, translated = e.translated,
        skipped = e.backend == BackendKind.skipped.ToString(),   // câu quá đơn giản: không dịch, chỉ có câu gốc
    };
    /// Một lần dịch màn hình. `image`: còn ảnh chụp (GET /api/shot/<id>.jpg); `items`: vị trí khối chữ theo tỉ lệ 0...1 của ảnh.
    static object AnalysisDTO(ScreenAnalysis a) => new
    {
        id = a.id, at = Unix(a.timestamp), summary = a.summary, lines = a.lines, ms = a.latencyMs,
        image = a.hasImage, width = a.imageWidth, height = a.imageHeight, items = a.hasImage ? a.items : new List<ShotItem>(),
    };

    /// Trang web chỉ thấy nhật ký của game đang chọn trên app.
    static string ActiveProfile => HistoryStore.ProfileKey(AppSettings.shared.activeProfile.id);

    // MARK: bật / tắt

    /// Bật, tắt hoặc đổi cổng theo cài đặt hiện tại. Gọi lúc mở app và mỗi khi cài đặt web đổi.
    public void Apply()
    {
        var s = AppSettings.shared;
        int wanted = s.webServerOn ? s.webPort : 0;
        if (wanted > 0 && wanted == port && listener != null) return;
        Stop();
        if (wanted <= 0) return;
        if (wanted > 65535) { status = new(StatusKind.failed, 0, $"Cổng {wanted} không hợp lệ"); return; }
        try
        {
            // Chỉ IPv4: cùng với kiểm tra dải địa chỉ nội bộ bên dưới, máy ngoài mạng nhà không vào được.
            var l = new TcpListener(IPAddress.Any, wanted);
            l.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            l.Start();
            listener = l;
            port = wanted;
            cts = new CancellationTokenSource();
            status = new(StatusKind.running, wanted);
            Log.Info($"Web: đang phục vụ tại {string.Join(", ", Urls(wanted))}");
            Observe();
            _ = AcceptLoop(l, cts.Token);
        }
        catch (Exception e)
        {
            Log.Error($"Web: không mở được cổng {wanted}: {e.Message}");
            status = new(StatusKind.failed, 0, $"Không mở được cổng {wanted} (đang bị app khác dùng?)");
            listener = null; port = 0;
        }
    }

    void Stop()
    {
        if (listener == null) { status = new(StatusKind.off); return; }
        cts?.Cancel();
        try { listener.Stop(); } catch { }
        listener = null; port = 0;
        status = new(StatusKind.off);
        lock (lk)
        {
            foreach (var s in streams) { try { s.Dispose(); } catch { } }
            streams.Clear();
        }
        heartbeat?.Dispose(); heartbeat = null;
        clientCount = 0;
        Log.Info("Web: đã tắt");
    }

    /// Theo dõi trạng thái app để đẩy xuống các máy đang xem (đăng ký một lần, trên UI thread).
    void Observe()
    {
        if (observing) return;
        observing = true;
        var pipeline = Pipeline.shared;
        Timer? debounce = null;
        void Later() { debounce?.Dispose(); debounce = new Timer(_ => App.RunOnUI(PushState), null, 300, Timeout.Infinite); }
        pipeline.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Pipeline.isRunning)) App.RunOnUI(PushState); };
        pipeline.analyzer.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ScreenAnalyzer.isRunning)) App.RunOnUI(PushState); };
        AppSettings.shared.Changed += k => { if (k != "rpdUsed") Later(); };
        PushState();
        HistoryStore.shared.EntryAdded += e => { if (e.profile == ActiveProfile) Broadcast("entry", J(EntryDTO(e))); };
        HistoryStore.shared.EntriesCleared += () => Broadcast("cleared", Encoding.UTF8.GetBytes("{}"));
        HistoryStore.shared.AnalysisAdded += _ => Broadcast("analysis", Encoding.UTF8.GetBytes("{}"));
    }

    void PushState()
    {
        var p = Pipeline.shared; var s = AppSettings.shared; var prof = s.activeProfile;
        var state = new
        {
            running = p.isRunning, analyzing = p.analyzer.isRunning, profile = prof.name,
            profileID = HistoryStore.ProfileKey(prof.id), names = prof.showsSpeakerNames, speakers = prof.speakers,
        };
        var data = J(state);
        var str = Encoding.UTF8.GetString(data);
        if (str == sentState) return;
        bool switched = sentProfileID != null && sentProfileID != state.profileID;
        sentState = str; sentProfileID = state.profileID;
        lock (lk)
        {
            if (switched) lastSubtitle = null;      // đổi game: câu phụ đề của game cũ không gửi cho máy mới vào nữa
            lastState = data;
        }
        Broadcast("state", data);
    }

    // MARK: sự kiện

    /// Pipeline gọi mỗi khi có bản dịch mới. `first` = câu đầu của một lượt phụ đề (các câu sau nối thêm vào cùng lượt).
    public void Subtitle(string source, string translated, bool first)
    {
        var data = J(new { source, translated, first, at = Unix(DateTime.Now) });
        lock (lk) lastSubtitle = data;
        Broadcast("subtitle", data);
    }

    /// Giọng đọc phát trên TV / điện thoại: giữ tạm các đoạn âm thanh gần nhất (GET /api/audio/<id>) và báo cho máy đang xem.
    /// `flush` = bỏ câu đang đọc dở để đọc câu này ngay.
    readonly Dictionary<int, (byte[] data, string mime)> clips = new();
    int clipSeq;
    public void Audio(byte[] data, string mime, bool flush, string text)
    {
        int id;
        lock (lk)
        {
            id = ++clipSeq;
            clips[id] = (data, mime);
            foreach (var k in clips.Keys.Where(k => k <= id - 30).ToList()) clips.Remove(k);
        }
        Broadcast("audio", J(new { id, mime, flush, text }));
    }

    void Broadcast(string ev, byte[] data)
    {
        List<Stream> targets;
        lock (lk) targets = streams.ToList();
        foreach (var t in targets) Send(ev, data, t);
    }

    void Send(string ev, byte[] data, Stream s)
    {
        var msg = new MemoryStream();
        msg.Write(Encoding.UTF8.GetBytes($"event: {ev}\ndata: "));
        msg.Write(data);
        msg.Write(Encoding.UTF8.GetBytes("\n\n"));
        Write(s, msg.ToArray());
    }

    void Write(Stream s, byte[] bytes)
    {
        _ = Task.Run(async () =>
        {
            try { await s.WriteAsync(bytes); await s.FlushAsync(); }
            catch { Drop(s); }
        });
    }

    void Drop(Stream s)
    {
        bool removed;
        lock (lk) removed = streams.Remove(s);
        try { s.Dispose(); } catch { }
        if (removed) ReportClients();
    }

    // MARK: kết nối

    async Task AcceptLoop(TcpListener l, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(ct); }
            catch { return; }
            var ep = c.Client.RemoteEndPoint as IPEndPoint;
            if (ep == null || !IsLocal(ep.Address))
            {
                Log.Warn($"Web: từ chối kết nối từ ngoài mạng nội bộ: {ep}");
                c.Dispose();
                continue;
            }
            _ = Task.Run(() => Handle(c));
        }
    }

    async Task Handle(TcpClient c)
    {
        var s = c.GetStream();
        try
        {
            var buf = new byte[16384];
            var acc = new MemoryStream();
            string? head = null;
            using (var readCts = new CancellationTokenSource(TimeSpan.FromSeconds(15)))
            {
                while (head == null)
                {
                    int n = await s.ReadAsync(buf, readCts.Token);
                    if (n <= 0) { c.Dispose(); return; }
                    acc.Write(buf, 0, n);
                    var str = Encoding.UTF8.GetString(acc.GetBuffer(), 0, (int)acc.Length);
                    int end = str.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                    if (end >= 0) head = str[..end];
                    else if (acc.Length > 32768) { c.Dispose(); return; }
                }
            }
            await Route(c, s, head);
        }
        catch { try { c.Dispose(); } catch { } }
    }

    async Task Route(TcpClient c, Stream s, string head)
    {
        var lines = head.Split("\r\n");
        var parts = lines[0].Split(' ');
        if (parts.Length < 2) { c.Dispose(); return; }
        var method = parts[0];
        // App TV (Tizen) chạy từ gói cài trên TV (Origin "null" / file:// / app://) cần CORS để đọc phụ đề.
        // Chỉ mở cho GET và đúng các origin đó; trang web lạ vẫn không đọc được, POST vẫn cần header riêng.
        var origin = lines.Skip(1).Select(l => l.Split(':', 2)).Where(kv => kv.Length == 2 && kv[0].Trim().Equals("origin", StringComparison.OrdinalIgnoreCase))
                          .Select(kv => kv[1].Trim()).FirstOrDefault();
        corsOrigin.Value = method == "GET" && origin != null && (origin == "null" || origin.StartsWith("file://") || origin.StartsWith("app://")) ? origin : null;
        if (origin != null && method == "GET" && path0(parts[1]) == "/events") Log.Info($"Web: SSE từ origin '{origin}' ({c.Client.RemoteEndPoint}){(corsOrigin.Value != null ? " → cho phép CORS" : "")}");
        var target = parts[1].Split('?', 2);
        var path = target[0];
        var query = target.Length > 1 ? target[1] : "";

        if (method == "GET" && (path == "/" || path == "/index.html"))
            await Respond(c, s, "text/html; charset=utf-8", WebPage.Html);
        else if (method == "GET" && path == "/events")
            OpenStream(c, s);
        else if (method == "GET" && path == "/icon.png")
        {
            icon ??= IconPNG();
            if (icon != null) await Respond(c, s, "image/png", icon, cache: true);
            else await Respond(c, s, "text/plain", Array.Empty<byte>(), "404 Not Found");
        }
        else if (method == "GET" && path == "/api/log")
        {
            int limit = 300;
            foreach (var q in query.Split('&')) if (q.StartsWith("limit=") && int.TryParse(q[6..], out var v)) limit = v;
            byte[] body = Array.Empty<byte>();
            await App.InvokeOnUI(() =>
            {
                var profile = ActiveProfile;
                body = J(HistoryStore.shared.entries.Where(e => e.profile == profile).Take(Math.Max(1, Math.Min(limit, 2000))).Select(EntryDTO).ToList());
            });
            await Respond(c, s, "application/json", body);
        }
        else if (method == "GET" && path == "/api/analyses")
        {
            byte[] body = Array.Empty<byte>();
            await App.InvokeOnUI(() =>
            {
                var profile = ActiveProfile;
                body = J(HistoryStore.shared.analyses.Where(a => a.profile == profile).Take(100).Select(AnalysisDTO).ToList());
            });
            await Respond(c, s, "application/json", body);
        }
        else if (method == "GET" && path.StartsWith("/api/shot/") && path.EndsWith(".jpg"))
        {
            // Ảnh chụp đã lưu; ?thumb=1 trả ảnh thu nhỏ cho danh sách.
            if (!long.TryParse(path["/api/shot/".Length..^4], out var id)) { c.Dispose(); return; }
            byte[]? data = null;
            try { data = query.Contains("thumb=1") ? ShotImages.ThumbnailJpeg(id, 480) : File.ReadAllBytes(HistoryStore.ShotPath(id)); } catch { }
            if (data == null) await Respond(c, s, "text/plain", Array.Empty<byte>(), "404 Not Found");
            else await Respond(c, s, "image/jpeg", data, cache: true);
        }
        else if (method == "GET" && path.StartsWith("/api/audio/"))
        {
            // Giọng đọc của một câu (WAV hoặc MP3), TV / điện thoại tải về để phát.
            (byte[] data, string mime) clip = default;
            bool found = false;
            if (int.TryParse(path["/api/audio/".Length..].Split('.')[0], out var id)) lock (lk) found = clips.TryGetValue(id, out clip);
            if (found) await Respond(c, s, clip.mime, clip.data);
            else await Respond(c, s, "text/plain", Array.Empty<byte>(), "404 Not Found");
        }
        else if (method == "POST" && !lines.Any(l => l.ToLowerInvariant().StartsWith("x-screentranslator:")))
        {
            // Header riêng buộc trình duyệt phải hỏi trước (preflight) nếu trang web khác gọi tới → trang lạ không bấm hộ được.
            await Respond(c, s, "text/plain", Array.Empty<byte>(), "403 Forbidden");
        }
        else if (method == "POST" && path == "/api/toggle")
        {
            string? error = null;
            var done = new TaskCompletionSource();
            App.RunOnUI(async () =>
            {
                var p = Pipeline.shared;
                try
                {
                    if (p.isRunning) p.Stop();
                    else
                    {
                        var regions = AppSettings.shared.subtitleRegions.Where(r => r.enabled).ToList();
                        if (regions.Count == 0) error = "Chưa có vùng phụ đề. Mở tab Màn hình trên máy tính để vẽ khung phụ đề.";
                        else
                        {
                            await p.Start();
                            if (!p.isRunning) error = "Không bắt đầu được. Xem thông báo trên máy tính.";
                        }
                    }
                    Log.Info($"Web: bật/tắt dịch phụ đề từ xa → {error ?? (p.isRunning ? "đang chạy" : "đã dừng")}");
                }
                finally { done.TrySetResult(); }
            });
            await done.Task;
            await Respond(c, s, "application/json", J(new { ok = error == null, error }));
        }
        else if (method == "POST" && path == "/api/analyze")
        {
            var p = Pipeline.shared;
            var regions = AppSettings.shared.manualRegions.Where(r => r.enabled).ToList();
            string? error = null;
            ScreenAnalysis? shot = null;
            if (regions.Count == 0) error = "Chưa chọn màn hình game. Mở tab Màn hình trên máy tính để chọn vùng game hoặc kết nối PS5.";
            else if (p.analyzer.isRunning) error = "Đang dịch, đợi một chút.";
            else
            {
                shot = await p.analyzer.Analyze(regions, present: false);
                if (shot == null) error = p.analyzer.lastError ?? "Không dịch được.";
            }
            Log.Info($"Web: dịch màn hình từ xa → {error ?? "xong"}");
            await Respond(c, s, "application/json", J(new { ok = error == null, error, id = shot?.id }));
        }
        else
            await Respond(c, s, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Không có trang này"), "404 Not Found");
    }

    static readonly AsyncLocal<string?> corsOrigin = new();
    static string CorsHeader => corsOrigin.Value is string o ? $"Access-Control-Allow-Origin: {o}\r\n" : "";
    static string path0(string target) => target.Split('?', 2)[0];

    static async Task Respond(TcpClient c, Stream s, string type, byte[] body, string status = "200 OK", bool cache = false)
    {
        try
        {
            var head = $"HTTP/1.1 {status}\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\nCache-Control: {(cache ? "max-age=86400" : "no-store")}\r\n{CorsHeader}Connection: close\r\n\r\n";
            await s.WriteAsync(Encoding.UTF8.GetBytes(head));
            await s.WriteAsync(body);
            await s.FlushAsync();
        }
        catch { }
        finally { c.Dispose(); }
    }

    void OpenStream(TcpClient c, Stream s)
    {
        var head = $"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n{CorsHeader}Connection: keep-alive\r\n\r\nretry: 2000\n\n";
        Write(s, Encoding.UTF8.GetBytes(head));
        byte[]? st, sub;
        lock (lk) { streams.Add(s); st = lastState; sub = lastSubtitle; }
        // Máy vừa mở trang thấy ngay trạng thái và câu phụ đề gần nhất.
        if (st != null) Send("state", st, s);
        if (sub != null) Send("subtitle", sub, s);
        ReportClients();
        // Đọc tới khi máy kia đóng kết nối.
        _ = Task.Run(async () =>
        {
            var b = new byte[256];
            try { while (await s.ReadAsync(b) > 0) { } } catch { }
            Drop(s);
            c.Dispose();
        });
        if (heartbeat == null)
        {
            // Dòng chú thích định kỳ: giữ kết nối sống và phát hiện máy đã rời đi.
            heartbeat = new Timer(_ =>
            {
                List<Stream> targets;
                lock (lk) targets = streams.ToList();
                if (targets.Count == 0) return;
                var ping = Encoding.UTF8.GetBytes(": ping\n\n");
                foreach (var t in targets) Write(t, ping);
            }, null, 20000, 20000);
        }
    }

    void ReportClients() { lock (lk) clientCount = streams.Count; }

    // MARK: địa chỉ

    /// Chỉ nhận máy trong mạng nội bộ (dải địa chỉ riêng, link-local, loopback, và 100.64/10 của VPN kiểu Tailscale).
    static bool IsLocal(IPAddress a)
    {
        if (a.IsIPv4MappedToIPv6) a = a.MapToIPv4();
        if (a.AddressFamily == AddressFamily.InterNetworkV6) return IPAddress.IsLoopback(a);
        var b = a.GetAddressBytes();
        if (b.Length != 4) return false;
        return b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
               || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
    }

    /// Địa chỉ IPv4 của máy trong mạng nội bộ (ưu tiên Wi-Fi/Ethernet).
    public static List<string> LanAddresses()
    {
        var outp = new List<(int rank, string ip)>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                int rank = ni.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet ? 0 : 1;
                if (ni.Description.Contains("Virtual", StringComparison.OrdinalIgnoreCase) || ni.Description.Contains("Hyper-V")) rank = 2;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork && IsLocal(ua.Address) && !IPAddress.IsLoopback(ua.Address))
                        outp.Add((rank, ua.Address.ToString()));
            }
        }
        catch { }
        return outp.OrderBy(x => x.rank).Select(x => x.ip).Distinct().ToList();
    }

    /// Các địa chỉ mở được từ điện thoại: IP trước (chắc chắn nhất), rồi tên máy.
    public static List<string> Urls(int port)
    {
        var hosts = LanAddresses();
        hosts.Add(Environment.MachineName.ToLowerInvariant());
        return hosts.Select(h => $"http://{h}:{port}").ToList();
    }

    static byte[]? IconPNG()
    {
        try
        {
            var dec = BitmapDecoder.Create(new Uri("pack://application:,,,/Resources/AppIcon.png"), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            var tb = new TransformedBitmap(dec.Frames[0], new System.Windows.Media.ScaleTransform(180.0 / dec.Frames[0].PixelWidth, 180.0 / dec.Frames[0].PixelHeight));
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(tb));
            using var ms = new MemoryStream();
            enc.Save(ms);
            return ms.ToArray();
        }
        catch (Exception e) { Log.Warn($"Web icon: {e.Message}"); return null; }
    }
}

/// Trang web một file (HTML + CSS + JS), nhúng trong exe (Web/WebPage.html, giống hệt bản macOS).
public static class WebPage
{
    static byte[]? html;
    public static byte[] Html
    {
        get
        {
            if (html != null) return html;
            using var s = typeof(WebPage).Assembly.GetManifestResourceStream("WebPage.html");
            if (s == null) return html = Encoding.UTF8.GetBytes("<h1>WebPage.html missing</h1>");
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            return html = ms.ToArray();
        }
    }
}
