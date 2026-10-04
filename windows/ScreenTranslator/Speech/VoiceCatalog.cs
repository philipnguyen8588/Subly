using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Giọng AI offline tải được (model Piper tiếng Việt của NGHI-TTS, bản cho sherpa-onnx).
public record LocalVoice(string id, string name, string note)
{
    public int sizeMB => 61;
}

public sealed class VoiceCatalog : INotifyPropertyChanged
{
    static readonly Lazy<VoiceCatalog> lazy = new(() => new VoiceCatalog());
    public static VoiceCatalog shared => lazy.Value;
    public event PropertyChangedEventHandler? PropertyChanged;

    /// Ghi chú dựa trên đo cao độ (F0) của 10 câu thoại: giọng dao động nhiều giữa các câu nghe như nhiều người khác nhau.
    public static readonly LocalVoice[] voices =
    {
        new("minhquang", "Minh Quang", "nam · ổn định nhất trong các giọng nam"),
        new("manhdung", "Mạnh Dũng", "nam · ổn định"),
        new("chieuthanh", "Chiếu Thành", "nam trầm · cao độ đổi khá nhiều giữa các câu"),
        new("thientam", "Thiện Tâm", "nam rất trầm · cao độ đổi nhiều giữa các câu"),
        new("deepman3909", "Deep Man", "nam giọng cao · cao độ đổi nhiều giữa các câu"),
        new("lacphi", "Lạc Phi", "nữ · ổn định nhất trong các giọng nữ"),
        new("banmai", "Ban Mai", "nữ · ổn định"),
        new("calmwoman3688", "Calm Woman", "nữ trầm"),
        new("maiphuong", "Mai Phương", "nữ"),
        new("phuongtrang", "Phương Trang", "nữ"),
        new("minhthu", "Minh Thu", "nữ giọng cao"),
    };
    public const string defaultVoiceID = "minhquang";

    public static string Dir => AppPaths.Voices;
    public static string ModelPath(string id) => Path.Combine(Dir, $"{id}.onnx");
    public static string TokensPath => Path.Combine(Dir, "tokens.txt");
    public static string EspeakPath => Path.Combine(Dir, "espeak-ng-data");
    public static bool IsInstalled(string id) =>
        File.Exists(ModelPath(id)) && File.Exists(TokensPath) && File.Exists(Path.Combine(EspeakPath, "phontab"));

    const string modelBase = "https://huggingface.co/doof-ferb/nghitts-copy/resolve/main/sherpa-onnx/";
    const string espeakArchive = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2";

    public HashSet<string> installed { get; private set; } = new();
    /// id → tiến độ 0...1
    public Dictionary<string, double> downloading { get; } = new();
    public Dictionary<string, string> errors { get; } = new();

    static readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(30) };

    VoiceCatalog() { Refresh(); }

    void Raise() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));

    public void Refresh()
    {
        installed = voices.Select(v => v.id).Where(IsInstalled).ToHashSet();
        Raise();
    }

    public void Download(string id) => _ = DownloadAsync(id);

    public async Task<bool> DownloadAsync(string id)
    {
        lock (downloading) { if (downloading.ContainsKey(id)) return false; downloading[id] = 0; }
        errors.Remove(id);
        Raise();
        bool ok = false;
        try
        {
            await EnsureCommonFiles();
            await Fetch(modelBase + $"{id}.onnx", ModelPath(id), p => { downloading[id] = p; Raise(); });
            Log.Info($"VoiceCatalog: đã tải giọng {id}");
            ok = true;
        }
        catch (Exception e)
        {
            errors[id] = e.Message;
            Log.Error($"VoiceCatalog: tải giọng {id} lỗi: {e.Message}");
        }
        lock (downloading) downloading.Remove(id);
        Refresh();
        return ok;
    }

    public void Delete(string id)
    {
        try { File.Delete(ModelPath(id)); } catch { }
        Refresh();
    }

    /// tokens.txt + espeak-ng-data (bảng phiên âm, 18 MB) dùng chung cho mọi giọng.
    static async Task EnsureCommonFiles()
    {
        if (!File.Exists(TokensPath)) await Fetch(modelBase + "tokens.txt", TokensPath, _ => { });
        if (!File.Exists(Path.Combine(EspeakPath, "phontab")))
        {
            var archive = Path.Combine(Dir, "espeak-ng-data.tar.bz2");
            await Fetch(espeakArchive, archive, _ => { });
            // Windows 10/11 có sẵn tar.exe (bsdtar) giải nén được .tar.bz2.
            var tar = Path.Combine(Environment.SystemDirectory, "tar.exe");
            var psi = new ProcessStartInfo(File.Exists(tar) ? tar : "tar", $"-xjf \"{archive}\" -C \"{Dir}\"")
            { CreateNoWindow = true, UseShellExecute = false };
            using var p = Process.Start(psi)!;
            await p.WaitForExitAsync();
            try { File.Delete(archive); } catch { }
            if (p.ExitCode != 0) throw new IOException($"Giải nén espeak-ng-data lỗi (tar exit {p.ExitCode})");
        }
    }

    static async Task Fetch(string url, string dest, Action<double> progress)
    {
        using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        if (!resp.IsSuccessStatusCode) throw new HttpRequestException($"HTTP {(int)resp.StatusCode}: {url}");
        var total = resp.Content.Headers.ContentLength ?? -1;
        var tmp = dest + ".part";
        await using (var src = await resp.Content.ReadAsStreamAsync())
        await using (var fs = File.Create(tmp))
        {
            var buf = new byte[1 << 16];
            long done = 0; int n; var last = DateTime.MinValue;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await fs.WriteAsync(buf.AsMemory(0, n));
                done += n;
                if (total > 0 && (DateTime.UtcNow - last).TotalMilliseconds > 200) { last = DateTime.UtcNow; progress((double)done / total); }
            }
        }
        File.Move(tmp, dest, true);
    }
}
