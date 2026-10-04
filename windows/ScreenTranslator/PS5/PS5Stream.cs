using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

namespace ScreenTranslator;

/// Phiên Remote Play nhúng trong app (qua libchiaki): chỉ nhận hình để hiển thị và OCR. Không gửi điều khiển, không âm thanh.
public sealed class PS5Stream : INotifyPropertyChanged
{
    public static readonly PS5Stream shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => App.RunOnUI(() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n)));

    public enum StateKind { idle, searching, connecting, streaming, needsPin, failed }
    public record State(StateKind kind, string text = "", bool wrongPin = false)
    {
        public string label => kind switch
        {
            StateKind.idle => "Chưa kết nối",
            StateKind.searching => text,
            StateKind.connecting => "Đang kết nối…",
            StateKind.streaming => "Đang nhận hình",
            StateKind.needsPin => wrongPin ? "Mã PIN đăng nhập sai, nhập lại" : "PS5 yêu cầu mã PIN đăng nhập",
            _ => text,
        };
        public bool isBusy => kind is StateKind.searching or StateKind.connecting or StateKind.streaming or StateKind.needsPin;
    }

    public record Found(string addr, string name, string hostID, bool ps5, int state)
    {
        public string id => hostID.Length == 0 ? addr : hostID;
        public string stateLabel => state == 1 ? "đang bật" : state == 2 ? "chế độ nghỉ" : "không rõ";
    }

    State _state = new(StateKind.idle);
    public State state { get => _state; private set { _state = value; Raise(nameof(state)); } }
    PS5Host? _host = PS5Store.Load();
    public PS5Host? host { get => _host; private set { _host = value; Raise(nameof(host)); } }
    public (int w, int h) videoSize { get; private set; }
    int _fps; public int fps { get => _fps; private set { if (_fps != value) { _fps = value; Raise(nameof(fps)); } } }
    bool _registering; public bool registering { get => _registering; private set { _registering = value; Raise(nameof(registering)); } }
    string _registMessage = ""; public string registMessage { get => _registMessage; set { _registMessage = value; Raise(nameof(registMessage)); } }

    IntPtr session, regist, decoder;
    readonly SerialQueue work = new("ps5.stream");
    readonly object lk = new();
    Frame? latest;
    long frameIndex;
    readonly Dictionary<Guid, Action<Frame>> displaySinks = new();
    int framesThisSecond;
    Timer? fpsTimer;
    int generation;
    bool needKeyframe;
    // Giữ delegate sống trong suốt phiên (tránh GC thu hồi khi code native còn gọi).
    readonly ChiakiNative.VideoCb videoCb;
    readonly ChiakiNative.EventCb eventCb;
    readonly ChiakiNative.RegistCb registCb;
    readonly ChiakiNative.EventCb registLogCb;

    PS5Stream()
    {
        videoCb = (buf, size, _) => HandleVideo(buf, size);
        eventCb = (type, msg, _) => HandleEvent(type, msg == IntPtr.Zero ? "" : Marshal.PtrToStringUTF8(msg) ?? "");
        registCb = (ok, nick, mac, rk, key, _) =>
        {
            (string, byte[], byte[], byte[])? result = null;
            if (ok != 0 && nick != IntPtr.Zero && mac != IntPtr.Zero && rk != IntPtr.Zero && key != IntPtr.Zero)
            {
                var m = new byte[6]; Marshal.Copy(mac, m, 0, 6);
                var r = new byte[16]; Marshal.Copy(rk, r, 0, 16);
                var k = new byte[16]; Marshal.Copy(key, k, 0, 16);
                result = (Marshal.PtrToStringUTF8(nick) ?? "PS5", m, r, k);
            }
            RegistFinished(result);
        };
        registLogCb = (_, msg, _) => { if (msg != IntPtr.Zero) Log.Info($"chiaki regist: {Marshal.PtrToStringUTF8(msg)}"); };
    }

    // MARK: khung hình

    void Deliver(Frame f)
    {
        List<Action<Frame>> sinks;
        lock (lk)
        {
            latest = f;
            frameIndex++;
            framesThisSecond++;
            sinks = displaySinks.Values.ToList();
        }
        foreach (var s in sinks) s(f);
        if (videoSize != (f.Width, f.Height)) { videoSize = (f.Width, f.Height); Raise(nameof(videoSize)); }
    }

    /// Khung mới nhất và số thứ tự của nó (để biết đã có khung mới chưa).
    public (Frame frame, long index)? LatestFrame()
    {
        lock (lk) return latest == null ? null : (latest, frameIndex);
    }

    public Guid AddDisplaySink(Action<Frame> f)
    {
        var id = Guid.NewGuid();
        Frame? cur;
        lock (lk) { displaySinks[id] = f; cur = latest; }
        if (cur != null) f(cur);
        return id;
    }
    public void RemoveDisplaySink(Guid id) { lock (lk) displaySinks.Remove(id); }

    public bool isStreaming => state.kind == StateKind.streaming;

    // MARK: máy đã đăng ký

    public void SetHost(PS5Host? h)
    {
        PS5Store.Save(h);
        host = h;
    }

    public bool ImportFromChiaki()
    {
        var h = PS5Store.ImportFromChiaki();
        if (h == null) return false;
        h.host = host?.host ?? "";
        SetHost(h);
        Log.Info($"PS5: nhập máy '{h.nickname}' từ chiaki-ng");
        return true;
    }

    // MARK: tìm máy / đánh thức

    /// Địa chỉ broadcast của các card mạng IPv4 đang hoạt động.
    public static List<string> BroadcastAddresses()
    {
        var outp = new List<string>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.IPv4Mask == null) continue;
                    var ip = ua.Address.GetAddressBytes(); var mask = ua.IPv4Mask.GetAddressBytes();
                    var b = new byte[4];
                    for (int i = 0; i < 4; i++) b[i] = (byte)(ip[i] | ~mask[i]);
                    var s = new IPAddress(b).ToString();
                    if (!outp.Contains(s)) outp.Add(s);
                }
            }
        }
        catch { }
        return outp.Count == 0 ? new List<string> { "255.255.255.255" } : outp;
    }

    /// Tìm IP ứng với địa chỉ MAC trong bảng ARP của hệ điều hành (GetIpNetTable).
    public static string? ArpLookup(byte[] mac)
    {
        int size = 0;
        Win32.GetIpNetTable(IntPtr.Zero, ref size, false);
        if (size <= 0) return null;
        var buf = Marshal.AllocHGlobal(size);
        try
        {
            if (Win32.GetIpNetTable(buf, ref size, false) != 0) return null;
            int n = Marshal.ReadInt32(buf);
            for (int i = 0; i < n; i++)
            {
                var row = buf + 4 + i * 24;   // MIB_IPNETROW: index, physAddrLen, physAddr[8], addr, type
                int len = Marshal.ReadInt32(row, 4);
                if (len != 6) continue;
                var phys = new byte[6]; Marshal.Copy(row + 8, phys, 0, 6);
                if (!phys.SequenceEqual(mac)) continue;
                var addr = (uint)Marshal.ReadInt32(row, 16);
                return new IPAddress(addr).ToString();
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
        return null;
    }

    /// Chặn ~`ms` mili giây cho mỗi địa chỉ. Gọi ngoài UI thread.
    public static List<Found> Discover(IEnumerable<string> targets, int ms = 1200)
    {
        var items = new List<Found>();
        if (!ChiakiNative.Available) return items;
        ChiakiNative.DiscoveryCb cb = (addr, name, hid, ps5, st, _) =>
        {
            var f = new Found(Marshal.PtrToStringUTF8(addr) ?? "", Marshal.PtrToStringUTF8(name) ?? "", Marshal.PtrToStringUTF8(hid) ?? "", ps5 != 0, st);
            lock (items) if (!items.Any(x => x.id == f.id)) items.Add(f);
        };
        foreach (var t in targets) ChiakiNative.st_discover(t, ms, cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        return items;
    }

    void SetState(State s)
    {
        if (state != s) Log.Info($"PS5: {s.label}");
        state = s;
    }

    // MARK: kết nối

    public void Connect(int resolution, int fps)
    {
        var h0 = host;
        if (h0 == null || session != IntPtr.Zero || state.isBusy) return;
        if (!ChiakiNative.Available) { SetState(new State(StateKind.failed, ChiakiNative.LoadError ?? "Thiếu st_chiaki.dll")); return; }
        int gen = Interlocked.Increment(ref generation);
        SetState(new State(StateKind.searching, $"Đang tìm {h0.nickname}…"));
        work.Async(() =>
        {
            var h = h0.Clone();
            // 1. Tìm máy: thử IP đã lưu, không thấy thì hỏi cả mạng và khớp theo địa chỉ MAC.
            Found? found = h.host.Length == 0 ? null : Discover(new[] { h.host }, 900).FirstOrDefault();
            found ??= Discover(BroadcastAddresses()).FirstOrDefault(f => f.hostID.ToUpperInvariant() == h.hostID);
            if (gen != generation) return;
            // PS5 đang nghỉ có thể không trả lời tìm kiếm: lấy IP từ bảng ARP theo địa chỉ MAC để còn đánh thức.
            if (found == null && h.host.Length == 0 && ArpLookup(h.mac) is string ip)
            {
                h.host = ip;
                SetHost(h);
                Log.Info($"PS5: địa chỉ {ip} (từ bảng ARP)");
            }
            if (found != null && found.addr != h.host && found.addr.Length > 0)
            {
                h.host = found.addr;
                SetHost(h);
                Log.Info($"PS5: địa chỉ {found.addr}");
            }
            if (h.host.Length == 0)
            {
                SetState(new State(StateKind.failed, $"Không tìm thấy {h.nickname} trong mạng. Bật PS5 (hoặc để chế độ nghỉ có bật mạng) rồi thử lại."));
                return;
            }
            // 2. Đang nghỉ (hoặc không trả lời) → gửi gói đánh thức và đợi máy sẵn sàng.
            if (found?.state != 1)
            {
                SetState(new State(StateKind.searching, found == null ? "Không thấy PS5 trả lời, thử đánh thức…" : "Đang đánh thức PS5…"));
                bool ready = false;
                for (int i = 0; i < 30; i++)
                {
                    if (gen != generation) return;
                    if (i % 5 == 0) ChiakiNative.st_wakeup(h.host, h.registKey, h.ps5 ? 1 : 0);
                    if (Discover(new[] { h.host }, 900).FirstOrDefault() is { state: 1 }) { ready = true; break; }
                    Thread.Sleep(1000);
                }
                if (!ready)
                {
                    SetState(new State(StateKind.failed, "PS5 không trả lời. Máy đang tắt hẳn, hoặc chế độ nghỉ chưa bật “Stay Connected to the Internet” và “Enable Turning On PS5 from Network”."));
                    return;
                }
                Thread.Sleep(3000);   // vừa thức dậy: đợi dịch vụ Remote Play lên
            }
            if (gen != generation) return;
            // 3. Mở phiên.
            SetState(new State(StateKind.connecting));
            ResetDecoder();
            needKeyframe = false;
            var s = ChiakiNative.st_session_start(h.host, h.ps5 ? 1 : 0, h.registKey, h.rpKey, h.accountID, resolution, fps, 0, videoCb, eventCb, IntPtr.Zero);
            if (s == IntPtr.Zero) { SetState(new State(StateKind.failed, "Không mở được phiên Remote Play")); return; }
            session = s;
            StartFPSTimer();
        });
    }

    void ResetDecoder()
    {
        lock (lk)
        {
            if (decoder != IntPtr.Zero) ChiakiNative.st_decoder_free(decoder);
            decoder = ChiakiNative.st_decoder_new();
        }
    }

    void HandleVideo(IntPtr buf, UIntPtr size)
    {
        IntPtr d;
        lock (lk) d = decoder;
        if (d == IntPtr.Zero) return;
        int r = ChiakiNative.st_decoder_decode(d, buf, size);
        bool ok = r >= 0;
        if (r > 0)
        {
            var px = ChiakiNative.st_decoder_frame(d, out int w, out int h, out int stride);
            if (px != IntPtr.Zero && w > 0 && h > 0)
            {
                var f = new Frame(w, h);
                if (stride == f.Stride) Marshal.Copy(px, f.Data, 0, f.Data.Length);
                else for (int y = 0; y < h; y++) Marshal.Copy(px + y * stride, f.Data, y * f.Stride, w * 4);
                Deliver(f);
            }
        }
        if (!ok && !needKeyframe)
        {
            needKeyframe = true;
            if (session != IntPtr.Zero) ChiakiNative.st_session_request_idr(session);
        }
        else if (ok) needKeyframe = false;
    }

    void HandleEvent(int type, string msg)
    {
        switch (type)
        {
            case ChiakiNative.ST_EVENT_LOG:
                if (msg.Contains("rror") || msg.Contains("ailed")) Log.Warn($"chiaki: {msg}");
                break;
            case ChiakiNative.ST_EVENT_CONNECTED:
                SetState(new State(StateKind.streaming));
                break;
            case ChiakiNative.ST_EVENT_PIN_REQUEST:
                SetState(new State(StateKind.needsPin, wrongPin: msg == "incorrect"));
                break;
            case ChiakiNative.ST_EVENT_QUIT:
                var parts = msg.Split('|', 2);
                int code = int.TryParse(parts[0], out var c) ? c : -1;
                var text = parts.Length > 1 ? parts[1] : msg;
                Log.Info($"PS5: phiên kết thúc ({msg})");
                // Không được join luồng phiên ngay trong callback của nó → dọn ở hàng đợi khác.
                work.Async(() =>
                {
                    Teardown();
                    SetState(code switch
                    {
                        1 => new State(StateKind.idle),
                        4 => new State(StateKind.failed, "PS5 đang có một phiên Remote Play khác. Thoát chiaki-ng / PS Remote Play rồi thử lại."),
                        12 => new State(StateKind.failed, "PS5 đã tắt hoặc vào chế độ nghỉ."),
                        _ => new State(StateKind.failed, $"Mất kết nối: {text}"),
                    });
                });
                break;
        }
    }

    public void SendPin(string pin)
    {
        if (session == IntPtr.Zero) return;
        ChiakiNative.st_session_set_pin(session, pin);
        SetState(new State(StateKind.connecting));
    }

    public void Disconnect()
    {
        Interlocked.Increment(ref generation);
        work.Async(() =>
        {
            Teardown();
            SetState(new State(StateKind.idle));
        });
    }

    /// Gọi trên `work`.
    void Teardown()
    {
        if (session != IntPtr.Zero)
        {
            var s = session;
            session = IntPtr.Zero;
            ChiakiNative.st_session_stop(s);
        }
        lock (lk)
        {
            if (decoder != IntPtr.Zero) { ChiakiNative.st_decoder_free(decoder); decoder = IntPtr.Zero; }
            latest = null;
        }
        fpsTimer?.Dispose(); fpsTimer = null;
        fps = 0;
    }

    void StartFPSTimer()
    {
        fpsTimer?.Dispose();
        fpsTimer = new Timer(_ =>
        {
            int n;
            lock (lk) { n = framesThisSecond; framesThisSecond = 0; }
            fps = n;
        }, null, 1000, 1000);
    }

    // MARK: đăng ký máy

    (string addr, byte[] account, bool ps5)? pendingRegist;

    /// `pin`: 8 chữ số hiện ở Settings → System → Remote Play → Link Device trên PS5.
    public void Register(string hostAddr, byte[] accountID, uint pin, bool ps5 = true)
    {
        if (regist != IntPtr.Zero) return;
        if (!ChiakiNative.Available) { registMessage = ChiakiNative.LoadError ?? "Thiếu st_chiaki.dll"; return; }
        registering = true;
        registMessage = $"Đang đăng ký với {hostAddr}…";
        pendingRegist = (hostAddr, accountID, ps5);
        regist = ChiakiNative.st_regist_start(hostAddr, ps5 ? 1 : 0, accountID, pin, registCb, registLogCb, IntPtr.Zero);
        if (regist == IntPtr.Zero)
        {
            registering = false;
            registMessage = "Không bắt đầu được việc đăng ký";
        }
    }

    void RegistFinished((string nick, byte[] mac, byte[] rk, byte[] key)? r)
    {
        var pending = pendingRegist;
        // Callback chạy trên luồng của regist → dọn ở hàng đợi khác.
        work.Async(() =>
        {
            if (regist != IntPtr.Zero) { var rg = regist; regist = IntPtr.Zero; ChiakiNative.st_regist_finish(rg); }
            registering = false;
            if (r is { } v && pending is { } p)
            {
                var h = new PS5Host { host = p.addr, nickname = v.nick, mac = v.mac, registKey = v.rk, rpKey = v.key, accountID = p.account, ps5 = p.ps5 };
                SetHost(h);
                registMessage = $"Đã đăng ký {v.nick}";
                Log.Info($"PS5: đăng ký thành công '{v.nick}'");
            }
            else registMessage = "Đăng ký thất bại. Kiểm tra mã PIN (8 số, còn hạn), PSN Account ID và địa chỉ IP.";
        });
    }
}
