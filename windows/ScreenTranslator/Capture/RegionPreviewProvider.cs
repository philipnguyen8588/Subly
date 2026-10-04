using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Windows.Media.Imaging;

namespace ScreenTranslator;

/// Ảnh thu nhỏ + kết quả OCR gần nhất của từng vùng (để hiện trong cửa sổ chính / log).
public sealed class RegionPreviewProvider
{
    public static readonly RegionPreviewProvider shared = new();
    public record OcrInfo(double ms, string text, DateTime at);

    public readonly ConcurrentDictionary<Guid, OcrInfo> lastOCR = new();
    public readonly ConcurrentDictionary<Guid, BitmapSource> images = new();
    readonly ConcurrentDictionary<Guid, DateTime> lastPush = new();
    public event Action<Guid>? Updated;
    public bool pipelineRunning;

    /// Từ RegionWorker (thread bất kỳ), tối đa 1 ảnh/giây/vùng.
    public void PushFrame(Guid regionID, Frame f)
    {
        var now = DateTime.UtcNow;
        if (lastPush.TryGetValue(regionID, out var l) && (now - l).TotalSeconds < 1) return;
        lastPush[regionID] = now;
        try
        {
            images[regionID] = f.Downscale(320).ToBitmapSource();
            Updated?.Invoke(regionID);
        }
        catch { }
    }

    public void ReportOCR(Guid regionID, double ms, string text)
    {
        lastOCR[regionID] = new OcrInfo(ms, text, DateTime.Now);
        Updated?.Invoke(regionID);
    }

    public void Remove(Guid id) { images.TryRemove(id, out _); lastOCR.TryRemove(id, out _); }
}
