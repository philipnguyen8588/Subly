using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace ScreenTranslator;

/// P/Invoke tới sherpa-onnx-c-api.dll (bản win-x64 dựng sẵn v1.13.8, tải bằng Scripts/fetch-sherpa.ps1).
static class SherpaNative
{
    const string Dll = "sherpa-onnx-c-api";

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SherpaOnnxCreateOfflineTts(IntPtr config);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void SherpaOnnxDestroyOfflineTts(IntPtr tts);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int SherpaOnnxOfflineTtsSampleRate(IntPtr tts);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SherpaOnnxOfflineTtsGenerate(IntPtr tts, IntPtr text, int sid, float speed);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void SherpaOnnxDestroyOfflineTtsGeneratedAudio(IntPtr audio);

    // Offset (x64) trong SherpaOnnxOfflineTtsConfig của sherpa-onnx v1.13.8 (xem Sources/CSherpaOnnx/include/sherpa_onnx_c_api.h):
    // model.vits {model 0, lexicon 8, tokens 16, data_dir 24, noise_scale 32, noise_scale_w 36, length_scale 40, dict_dir 48}
    // model.num_threads 56, model.debug 60, model.provider 64, ... model kết thúc ở 416;
    // rule_fsts 416, max_num_sentences 424, rule_fars 432, silence_scale 440. Tổng 448 byte.
    public const int ConfigSize = 448;
    public const int OffVitsModel = 0, OffVitsTokens = 16, OffVitsDataDir = 24, OffNoise = 32, OffNoiseW = 36, OffLength = 40;
    public const int OffNumThreads = 56, OffProvider = 64, OffMaxSentences = 424;

    static bool? available;
    public static bool Available
    {
        get
        {
            if (available is bool b) return b;
            try { available = NativeLibrary.TryLoad(Path.Combine(AppPaths.AppDir, Dll + ".dll"), out _); }
            catch { available = false; }
            return available.Value;
        }
    }
}

/// Giọng AI chạy ngay trên máy: sherpa-onnx + model Piper/VITS tiếng Việt (~60 MB/giọng).
public sealed class LocalTTS
{
    IntPtr tts = IntPtr.Zero;
    string loadedVoice = "";
    public int sampleRate { get; private set; } = 22050;
    public readonly SerialQueue queue = new("local.tts", System.Threading.ThreadPriority.AboveNormal);

    /// Gọi trên `queue`. Nạp model nếu chưa nạp / đổi giọng. Trả về false nếu thiếu file.
    public bool Load(string voiceID)
    {
        if (tts != IntPtr.Zero && loadedVoice == voiceID) return true;
        Unload();
        if (!VoiceCatalog.IsInstalled(voiceID)) return false;
        if (!SherpaNative.Available) { Log.Error("LocalTTS: thiếu sherpa-onnx-c-api.dll (chạy Scripts/fetch-sherpa.ps1)"); return false; }
        var sw = Stopwatch.StartNew();
        var allocs = new List<IntPtr>();
        IntPtr S(string s) { var p = Marshal.StringToCoTaskMemUTF8(s); allocs.Add(p); return p; }
        var cfg = Marshal.AllocHGlobal(SherpaNative.ConfigSize + 64);
        try
        {
            unsafe { new Span<byte>((void*)cfg, SherpaNative.ConfigSize + 64).Clear(); }
            Marshal.WriteIntPtr(cfg, SherpaNative.OffVitsModel, S(VoiceCatalog.ModelPath(voiceID)));
            Marshal.WriteIntPtr(cfg, SherpaNative.OffVitsTokens, S(VoiceCatalog.TokensPath));
            Marshal.WriteIntPtr(cfg, SherpaNative.OffVitsDataDir, S(VoiceCatalog.EspeakPath));
            WriteFloat(cfg, SherpaNative.OffNoise, 0.667f);
            WriteFloat(cfg, SherpaNative.OffNoiseW, 0.8f);
            WriteFloat(cfg, SherpaNative.OffLength, 1.0f);
            Marshal.WriteInt32(cfg, SherpaNative.OffNumThreads, 2);
            Marshal.WriteIntPtr(cfg, SherpaNative.OffProvider, S("cpu"));
            Marshal.WriteInt32(cfg, SherpaNative.OffMaxSentences, 2);
            var created = SherpaNative.SherpaOnnxCreateOfflineTts(cfg);
            if (created == IntPtr.Zero) { Log.Error($"LocalTTS: không nạp được model {voiceID}"); return false; }
            tts = created;
            loadedVoice = voiceID;
            sampleRate = SherpaNative.SherpaOnnxOfflineTtsSampleRate(created);
            Log.Info($"LocalTTS: nạp giọng {voiceID} trong {sw.ElapsedMilliseconds} ms, {sampleRate} Hz");
            return true;
        }
        catch (Exception e) { Log.Error($"LocalTTS: {e.Message}"); return false; }
        finally
        {
            Marshal.FreeHGlobal(cfg);
            foreach (var p in allocs) Marshal.FreeCoTaskMem(p);
        }
    }

    static void WriteFloat(IntPtr p, int off, float v) => Marshal.WriteInt32(p, off, BitConverter.SingleToInt32Bits(v));

    /// Gọi trên `queue`.
    public float[]? Synthesize(string text, float speed)
    {
        if (tts == IntPtr.Zero) return null;
        var t = Marshal.StringToCoTaskMemUTF8(text);
        try
        {
            var audio = SherpaNative.SherpaOnnxOfflineTtsGenerate(tts, t, 0, speed);
            if (audio == IntPtr.Zero) return null;
            try
            {
                var samples = Marshal.ReadIntPtr(audio, 0);
                int n = Marshal.ReadInt32(audio, 8);
                if (n <= 0 || samples == IntPtr.Zero) return null;
                var outp = new float[n];
                Marshal.Copy(samples, outp, 0, n);
                return outp;
            }
            finally { SherpaNative.SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio); }
        }
        finally { Marshal.FreeCoTaskMem(t); }
    }

    public void Unload()
    {
        if (tts != IntPtr.Zero) SherpaNative.SherpaOnnxDestroyOfflineTts(tts);
        tts = IntPtr.Zero;
        loadedVoice = "";
    }
}
