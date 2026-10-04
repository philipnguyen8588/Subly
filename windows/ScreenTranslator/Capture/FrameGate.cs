using System;

namespace ScreenTranslator;

/// Chữ ký 64×8 (độ sáng trung bình theo ô) để phát hiện thay đổi rẻ tiền.
/// Việc "chờ ổn định" do RegionWorker xử lý bằng timer.
public sealed class FrameGate
{
    public enum Kind { first, changed, unchanged }
    public readonly record struct Verdict(Kind kind, double diff);

    public double threshold;
    const int gw = 64, gh = 8;
    byte[]? last;

    public FrameGate(double threshold = 4) { this.threshold = threshold; }

    public void Reset() => last = null;

    public Verdict Process(Frame f)
    {
        var sig = Signature(f);
        var prev = last;
        last = sig;
        if (prev == null) return new(Kind.first, 0);
        var diff = MeanAbsDiff(sig, prev);
        // Phụ đề đổi trên nền đứng yên chỉ làm đổi vài chục ô trong 512 ô nên trung bình cả vùng vẫn dưới ngưỡng
        // → xét thêm số ô đổi rõ: từ `minCells` ô lệch quá `cellDelta` mức sáng cũng coi là đổi.
        if (diff <= threshold && ChangedCells(sig, prev) >= minCells) return new(Kind.changed, diff);
        return diff > threshold ? new(Kind.changed, diff) : new(Kind.unchanged, diff);
    }

    const int cellDelta = 12, minCells = 5;
    static int ChangedCells(byte[] a, byte[] b)
    {
        int n = 0;
        for (int i = 0; i < Math.Min(a.Length, b.Length); i++) if (Math.Abs(a[i] - b[i]) > cellDelta) n++;
        return n;
    }

    static double MeanAbsDiff(byte[] a, byte[] b)
    {
        int sum = 0;
        for (int i = 0; i < Math.Min(a.Length, b.Length); i++) sum += Math.Abs(a[i] - b[i]);
        return (double)sum / Math.Max(1, a.Length);
    }

    static byte[] Signature(Frame f)
    {
        int w = f.Width, h = f.Height, bpr = f.Stride;
        var p = f.Data;
        var outp = new byte[gw * gh];
        int cellW = Math.Max(1, w / gw), cellH = Math.Max(1, h / gh);
        int step = Math.Max(1, Math.Min(cellW, cellH) / 4);
        for (int gy = 0; gy < gh; gy++)
        {
            int y0 = gy * h / gh, y1 = Math.Min(h, (gy + 1) * h / gh);
            for (int gx = 0; gx < gw; gx++)
            {
                int x0 = gx * w / gw, x1 = Math.Min(w, (gx + 1) * w / gw);
                int acc = 0, n = 0;
                for (int y = y0; y < y1; y += step)
                {
                    int row = y * bpr;
                    for (int x = x0; x < x1; x += step)
                    {
                        int px = row + x * 4;
                        acc += (p[px + 2] * 77 + p[px + 1] * 150 + p[px] * 29) >> 8;
                        n++;
                    }
                }
                outp[gy * gw + gx] = (byte)Math.Clamp(n > 0 ? acc / n : 0, 0, 255);
            }
        }
        return outp;
    }
}
