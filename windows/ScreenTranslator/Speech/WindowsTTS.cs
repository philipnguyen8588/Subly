using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Windows.Media.SpeechSynthesis;

namespace ScreenTranslator;

/// Giọng có sẵn của Windows (OneCore: vi-VN "An", en-US "Aria/David/Zira"…), tổng hợp ra WAV rồi phát qua PcmStreamPlayer.
public sealed class WindowsTTS
{
    readonly SpeechSynthesizer synth = new();
    string currentVoiceId = "";
    readonly HashSet<string> warned = new();

    public record VoiceItem(string id, string name, string language, string gender);

    public static List<VoiceItem> AllVoices()
    {
        try
        {
            return SpeechSynthesizer.AllVoices
                .Select(v => new VoiceItem(v.Id, v.DisplayName, v.Language, v.Gender.ToString()))
                .ToList();
        }
        catch (Exception e) { Log.Warn($"Không liệt kê được giọng Windows: {e.Message}"); return new(); }
    }

    /// Giọng cho ngôn ngữ đích (bcp47 vd "vi-VN"); zh-* phải khớp đúng vùng.
    public static List<VoiceItem> VoicesFor(string bcp47)
    {
        var want = bcp47.ToLowerInvariant();
        var prefix = want.Split('-')[0];
        return AllVoices().Where(v =>
        {
            var l = v.language.ToLowerInvariant();
            return want.StartsWith("zh") ? l == want : l.StartsWith(prefix);
        }).ToList();
    }

    VoiceInformation? Resolve(string voiceId, string bcp47)
    {
        try
        {
            var all = SpeechSynthesizer.AllVoices;
            var prefix = bcp47.ToLowerInvariant().Split('-')[0];
            if (!string.IsNullOrEmpty(voiceId))
            {
                var v = all.FirstOrDefault(x => x.Id == voiceId);
                if (v != null && v.Language.ToLowerInvariant().StartsWith(prefix)) return v;
                Log.Warn($"Voice id '{voiceId}' không dùng được cho {bcp47} → chọn tự động");
            }
            var cands = all.Where(x => bcp47.ToLowerInvariant().StartsWith("zh")
                    ? x.Language.ToLowerInvariant() == bcp47.ToLowerInvariant()
                    : x.Language.ToLowerInvariant().StartsWith(prefix)).ToList();
            if (cands.Count == 0 && warned.Add(bcp47)) Log.Warn($"Không có giọng Windows cho {bcp47} (cài thêm trong Settings → Time & language → Speech) → dùng giọng mặc định");
            return cands.FirstOrDefault();
        }
        catch { return null; }
    }

    /// Trả về PCM 16-bit mono/stereo + sample rate. `rate` 0.5…6 (1 = bình thường).
    public async Task<(byte[] pcm, int sampleRate, int channels, string voiceName)?> Synthesize(string text, string voiceId, string bcp47, double rate)
    {
        var v = Resolve(voiceId, bcp47);
        if (v != null && v.Id != currentVoiceId) { synth.Voice = v; currentVoiceId = v.Id; }
        synth.Options.SpeakingRate = Math.Clamp(rate, 0.5, 6.0);
        using var stream = await synth.SynthesizeTextToStreamAsync(text);
        var bytes = new byte[stream.Size];
        using (var reader = new Windows.Storage.Streams.DataReader(stream.GetInputStreamAt(0)))
        {
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(bytes);
        }
        // Phân tích WAV
        using var ms = new MemoryStream(bytes);
        using var wav = new NAudio.Wave.WaveFileReader(ms);
        var fmt = wav.WaveFormat;
        var pcm = new byte[wav.Length];
        int read = wav.Read(pcm, 0, pcm.Length);
        if (fmt.Channels == 2)
        {
            // Trộn về mono
            var mono = new byte[read / 2];
            for (int i = 0, j = 0; i + 3 < read; i += 4, j += 2)
            {
                int l = (short)(pcm[i] | pcm[i + 1] << 8), r = (short)(pcm[i + 2] | pcm[i + 3] << 8);
                short m = (short)((l + r) / 2);
                mono[j] = (byte)m; mono[j + 1] = (byte)(m >> 8);
            }
            return (mono, fmt.SampleRate, 1, v?.DisplayName ?? "default");
        }
        return (pcm[..read], fmt.SampleRate, fmt.Channels, v?.DisplayName ?? "default");
    }
}
