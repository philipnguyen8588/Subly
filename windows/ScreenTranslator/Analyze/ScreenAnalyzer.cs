using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Dịch thủ công: chụp vùng manual → OCR → dịch + tóm tắt → lưu.
public sealed class ScreenAnalyzer : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => App.RunOnUI(() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n)));

    bool _running; public bool isRunning { get => _running; private set { _running = value; Raise(nameof(isRunning)); } }
    string? _err; public string? lastError { get => _err; private set { _err = value; Raise(nameof(lastError)); } }
    string _progress = ""; public string progress { get => _progress; private set { _progress = value; Raise(nameof(progress)); } }

    readonly WinOcr ocr = new();
    readonly TranslationRouter router;
    readonly Speaker speaker;
    readonly AppSettings settings = AppSettings.shared;

    public ScreenAnalyzer(TranslationRouter router, Speaker speaker) { this.router = router; this.speaker = speaker; }

    /// `present`: mở ảnh đã dịch ngay trên cửa sổ app (bấm từ điện thoại thì không, vì người bấm xem trên điện thoại).
    public async Task<ScreenAnalysis?> Analyze(List<Region> regions, bool present = true)
    {
        if (isRunning) return null;
        if (regions.Count == 0) { lastError = "Chưa có vùng dịch thủ công"; return null; }
        if (!WinOcr.Available) { lastError = WinOcr.LastError ?? "OCR không dùng được"; return null; }
        isRunning = true;
        lastError = null;
        try
        {
            var t0 = DateTime.UtcNow;
            // 1. Chụp + OCR từng vùng
            var lines = new List<string>();
            (Frame image, List<OcrBlock> blocks, int offset)? placed = null;   // vùng đầu tiên: giữ vị trí từng khối
            foreach (var r in regions)
            {
                progress = $"Đang chụp {r.name}…";
                try
                {
                    var img = await ScreenCapture.CaptureAsync(r, 1);
                    // Ảnh nhỏ (vùng < 1500 px) phóng to cho OCR đọc chữ nhỏ tốt hơn
                    var ocrImg = img.Width < 1500 ? img.Scale(Math.Min(2.0, 3000.0 / Math.Max(1, img.Width))) : img;
                    progress = "Đang nhận dạng chữ…";
                    var blocks = await Task.Run(() => ocr.RecognizeBlocks(ocrImg));
                    Log.Info($"Analyze OCR[{r.name}] {blocks.Count} khối chữ");
                    placed ??= (img, blocks, lines.Count);
                    lines.AddRange(blocks.Select(b => b.text));
                }
                catch (Exception e)
                {
                    lastError = e.Message;
                    Log.Error($"Analyze capture failed: {e.Message}");
                }
            }
            if (lines.Count == 0) { lastError ??= "Không thấy chữ nào trong vùng"; return null; }
            if (lines.Count > 80) lines = lines.Take(80).ToList();

            // 2. Dịch + tóm tắt
            progress = $"Đang dịch {lines.Count} dòng…";
            var outp = await router.Analyze(lines);
            if (outp == null) { lastError = $"Không dịch được ({router.state.label})"; return null; }
            var pairs = lines.Zip(outp.translations).Select((p, i) => new AnalysisLine { id = i + 1, source = p.First, target = p.Second }).ToList();
            var summary = outp.summary.Length == 0 ? "(Google Translate không tóm tắt; xem bản dịch từng dòng)" : outp.summary;
            int ms = (int)(DateTime.UtcNow - t0).TotalMilliseconds;
            // Vị trí từng khối chữ trên ảnh của vùng đầu tiên, để vẽ bản dịch đè đúng chỗ.
            var items = new List<ShotItem>();
            if (placed is { } pl)
                for (int i = 0; i < pl.blocks.Count; i++)
                {
                    int k = pl.offset + i;
                    if (k >= outp.translations.Count || outp.translations[k].Length == 0 || k >= lines.Count) continue;
                    var b = pl.blocks[i];
                    items.Add(new ShotItem { id = i, x = b.box.X, y = b.box.Y, w = b.box.Width, h = b.box.Height, lines = b.lines, source = b.text, target = outp.translations[k] });
                }
            ScreenAnalysis a = null!;
            await App.InvokeOnUI(() =>
            {
                a = HistoryStore.shared.AddAnalysis(string.Join(", ", regions.Select(r => r.name)), placed?.image, items, summary, pairs,
                                                    outp.backend, ms, HistoryStore.ProfileKey(settings.activeProfile.id));
                if (present && a.hasImage) ShotViewer.Show(a.id);
            });
            Log.Info($"Analyze done [{outp.backend}] {ms}ms: {(summary.Length > 80 ? summary[..80] : summary)}");
            if (settings.analyzeSpeakSummary && settings.voiceOn && outp.summary.Length > 0)
                App.RunOnUI(() => speaker.Speak(outp.summary));
            return a;
        }
        finally
        {
            isRunning = false;
            progress = "";
        }
    }
}
