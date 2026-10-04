using System;
using System.IO;
using System.Linq;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Microsoft Edge "Read Aloud" neural TTS (endpoint không chính thức, miễn phí). Trả về MP3.
public sealed class EdgeTTS
{
    public record Voice(string id, string name, string lang);

    public static readonly Voice[] voices =
    {
        new("vi-VN-NamMinhNeural", "Nam Minh (nam)", "vi"),
        new("vi-VN-HoaiMyNeural", "Hoài My (nữ)", "vi"),
        new("en-US-GuyNeural", "Guy (male)", "en"),
        new("en-US-AndrewNeural", "Andrew (male)", "en"),
        new("en-US-JennyNeural", "Jenny (female)", "en"),
        new("en-US-AriaNeural", "Aria (female)", "en"),
        new("ja-JP-KeitaNeural", "Keita (男)", "ja"),
        new("ja-JP-NanamiNeural", "Nanami (女)", "ja"),
        new("ko-KR-InJoonNeural", "InJoon (남)", "ko"),
        new("ko-KR-SunHiNeural", "SunHi (여)", "ko"),
        new("zh-CN-YunxiNeural", "云希 (男)", "zh-Hans"),
        new("zh-CN-XiaoxiaoNeural", "晓晓 (女)", "zh-Hans"),
        new("zh-TW-YunJheNeural", "雲哲 (男)", "zh-Hant"),
        new("zh-TW-HsiaoChenNeural", "曉臻 (女)", "zh-Hant"),
        new("fr-FR-HenriNeural", "Henri (homme)", "fr"),
        new("fr-FR-DeniseNeural", "Denise (femme)", "fr"),
        new("de-DE-ConradNeural", "Conrad (Mann)", "de"),
        new("de-DE-KatjaNeural", "Katja (Frau)", "de"),
        new("es-ES-AlvaroNeural", "Álvaro (hombre)", "es"),
        new("es-ES-ElviraNeural", "Elvira (mujer)", "es"),
        new("th-TH-NiwatNeural", "Niwat (ชาย)", "th"),
        new("th-TH-PremwadeeNeural", "Premwadee (หญิง)", "th"),
        new("id-ID-ArdiNeural", "Ardi (pria)", "id"),
        new("id-ID-GadisNeural", "Gadis (wanita)", "id"),
    };

    public static Voice[] VoicesFor(string lang) => voices.Where(v => v.lang == lang).ToArray();
    public static string DefaultVoice(string lang) => VoicesFor(lang).FirstOrDefault()?.id ?? "en-US-GuyNeural";

    const string token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
    const string chromeVersion = "143.0.3650.75";

    /// Mốc thời gian (ms) của lần tổng hợp gần nhất, để ghi log: đã dùng kết nối ấm?, gửi xong, gói âm thanh đầu.
    public (bool warm, int sentMs, int firstMs) lastMarks { get; private set; } = (false, -1, -1);

    /// Sec-MS-GEC: SHA256(ticks làm tròn 5 phút + token), theo cách Edge làm.
    static string GecToken()
    {
        ulong ticks = (ulong)((DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 + 11_644_473_600) * 10_000_000);
        ticks -= ticks % 3_000_000_000;
        var hash = SHA256.HashData(Encoding.ASCII.GetBytes($"{ticks}{token}"));
        return Convert.ToHexString(hash);
    }

    static string Timestamp() =>
        DateTime.UtcNow.ToString("ddd MMM dd yyyy HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture) + " GMT+0000 (Coordinated Universal Time)";

    static string Escape(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;").Replace("'", "&apos;");

    static string NewId() => Guid.NewGuid().ToString("N").ToUpperInvariant();

    // MARK: kết nối giữ sẵn ("ấm")

    sealed class Conn
    {
        public readonly ClientWebSocket ws = new();
        public Task connect = Task.CompletedTask;
        public readonly DateTime at = DateTime.UtcNow;
        public bool Usable => !connect.IsFaulted && !connect.IsCanceled && (ws.State == WebSocketState.Open || ws.State == WebSocketState.Connecting || ws.State == WebSocketState.None);
        public void Kill() { try { ws.Abort(); ws.Dispose(); } catch { } }
    }

    Conn? warm;
    readonly object warmLock = new();
    const double warmMaxAge = 50;

    static Conn MakeSocket()
    {
        var c = new Conn();
        var url = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1" +
                  $"?TrustedClientToken={token}&Sec-MS-GEC={GecToken()}&Sec-MS-GEC-Version=1-{chromeVersion}&ConnectionId={NewId()}";
        var o = c.ws.Options;
        var major = chromeVersion.Split('.')[0];
        o.SetRequestHeader("Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold");
        o.SetRequestHeader("User-Agent", $"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{major}.0.0.0 Safari/537.36 Edg/{major}.0.0.0");
        o.SetRequestHeader("Pragma", "no-cache");
        o.SetRequestHeader("Cache-Control", "no-cache");
        o.SetRequestHeader("Accept-Language", "en-US,en;q=0.9");
        o.SetRequestHeader("Cookie", $"MUID={NewId()}");
        o.KeepAliveInterval = TimeSpan.FromSeconds(5);
        c.connect = c.ws.ConnectAsync(new Uri(url), CancellationToken.None);
        c.connect.ContinueWith(t => { _ = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
        return c;
    }

    /// Gọi định kỳ khi đang chạy: kết nối ấm chết hoặc quá cũ thì mở cái mới. Luôn có sẵn một kết nối đã bắt tay xong.
    public void KeepWarm()
    {
        lock (warmLock)
        {
            if (warm != null && warm.Usable && (DateTime.UtcNow - warm.at).TotalSeconds < 45) return;
            warm?.Kill();
            warm = MakeSocket();
        }
    }

    void ReplaceWarm()
    {
        lock (warmLock) { warm?.Kill(); warm = MakeSocket(); }
    }

    /// Mở sẵn một kết nối để câu kế tiếp không mất thời gian bắt tay TLS/WebSocket.
    public void Prewarm()
    {
        lock (warmLock)
        {
            if (warm != null && (DateTime.UtcNow - warm.at).TotalSeconds < warmMaxAge && warm.Usable) return;
            warm?.Kill();
            warm = MakeSocket();
        }
    }

    (Conn, bool) TakeSocket()
    {
        lock (warmLock)
        {
            if (warm != null && (DateTime.UtcNow - warm.at).TotalSeconds < warmMaxAge && warm.Usable)
            {
                var w = warm; warm = null;
                return (w, true);
            }
            warm?.Kill();
            warm = null;
            return (MakeSocket(), false);
        }
    }

    /// `ratePercent`: -50…+100 (0 = bình thường). `onAudio` được gọi với từng mẩu MP3 ngay khi tới (streaming).
    public async Task<byte[]> Synthesize(string text, string voice, int ratePercent, Action<byte[]>? onAudio, CancellationToken ct)
    {
        var (c, wasWarm) = TakeSocket();
        var t0 = DateTime.UtcNow;
        lastMarks = (wasWarm, -1, -1);
        try { return await Run(c, text, voice, ratePercent, onAudio, t0, ct); }
        catch (Exception) when (wasWarm && !ct.IsCancellationRequested)
        {
            c.Kill();
            // Kết nối giữ sẵn có thể đã bị server đóng → thử lại một lần với kết nối mới.
            lastMarks = (false, -1, -1);
            var fresh = MakeSocket();
            try { return await Run(fresh, text, voice, ratePercent, onAudio, DateTime.UtcNow, ct); }
            finally { fresh.Kill(); }
        }
        finally { c.Kill(); }
    }

    async Task<byte[]> Run(Conn c, string text, string voice, int ratePercent, Action<byte[]>? onAudio, DateTime t0, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        var tk = timeout.Token;
        await c.connect.WaitAsync(tk);
        var ws = c.ws;
        var cfg = $"X-Timestamp:{Timestamp()}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" +
                  "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}";
        await ws.SendAsync(Encoding.UTF8.GetBytes(cfg), WebSocketMessageType.Text, true, tk);

        var rate = ratePercent >= 0 ? $"+{ratePercent}%" : $"{ratePercent}%";
        var ssml = $"<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='https://www.w3.org/2001/mstts' xml:lang='en-US'><voice name='{voice}'><prosody pitch='+0Hz' rate='{rate}' volume='+0%'>{Escape(text)}</prosody></voice></speak>";
        var msg = $"X-RequestId:{NewId()}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:{Timestamp()}Z\r\nPath:ssml\r\n\r\n{ssml}";
        await ws.SendAsync(Encoding.UTF8.GetBytes(msg), WebSocketMessageType.Text, true, tk);
        lastMarks = (lastMarks.warm, (int)(DateTime.UtcNow - t0).TotalMilliseconds, -1);
        ReplaceWarm();  // chuẩn bị luôn kết nối cho câu sau

        var audio = new MemoryStream();
        var buf = new byte[1 << 16];
        var msgBuf = new MemoryStream();
        while (true)
        {
            msgBuf.SetLength(0);
            WebSocketReceiveResult r;
            do
            {
                r = await ws.ReceiveAsync(buf, tk);
                if (r.MessageType == WebSocketMessageType.Close) throw new IOException("Edge TTS: server đóng kết nối");
                msgBuf.Write(buf, 0, r.Count);
            } while (!r.EndOfMessage);
            var d = msgBuf.ToArray();
            if (r.MessageType == WebSocketMessageType.Text)
            {
                var s = Encoding.UTF8.GetString(d);
                if (s.Contains("Path:turn.end"))
                {
                    try { await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None); } catch { }
                    if (audio.Length == 0) throw new IOException("Edge TTS không trả âm thanh");
                    return audio.ToArray();
                }
            }
            else
            {
                // 2 byte big-endian độ dài header, rồi header text, rồi audio
                if (d.Length <= 2) continue;
                int hlen = d[0] << 8 | d[1];
                if (d.Length <= 2 + hlen) continue;
                var header = Encoding.UTF8.GetString(d, 2, hlen);
                if (header.Contains("Path:audio"))
                {
                    var chunk = d[(2 + hlen)..];
                    if (audio.Length == 0) lastMarks = (lastMarks.warm, lastMarks.sentMs, (int)(DateTime.UtcNow - t0).TotalMilliseconds);
                    audio.Write(chunk);
                    onAudio?.Invoke(chunk);
                }
            }
        }
    }
}
