using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading;
using System.Threading.Tasks;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace ScreenTranslator;

/// Kết quả OCR (tương đương VisionOCR.Result).
public class OcrResult
{
    public string text = "";
    public List<string> lines = new();
    public double ms;
    /// Bố cục, dùng để phân biệt phụ đề với chữ giao diện (menu/cài đặt).
    public int observations;          // số mảnh chữ OCR trả về
    public int rows;                  // số hàng sau khi gom
    public int maxPerRow;             // nhiều mảnh trên một hàng = cột menu
    public double heightRatio = 1.0;  // chiều cao mảnh lớn nhất / nhỏ nhất = cỡ chữ lẫn lộn
    public List<double> lineHeights = new();   // chiều cao chữ của từng hàng trong `lines` (tỉ lệ theo chiều cao ảnh)
}

/// Một khối chữ kèm vị trí (chuẩn hoá 0...1, gốc trên-trái) để vẽ bản dịch đè lên đúng chỗ.
public class OcrBlock
{
    public string text = "";
    public RectD box;
    public int lines = 1;
    /// Chiều cao chữ trung bình của các dòng (không tính khoảng trống giữa dòng), để so cỡ chữ khi gộp đoạn.
    public double textH;
}

/// OCR bằng Windows.Media.Ocr (có sẵn trên Windows 10/11, cần gói ngôn ngữ English).
/// Windows OCR không trả confidence; mỗi OcrLine được tách thành các "mảnh" khi giữa hai từ có khoảng trống lớn,
/// để mô phỏng các observation riêng của Vision (phụ đề ở giữa, nút bấm ở mép).
public sealed class WinOcr
{
    public double minTextHeight = 0;
    /// Chỉ nhận chữ nằm ở giữa khung theo chiều ngang (phụ đề luôn canh giữa).
    public bool centerOnly;
    /// Dải giữa khung (tỉ lệ bề ngang): một cụm chữ phải chạm dải này mới được nhận.
    public const double centerBandLo = 0.40, centerBandHi = 0.60;
    /// Bỏ hàng có chữ thấp hơn mức này (tỉ lệ theo chiều cao ảnh).
    public double minRowHeight;

    static OcrEngine? engine;
    static readonly SemaphoreSlim gate = new(1, 1);
    public static string? LastError;

    public static OcrEngine? Engine
    {
        get
        {
            if (engine != null) return engine;
            try
            {
                engine = OcrEngine.TryCreateFromLanguage(new Language("en-US"))
                         ?? OcrEngine.TryCreateFromLanguage(new Language("en-GB"))
                         ?? OcrEngine.TryCreateFromLanguage(new Language("en"));
                if (engine == null)
                {
                    LastError = "Chưa cài OCR tiếng Anh. Vào Settings → Time & language → Language & region → thêm English (United States) (có Optical character recognition).";
                    Log.Error(LastError);
                }
            }
            catch (Exception e) { LastError = e.Message; Log.Error($"OCR init: {e.Message}"); }
            return engine;
        }
    }

    public static bool Available => Engine != null;

    record Frag(string text, RectD box); // box chuẩn hoá 0..1, gốc trên-trái

    /// Chạy OCR và trả về các mảnh chữ (chuẩn hoá).
    static async Task<List<Frag>?> RunRaw(Frame f)
    {
        var eng = Engine;
        if (eng == null) return null;
        // Windows OCR giới hạn kích thước ảnh; thu nhỏ nếu cần. Chữ quá nhỏ (< ~10 px) đọc kém → phóng to ảnh thấp.
        double scale = 1;
        int maxDim = (int)OcrEngine.MaxImageDimension;
        if (Math.Max(f.Width, f.Height) > maxDim) scale = (double)maxDim / Math.Max(f.Width, f.Height);
        else if (f.Height < 60) scale = Math.Min(3, 60.0 / f.Height);
        var img = Math.Abs(scale - 1) > 0.01 ? f.Scale(scale) : f;
        if (img.Width < 40 || img.Height < 40)
        {
            // Pad lên tối thiểu 40×40 (Windows OCR từ chối ảnh quá nhỏ).
            int pw = Math.Max(40, img.Width), ph = Math.Max(40, img.Height);
            var padded = new Frame(pw, ph);
            for (int y = 0; y < img.Height; y++) Buffer.BlockCopy(img.Data, y * img.Stride, padded.Data, y * padded.Stride, img.Width * 4);
            img = padded;
        }
        SoftwareBitmap sb;
        if (img.Stride == img.Width * 4)
            sb = SoftwareBitmap.CreateCopyFromBuffer(img.Data.AsBuffer(), BitmapPixelFormat.Bgra8, img.Width, img.Height, BitmapAlphaMode.Premultiplied);
        else
        {
            var tight = new byte[img.Width * img.Height * 4];
            for (int y = 0; y < img.Height; y++) Buffer.BlockCopy(img.Data, y * img.Stride, tight, y * img.Width * 4, img.Width * 4);
            sb = SoftwareBitmap.CreateCopyFromBuffer(tight.AsBuffer(), BitmapPixelFormat.Bgra8, img.Width, img.Height, BitmapAlphaMode.Premultiplied);
        }
        OcrResultWin res;
        await gate.WaitAsync();
        try { res = new OcrResultWin(await eng.RecognizeAsync(sb)); }
        catch (Exception e) { Log.Error($"OCR failed: {e.Message}"); return null; }
        finally { gate.Release(); sb.Dispose(); }

        double W = f.Width * scale, H = f.Height * scale;
        var frags = new List<Frag>();
        foreach (var line in res.r.Lines)
        {
            var words = line.Words.ToList();
            if (words.Count == 0) continue;
            // Tách dòng thành mảnh khi khoảng trống giữa hai từ > 1.5 × chiều cao chữ.
            var cur = new List<OcrWord> { words[0] };
            void Flush()
            {
                double x0 = cur.Min(w => w.BoundingRect.X), y0 = cur.Min(w => w.BoundingRect.Y);
                double x1 = cur.Max(w => w.BoundingRect.X + w.BoundingRect.Width), y1 = cur.Max(w => w.BoundingRect.Y + w.BoundingRect.Height);
                var text = string.Join(" ", cur.Select(w => w.Text));
                frags.Add(new Frag(text, new RectD(x0 / W, y0 / H, (x1 - x0) / W, (y1 - y0) / H)));
            }
            for (int i = 1; i < words.Count; i++)
            {
                var prev = words[i - 1].BoundingRect; var w = words[i].BoundingRect;
                double hgt = Math.Max(prev.Height, w.Height);
                if (w.X - (prev.X + prev.Width) > hgt * 1.5) { Flush(); cur = new List<OcrWord>(); }
                cur.Add(words[i]);
            }
            Flush();
        }
        return frags;
    }

    sealed record OcrResultWin(Windows.Media.Ocr.OcrResult r);

    /// Cho phụ đề (khung chụp liên tục).
    public async Task<OcrResult?> Recognize(Frame f)
    {
        var sw = Stopwatch.StartNew();
        var raw = await RunRaw(f);
        if (raw == null) return null;
        var r = Build(raw, centerOnly, minRowHeight);
        r.ms = sw.Elapsed.TotalMilliseconds;
        return r;
    }

    /// Cho phân tích màn hình: trả về từng dòng.
    public async Task<OcrResult?> RecognizeLines(Frame f)
    {
        var sw = Stopwatch.StartNew();
        var raw = await RunRaw(f);
        if (raw == null) return null;
        var r = Build(raw, false, 0);
        r.ms = sw.Elapsed.TotalMilliseconds;
        return r;
    }

    /// Cho "dịch đè lên màn hình": trả về từng khối chữ. Các dòng liền nhau của cùng một đoạn văn được gộp lại để dịch trọn ý.
    public async Task<List<OcrBlock>> RecognizeBlocks(Frame f)
    {
        var raw = await RunRaw(f) ?? new List<Frag>();
        var items = new List<OcrBlock>();
        foreach (var o in raw)
        {
            var text = TextUtils.Normalize(TextUtils.StripJunkTokens(o.text));
            if (TextUtils.LetterCount(text) < 2) continue;
            items.Add(new OcrBlock { text = text, box = o.box, lines = 1, textH = o.box.Height });
        }
        items.Sort((a, b) => Math.Abs(a.box.MinY - b.box.MinY) > 0.01 ? a.box.MinY.CompareTo(b.box.MinY) : a.box.MinX.CompareTo(b.box.MinX));
        // Gộp đoạn văn: dòng dưới nằm sát dòng trên, cùng lề trái, cỡ chữ tương đương.
        var outp = new List<OcrBlock>();
        foreach (var it in items)
        {
            int idx = -1;
            for (int i = outp.Count - 1; i >= 0; i--)
            {
                var prev = outp[i];
                double lineH = prev.textH;
                double gap = it.box.MinY - prev.box.MaxY;
                // Cùng lề trái, hoặc cùng tâm (đoạn chữ canh giữa như hướng dẫn, thông báo).
                bool sameLeft = Math.Abs(it.box.MinX - prev.box.MinX) < 0.012 || Math.Abs(it.box.MidX - prev.box.MidX) < 0.012;
                // Dòng không có chữ cao/thấp (dòng cuối ngắn "no amount of money can buy.") có khung thấp hơn ~30 %.
                bool sameSize = Math.Max(lineH, it.box.Height) / Math.Max(0.0001, Math.Min(lineH, it.box.Height)) < 1.5;
                // Mục menu xếp dọc cũng cùng lề nhưng cách nhau xa hơn và thường chỉ 1–2 từ → không gộp.
                bool wordy = prev.text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 3;
                // Khoảng cách dòng của đoạn văn trong game thường bằng 0,5–0,8 lần chiều cao chữ (ngưỡng cũ 0,45 tách nhầm
                // dòng đầu của đoạn ra riêng); dưới 1 lần chiều cao chữ coi là cùng đoạn.
                if (sameLeft && sameSize && wordy && gap > -lineH * 0.3 && gap < lineH * 1.0 && prev.lines < 12) { idx = i; break; }
            }
            if (idx >= 0)
            {
                var b = outp[idx];
                b.text += " " + it.text;
                double x0 = Math.Min(b.box.MinX, it.box.MinX), y0 = Math.Min(b.box.MinY, it.box.MinY);
                double x1 = Math.Max(b.box.MaxX, it.box.MaxX), y1 = Math.Max(b.box.MaxY, it.box.MaxY);
                b.box = new RectD(x0, y0, x1 - x0, y1 - y0);
                b.textH = (b.textH * b.lines + it.box.Height) / (b.lines + 1);
                b.lines += 1;
            }
            else outp.Add(it);
        }
        return outp;
    }

    /// Trong một hàng, các mảnh chữ cách nhau xa là những cụm riêng (phụ đề ở giữa, nút bấm ở mép): chỉ giữ cụm chạm dải giữa khung.
    static List<Frag> Centered(List<Frag> row)
    {
        var clusters = new List<List<Frag>>();
        foreach (var o in row.OrderBy(o => o.box.MinX))
        {
            if (clusters.Count > 0 && o.box.MinX - clusters[^1][^1].box.MaxX < 0.05) clusters[^1].Add(o);
            else clusters.Add(new List<Frag> { o });
        }
        return clusters.Where(c => c.Min(o => o.box.MinX) <= centerBandHi && c.Max(o => o.box.MaxX) >= centerBandLo)
                       .SelectMany(c => c).ToList();
    }

    /// Như `Centered` cho cả khung: giữ cụm chạm dải giữa, cộng thêm dòng tiếp nối của phụ đề bị xuống dòng
    /// ("…Are you here" / "alone?"): cụm nằm sát ngay trên/dưới một cụm đã giữ và gọn trong bề ngang của cụm đó.
    /// Nút bấm ở mép không nằm trong bề ngang của phụ đề nên vẫn bị bỏ.
    static List<List<Frag>> CenteredRows(List<List<Frag>> groups)
    {
        var rows = groups.Select(row =>
        {
            var clusters = new List<List<Frag>>();
            foreach (var o in row.OrderBy(o => o.box.MinX))
            {
                if (clusters.Count > 0 && o.box.MinX - clusters[^1][^1].box.MaxX < 0.05) clusters[^1].Add(o);
                else clusters.Add(new List<Frag> { o });
            }
            return clusters;
        }).ToList();
        static RectD Box(List<Frag> c)
        {
            double x0 = c.Min(o => o.box.MinX), y0 = c.Min(o => o.box.MinY), x1 = c.Max(o => o.box.MaxX), y1 = c.Max(o => o.box.MaxY);
            return new RectD(x0, y0, x1 - x0, y1 - y0);
        }
        var keep = rows.Select(r => r.Select(c => { var b = Box(c); return b.MinX <= centerBandHi && b.MaxX >= centerBandLo; }).ToList()).ToList();
        bool changed = true;
        while (changed)
        {
            changed = false;
            for (int i = 0; i < rows.Count; i++)
                for (int j = 0; j < rows[i].Count; j++)
                {
                    if (keep[i][j]) continue;
                    var b = Box(rows[i][j]);
                    foreach (var n in new[] { i - 1, i + 1 })
                    {
                        if (n < 0 || n >= rows.Count) continue;
                        for (int k = 0; k < rows[n].Count; k++)
                        {
                            if (!keep[n][k]) continue;
                            var kb = Box(rows[n][k]);
                            double gap = Math.Max(kb.MinY - b.MaxY, b.MinY - kb.MaxY);
                            bool inside = b.MinX >= kb.MinX - 0.02 && b.MaxX <= kb.MaxX + 0.02;
                            if (inside && gap < Math.Max(kb.Height, b.Height) * 1.2 && !keep[i][j]) { keep[i][j] = true; changed = true; }
                        }
                    }
                }
        }
        return rows.Select((r, i) => r.Where((_, j) => keep[i][j]).SelectMany(c => c).ToList()).Where(g => g.Count > 0).ToList();
    }

    OcrResult Build(List<Frag> raw, bool centerOnly, double minRowHeight)
    {
        var all = new List<Frag>();
        foreach (var o in raw)
        {
            if (minTextHeight > 0 && o.box.Height < minTextHeight) continue;
            var cleaned = TextUtils.StripJunkTokens(o.text);
            if (cleaned.Length == 0) continue;
            all.Add(o with { text = cleaned });
        }
        if (all.Count == 0) return new OcrResult();

        // Gom theo dòng (gốc trên-trái → midY nhỏ = dòng trên).
        var sorted = all.OrderBy(o => o.box.MidY).ToList();
        var groups = new List<List<Frag>>();
        foreach (var o in sorted)
        {
            if (groups.Count > 0)
            {
                var refo = groups[^1][0];
                if (Math.Abs(refo.box.MidY - o.box.MidY) < Math.Max(refo.box.Height, o.box.Height) * 0.6) { groups[^1].Add(o); continue; }
            }
            groups.Add(new List<Frag> { o });
        }
        if (centerOnly) groups = CenteredRows(groups);
        if (minRowHeight > 0) groups = groups.Where(g => g.Max(o => o.box.Height) >= minRowHeight).ToList();
        if (groups.Count == 0) return new OcrResult();
        var obs = groups.SelectMany(g => g).ToList();
        var rowsText = groups.Select(g => (text: TextUtils.Normalize(string.Join("  ", g.OrderBy(o => o.box.MinX).Select(o => o.text))),
                                           h: g.Max(o => o.box.Height)))
                             .Where(t => t.text.Length > 0).ToList();
        var lines = rowsText.Select(t => t.text).ToList();
        var heights = obs.Select(o => o.box.Height).Where(h => h > 0).ToList();
        var r = new OcrResult
        {
            text = string.Join(" ", lines),
            lines = lines,
            lineHeights = rowsText.Select(t => t.h).ToList(),
            observations = obs.Count,
            rows = groups.Count,
            maxPerRow = groups.Max(g => g.Count),
        };
        if (heights.Count > 0 && heights.Min() > 0) r.heightRatio = heights.Max() / heights.Min();
        return r;
    }
}
