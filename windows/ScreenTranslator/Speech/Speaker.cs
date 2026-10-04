using System;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Đọc bản dịch: giọng Windows (offline, tức thì), giọng AI offline (sherpa-onnx, tiếng Việt), hoặc Microsoft Edge neural.
public sealed class Speaker
{
    readonly EdgeTTS edge = new();
    readonly Mp3StreamPlayer streamPlayer = new();
    Task? edgeTask;
    CancellationTokenSource? edgeCts;
    int edgeGeneration;          // tăng mỗi câu; mẩu âm thanh của câu cũ bị bỏ
    int edgeFailures;
    readonly LocalTTS local = new();
    readonly WindowsTTS win = new();
    readonly SerialQueue winQueue = new("win.tts", ThreadPriority.AboveNormal);
    readonly PcmStreamPlayer pcmPlayer = new();
    int localGeneration;

    public string localVoiceID = VoiceCatalog.defaultVoiceID;
    /// 1 = tốc độ gốc của model
    public double localSpeed = 1.15;
    /// Tốc độ nói riêng cho giọng Edge
    public double edgeRatePercent = 40;
    public VoiceEngine engine = VoiceEngine.windows;
    public string edgeVoice = "vi-VN-NamMinhNeural";
    public Action<string>? onEngineFallback;
    /// Tốc độ giọng Windows (1 = bình thường).
    public double rate = 1.25;
    public bool interrupt = true;
    public string voiceIdentifier = "";
    public string language = "vi";
    public bool adaptiveRate = true;
    /// Khi câu trước chưa đọc xong (đọc lần lượt, không ngắt): câu kế tiếp nhanh thêm chừng này để bắt kịp.
    public double catchUpBoost = 0.10;
    /// --mute: vẫn tổng hợp (để log/test) nhưng volume 0
    public bool silent;
    /// Phát giọng đọc trên TV / điện thoại: tạo âm thanh của câu rồi gửi qua máy chủ web thay vì phát ra loa máy này.
    public bool remote;
    /// (âm thanh, kiểu MIME, ngắt câu đang đọc?, câu) → máy chủ web.
    public Action<byte[], string, bool, string>? onRemoteAudio;
    Task? remoteChain;
    CancellationTokenSource? remoteCts;

    public bool isSpeaking => pcmPlayer.isBusy || streamPlayer.busyUntil > DateTime.UtcNow || (edgeTask != null && !edgeTask.IsCompleted);

    static string Head(string s, int n) => s.Length > n ? s[..n] : s;
    static int Words(string s) => TextUtils.WordCount(s);

    /// `enqueue` = đọc nối tiếp sau câu đang đọc (không cắt), dùng cho câu thứ 2 trở đi của cùng một lô phụ đề.
    public void Speak(string text, bool enqueue = false)
    {
        if (string.IsNullOrEmpty(text)) return;
        bool flush = interrupt && !enqueue;
        if (remote && onRemoteAudio != null) { SpeakRemote(text, flush); return; }
        if (engine == VoiceEngine.edge && edgeFailures < 3) { SpeakEdge(text, flush); return; }
        streamPlayer.Stop();
        if (engine == VoiceEngine.local && language == "vi") { SpeakLocal(text, flush); return; }
        SpeakWindows(text, flush);
    }

    /// Giọng AI offline: tổng hợp cả câu trên hàng đợi riêng (~0,1–0,3 s) rồi phát.
    void SpeakLocal(string text, bool flush)
    {
        var voiceID = localVoiceID; var isSilent = silent;
        float speed = (float)localSpeed;
        if (adaptiveRate)
        {
            int w = Words(text);
            if (w > 30) speed *= 1.3f; else if (w > 20) speed *= 1.2f; else if (w > 12) speed *= 1.1f;
        }
        int gen = Interlocked.Increment(ref localGeneration);
        var t0 = DateTime.UtcNow;
        local.queue.Async(() =>
        {
            if (flush && gen != localGeneration) return;       // đã có câu mới hơn → bỏ
            var sp = speed;
            bool backlog = !flush && pcmPlayer.isBusy;
            if (backlog) sp *= (float)(1 + catchUpBoost);     // còn câu đang đọc → nhanh hơn để bắt kịp
            float[]? samples = local.Load(voiceID) ? local.Synthesize(text, sp) : null;
            if (samples == null)
            {
                Log.Warn($"Giọng AI offline '{voiceID}' chưa tải hoặc lỗi → giọng Windows");
                onEngineFallback?.Invoke("Chưa tải giọng AI offline, tạm dùng giọng Windows");
                SpeakWindows(text, flush);
                return;
            }
            if (flush && gen != localGeneration) return;
            var ms = (int)(DateTime.UtcNow - t0).TotalMilliseconds;
            var dur = (double)samples.Length / local.sampleRate;
            pcmPlayer.volume = isSilent ? 0 : 1;
            pcmPlayer.Play(samples, local.sampleRate, flush);
            Log.Info($"SPEAK local {voiceID}{(backlog ? " [bắt kịp]" : "")} speed={sp:0.00} tổng hợp={ms}ms âm thanh={dur:0.0}s: {Head(text, 40)}");
        });
    }

    /// Giọng Windows: tổng hợp WAV trên hàng đợi riêng rồi phát.
    void SpeakWindows(string text, bool flush)
    {
        var isSilent = silent; var vid = voiceIdentifier; var bcp = TargetLanguage.Find(language).bcp47;
        double r = rate;
        if (adaptiveRate)
        {
            int w = Words(text);
            if (w > 30) r *= 1.35; else if (w > 20) r *= 1.25; else if (w > 12) r *= 1.12;
        }
        int gen = Interlocked.Increment(ref localGeneration);
        winQueue.Async(() =>
        {
            if (flush && gen != localGeneration) return;
            bool backlog = !flush && pcmPlayer.isBusy;
            var rr = backlog ? r * (1 + catchUpBoost) : r;
            try
            {
                var res = win.Synthesize(text, vid, bcp, rr).GetAwaiter().GetResult();
                if (res == null) return;
                if (flush && gen != localGeneration) return;
                pcmPlayer.volume = isSilent ? 0 : 1;
                pcmPlayer.PlayPcm16(res.Value.pcm, res.Value.sampleRate, flush);
                Log.Info($"SPEAK voice={res.Value.voiceName}{(backlog ? " [bắt kịp]" : "")} rate={rr:0.00}: {Head(text, 60)}");
            }
            catch (Exception e) { Log.Error($"Giọng Windows lỗi: {e.Message}"); }
        });
    }

    /// Nạp sẵn model giọng offline để câu đầu không bị trễ.
    public void PreloadLocal()
    {
        if (engine != VoiceEngine.local) return;
        var id = localVoiceID;
        local.queue.Async(() => local.Load(id));
    }

    int EdgeRate(string text, bool flush)
    {
        int pct = (int)Math.Round(edgeRatePercent);
        if (!flush && edgeTask != null && !edgeTask.IsCompleted) pct += (int)Math.Round(catchUpBoost * 100);
        if (adaptiveRate)
        {
            int w = Words(text);
            if (w > 30) pct += 30; else if (w > 20) pct += 20; else if (w > 12) pct += 10;
        }
        return Math.Clamp(pct, -40, 100);
    }

    /// Giữ một kết nối Edge luôn sẵn sàng (gọi định kỳ khi pipeline chạy).
    public void KeepWarm() { if (engine == VoiceEngine.edge && edgeFailures < 3) edge.KeepWarm(); }

    /// Mở sẵn kết nối Edge (gọi khi vừa OCR được câu mới, trong lúc đang dịch).
    public void Prewarm() { if (engine == VoiceEngine.edge && edgeFailures < 3) edge.Prewarm(); }

    void SpeakEdge(string text, bool flush)
    {
        var voice = edgeVoice; int pct = EdgeRate(text, flush); var isSilent = silent;
        var prev = edgeTask;
        if (flush) edgeCts?.Cancel();
        var cts = new CancellationTokenSource();
        edgeCts = cts;
        int gen = Interlocked.Increment(ref edgeGeneration);
        var t0 = DateTime.UtcNow;
        edgeTask = Task.Run(async () =>
        {
            if (!flush && prev != null) { try { await prev; } catch { } }   // chế độ đọc lần lượt: đợi câu trước nhận xong
            if (cts.IsCancellationRequested) return;
            if (flush) pcmPlayer.Stop();
            streamPlayer.volume = isSilent ? 0 : 1;
            streamPlayer.Begin(flush);
            int firstMs = -1;
            try
            {
                var mp3 = await edge.Synthesize(text, voice, pct, chunk =>
                {
                    if (flush && gen != edgeGeneration) return;   // câu đã bị ngắt → bỏ
                    if (firstMs < 0) firstMs = (int)(DateTime.UtcNow - t0).TotalMilliseconds;
                    streamPlayer.Feed(chunk);
                }, cts.Token);
                edgeFailures = 0;
                if (cts.IsCancellationRequested) return;
                if (streamPlayer.scheduledFrames == 0)
                {
                    // Lưới an toàn: giải mã streaming không ra âm thanh → phát cả file.
                    Log.Warn("Edge streaming không giải mã được → phát cả file");
                    streamPlayer.PlayWhole(mp3);
                }
                var m = edge.lastMarks;
                Log.Info($"SPEAK edge {voice} rate=+{pct}% warm={m.warm} sent={m.sentMs}ms firstAudio={m.firstMs}ms (từ lúc gọi: first={firstMs}ms total={(int)(DateTime.UtcNow - t0).TotalMilliseconds}ms) {mp3.Length / 1024}KB: {Head(text, 40)}");
            }
            catch (Exception e)
            {
                if (cts.IsCancellationRequested || e is OperationCanceledException) return;
                edgeFailures++;
                Log.Warn($"Edge TTS lỗi ({edgeFailures}/3): {e.Message} → giọng Windows");
                if (edgeFailures >= 3) onEngineFallback?.Invoke("Edge TTS lỗi liên tiếp, tạm dùng giọng Windows");
                SpeakWindows(text, flush);
            }
        });
    }

    /// Cho phép thử lại Edge sau khi đã lỗi 3 lần (ví dụ khi có mạng lại).
    public void ResetEdgeFailures() => edgeFailures = 0;

    public void Stop()
    {
        edgeCts?.Cancel(); edgeTask = null;
        Interlocked.Increment(ref edgeGeneration);
        streamPlayer.Stop();
        Interlocked.Increment(ref localGeneration);
        pcmPlayer.Stop();
        remoteCts?.Cancel(); remoteChain = null;
    }

    // MARK: phát giọng đọc trên TV / điện thoại

    /// Tạo âm thanh của câu bằng đúng engine đang chọn (cùng giọng, cùng tốc độ như khi đọc ra loa) rồi gửi đi.
    /// Các câu được tạo song song nhưng gửi đúng thứ tự; `flush` = bảo bên nhận bỏ câu đang đọc.
    void SpeakRemote(string text, bool flush)
    {
        var prev = remoteChain;
        if (flush) remoteCts?.Cancel();
        if (flush || remoteCts == null || remoteCts.IsCancellationRequested) remoteCts = new CancellationTokenSource();
        var ct = remoteCts.Token;
        var useEngine = engine == VoiceEngine.edge && edgeFailures < 3 ? VoiceEngine.edge : engine == VoiceEngine.local && language == "vi" ? VoiceEngine.local : VoiceEngine.windows;
        bool backlog = !flush && prev != null && !prev.IsCompleted;
        int edgePct = EdgeRate(text, flush);
        var voiceID = localVoiceID; var vid = voiceIdentifier; var bcp = TargetLanguage.Find(language).bcp47; var ev = edgeVoice;
        var t0 = DateTime.UtcNow;
        remoteChain = Task.Run(async () =>
        {
            (byte[] data, string mime)? audio = null;
            try { audio = await RenderAudio(text, useEngine, backlog, edgePct, voiceID, vid, bcp, ev, ct); }
            catch (Exception e) { Log.Warn($"Không tạo được âm thanh để gửi lên TV: {e.Message}"); }
            if (!flush && prev != null) { try { await prev; } catch { } }
            if (ct.IsCancellationRequested || audio == null) return;
            onRemoteAudio?.Invoke(audio.Value.data, audio.Value.mime, flush, text);
            Log.Info($"SPEAK→TV {useEngine} {audio.Value.data.Length / 1024}KB {(int)(DateTime.UtcNow - t0).TotalMilliseconds}ms: {Head(text, 40)}");
        });
    }

    async Task<(byte[], string)?> RenderAudio(string text, VoiceEngine eng, bool backlog, int edgePct, string voiceID, string vid, string bcp, string ev, CancellationToken ct)
    {
        if (eng == VoiceEngine.edge)
        {
            try { return (await edge.Synthesize(text, ev, edgePct, null, ct), "audio/mpeg"); }
            catch (Exception e) when (!ct.IsCancellationRequested) { Log.Warn($"Edge TTS (gửi TV) lỗi: {e.Message} → giọng Windows"); }
        }
        if (eng == VoiceEngine.local)
        {
            float speed = (float)localSpeed;
            if (adaptiveRate) { int w = Words(text); if (w > 30) speed *= 1.3f; else if (w > 20) speed *= 1.2f; else if (w > 12) speed *= 1.1f; }
            if (backlog) speed *= (float)(1 + catchUpBoost);
            var tcs = new TaskCompletionSource<(float[], int)?>();
            local.queue.Async(() =>
            {
                var s = local.Load(voiceID) ? local.Synthesize(text, speed) : null;
                tcs.SetResult(s == null ? null : (s, local.sampleRate));
            });
            if (await tcs.Task is { } r) return (Wav(r.Item1, r.Item2), "audio/wav");
        }
        double rr = rate;
        if (adaptiveRate) { int w = Words(text); if (w > 30) rr *= 1.35; else if (w > 20) rr *= 1.25; else if (w > 12) rr *= 1.12; }
        if (backlog) rr *= 1 + catchUpBoost;
        var res = await win.Synthesize(text, vid, bcp, rr);
        return res == null ? null : (WavPcm16(res.Value.pcm, res.Value.sampleRate), "audio/wav");
    }

    /// WAV PCM 16-bit mono.
    public static byte[] Wav(float[] samples, int sampleRate)
    {
        var pcm = new byte[samples.Length * 2];
        for (int i = 0; i < samples.Length; i++)
        {
            var s = (short)Math.Clamp((int)(samples[i] * 32767f), short.MinValue, short.MaxValue);
            pcm[2 * i] = (byte)s; pcm[2 * i + 1] = (byte)(s >> 8);
        }
        return WavPcm16(pcm, sampleRate);
    }

    public static byte[] WavPcm16(byte[] pcm, int sampleRate)
    {
        using var ms = new System.IO.MemoryStream(44 + pcm.Length);
        using var w = new System.IO.BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write(36 + pcm.Length); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(sampleRate); w.Write(sampleRate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(pcm.Length); w.Write(pcm);
        w.Flush();
        return ms.ToArray();
    }

    /// Gọi khi pipeline dừng hẳn: trả lại RAM của model giọng offline (lần chạy sau `PreloadLocal` nạp lại).
    public void ReleaseResources() => local.queue.Async(local.Unload);
}
