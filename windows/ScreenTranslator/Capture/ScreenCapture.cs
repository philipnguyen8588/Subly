using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Chụp màn hình bằng GDI (thay ScreenCaptureKit). Cửa sổ của app đã đặt WDA_EXCLUDEFROMCAPTURE nên không lọt vào ảnh.
public static class ScreenCapture
{
    /// Chụp một vùng màn hình (pixel vật lý toàn cục).
    public static Frame? CaptureScreen(RectD r)
    {
        int x = (int)Math.Round(r.X), y = (int)Math.Round(r.Y), w = (int)Math.Round(r.Width), h = (int)Math.Round(r.Height);
        if (w < 2 || h < 2) return null;
        var screen = Win32.GetDC(IntPtr.Zero);
        try { return Blit(screen, x, y, w, h); }
        finally { Win32.ReleaseDC(IntPtr.Zero, screen); }
    }

    static Frame? Blit(IntPtr srcDC, int sx, int sy, int w, int h, Func<IntPtr, bool>? draw = null)
    {
        var mem = Win32.CreateCompatibleDC(srcDC);
        var bmi = new Win32.BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf<Win32.BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32,
        };
        var hbmp = Win32.CreateDIBSection(mem, ref bmi, 0, out var bits, IntPtr.Zero, 0);
        if (hbmp == IntPtr.Zero) { Win32.DeleteDC(mem); return null; }
        var old = Win32.SelectObject(mem, hbmp);
        try
        {
            bool ok = draw != null ? draw(mem) : Win32.BitBlt(mem, 0, 0, w, h, srcDC, sx, sy, Win32.SRCCOPY);
            if (!ok) return null;
            var f = new Frame(w, h);
            Marshal.Copy(bits, f.Data, 0, f.Data.Length);
            // Kênh alpha của GDI không đáng tin → đặt 255
            for (int i = 3; i < f.Data.Length; i += 4) f.Data[i] = 255;
            return f;
        }
        finally
        {
            Win32.SelectObject(mem, old);
            Win32.DeleteObject(hbmp);
            Win32.DeleteDC(mem);
        }
    }

    /// Chụp thẳng cửa sổ (kể cả khi bị che) bằng PrintWindow(PW_RENDERFULLCONTENT). Ảnh theo khung GetWindowRect.
    public static Frame? CaptureWindow(IntPtr hwnd)
    {
        if (!Win32.GetWindowRect(hwnd, out var r) || r.Width < 2 || r.Height < 2) return null;
        var screen = Win32.GetDC(IntPtr.Zero);
        Frame? f;
        try { f = Blit(screen, 0, 0, r.Width, r.Height, mem => Win32.PrintWindow(hwnd, mem, Win32.PW_RENDERFULLCONTENT)); }
        finally { Win32.ReleaseDC(IntPtr.Zero, screen); }
        if (f == null) return null;
        // Cửa sổ không hỗ trợ DPI (game cũ, app Win32 cũ) được Windows phóng to khi hiển thị, nhưng PrintWindow vẽ theo
        // kích thước logic → nội dung chỉ chiếm góc trên-trái. Cắt phần đó và phóng lại cho khớp toạ độ trên màn hình.
        double winScale = WindowDpiScale(hwnd), monScale = Win32.ScaleAt(r.Left + r.Width / 2.0, r.Top + r.Height / 2.0);
        if (winScale > 0 && winScale < monScale - 0.01)
        {
            double k = winScale / monScale;
            var part = f.Crop(0, 0, (int)Math.Round(r.Width * k), (int)Math.Round(r.Height * k));
            if (part == null) return f;
            var up = part.Scale(1 / k);
            return up.Width == r.Width && up.Height == r.Height ? up : up.Crop(0, 0, Math.Min(up.Width, r.Width), Math.Min(up.Height, r.Height)) ?? up;
        }
        return f;
    }

    static double WindowDpiScale(IntPtr hwnd)
    {
        try { var d = Win32.GetDpiForWindow(hwnd); return d > 0 ? d / 96.0 : 0; }
        catch { return 0; }
    }

    /// Ảnh toàn đen (PrintWindow không lấy được nội dung DirectX/fullscreen) → nên chụp màn hình thay thế.
    public static bool IsBlank(Frame f)
    {
        int step = Math.Max(4, f.Data.Length / 4 / 2000) * 4;
        for (int i = 0; i < f.Data.Length; i += step)
            if (f.Data[i] > 8 || f.Data[i + 1] > 8 || f.Data[i + 2] > 8) return false;
        return true;
    }

    public record Target(IntPtr hwnd, RectD local, RectD windowBounds);

    /// Vùng bám cửa sổ: tìm cửa sổ và vùng cục bộ (đã co giãn theo kích thước hiện tại).
    public static Target? WindowTarget(Region region, out string? error)
    {
        error = null;
        var h = WindowFinder.FindWindow(region);
        if (h == IntPtr.Zero || WindowFinder.Bounds(h) is not RectD b)
        {
            error = $"Không thấy cửa sổ của {region.appName ?? region.appBundleID}";
            return null;
        }
        var local = (region.LocalRect(b.Width, b.Height) ?? new RectD()).Intersect(new RectD(0, 0, b.Width, b.Height));
        if (local.Width < 8 || local.Height < 8)
        {
            error = $"Vùng nằm ngoài cửa sổ {region.appName ?? region.appBundleID} (cửa sổ đã đổi kích thước?) → Chọn lại";
            return null;
        }
        return new Target(h, local, b);
    }

    /// Chụp một vùng (cửa sổ hoặc màn hình). `scale` &gt; 1 = phóng to cho OCR, &lt; 1 = thu nhỏ (thumbnail).
    public static Frame Capture(Region region, double scale = 1)
    {
        Frame? f;
        if (region.embedded)
        {
            f = PS5Stream.shared.LatestFrame()?.frame?.CropNormalized(region.rect)
                ?? throw new InvalidOperationException("Chưa có hình từ PS5 (chưa kết nối)");
        }
        else if (region.followsWindow)
        {
            var t = WindowTarget(region, out var err) ?? throw new InvalidOperationException(err);
            var full = Win32.IsIconic(t.hwnd) ? null : CaptureWindow(t.hwnd);
            f = full?.Crop((int)t.local.X, (int)t.local.Y, (int)t.local.Width, (int)t.local.Height);
            if (f == null || IsBlank(f))
                f = CaptureScreen(new RectD(t.windowBounds.X + t.local.X, t.windowBounds.Y + t.local.Y, t.local.Width, t.local.Height));
        }
        else
        {
            f = CaptureScreen(region.rect);
        }
        if (f == null) throw new InvalidOperationException("Vùng quá nhỏ hoặc nằm ngoài màn hình");
        if (Math.Abs(scale - 1) > 0.01) f = scale < 1 ? f.Downscale(Math.Max(16, (int)(f.Width * scale))) : f.Scale(scale);
        return f;
    }

    public static Task<Frame> CaptureAsync(Region region, double scale = 1) => Task.Run(() => Capture(region, scale));
}

/// Nguồn khung hình cho một vùng: màn hình/cửa sổ (RegionCapture) hoặc luồng PS5 nhúng (PS5FrameCapture).
public interface IFrameCapture
{
    Action<Frame>? onFrame { get; set; }
    /// Nguồn bị dừng ngoài ý muốn.
    Action<Exception>? onStopped { get; set; }
    void Start();
    void Stop();
}

/// Chụp một vùng `fps` lần mỗi giây trên thread riêng (GDI rất rẻ cho vùng nhỏ).
/// Vùng bám cửa sổ: chụp cửa sổ (PrintWindow) mỗi khung nên tự theo khi cửa sổ di chuyển / đổi cỡ.
public sealed class RegionCapture : IFrameCapture
{
    public readonly Region region;
    readonly int fps;
    readonly double scale;
    public Action<Frame>? onFrame { get; set; }
    public Action<Exception>? onStopped { get; set; }
    Thread? thread;
    volatile bool running;
    int failures;
    RectD lastWindow;

    public RegionCapture(Region region, int fps, double scale)
    {
        this.region = region; this.fps = Math.Max(1, fps); this.scale = scale;
    }

    public void Start()
    {
        // Thử chụp ngay một khung để báo lỗi sớm (cửa sổ không còn, vùng ngoài màn hình…).
        ScreenCapture.Capture(region, 1);
        running = true;
        thread = new Thread(Loop) { IsBackground = true, Name = $"capture.{region.name}", Priority = ThreadPriority.AboveNormal };
        thread.Start();
        Log.Info($"Capture started '{region.name}' {(region.followsWindow ? $"window({region.appName ?? "?"})" : "display")} {region.rect} @{fps}fps");
    }

    void Loop()
    {
        var interval = TimeSpan.FromSeconds(1.0 / fps);
        var next = DateTime.UtcNow;
        while (running)
        {
            try
            {
                if (region.followsWindow)
                {
                    var t = ScreenCapture.WindowTarget(region, out _);
                    if (t != null && (Math.Abs(t.windowBounds.Width - lastWindow.Width) > 1 || Math.Abs(t.windowBounds.Height - lastWindow.Height) > 1))
                    {
                        if (lastWindow.Width > 0)
                            Log.Info($"Cửa sổ '{region.appName ?? "?"}' đổi cỡ {(int)t.windowBounds.Width}×{(int)t.windowBounds.Height} → vùng '{region.name}' = {t.local}");
                        lastWindow = t.windowBounds;
                    }
                }
                var f = ScreenCapture.Capture(region, scale);
                failures = 0;
                onFrame?.Invoke(f);
            }
            catch (Exception e)
            {
                failures++;
                if (failures == 1) Log.Warn($"Capture '{region.name}' lỗi: {e.Message}");
                if (failures >= Math.Max(8, fps * 3))
                {
                    running = false;
                    Log.Error($"Capture '{region.name}' stopped with error: {e.Message}");
                    onStopped?.Invoke(e);
                    return;
                }
            }
            next += interval;
            var wait = next - DateTime.UtcNow;
            if (wait > TimeSpan.Zero) Thread.Sleep(wait); else next = DateTime.UtcNow;
        }
    }

    public void Stop()
    {
        if (!running && thread == null) return;
        running = false;
        thread = null;
        Log.Info($"Capture stopped '{region.name}'");
    }
}

/// Cắt vùng (toạ độ chuẩn hoá 0...1) từ khung hình PS5 mới nhất, `fps` lần mỗi giây.
public sealed class PS5FrameCapture : IFrameCapture
{
    public readonly Region region;
    readonly int fps;
    public Action<Frame>? onFrame { get; set; }
    public Action<Exception>? onStopped { get; set; }
    Timer? timer;
    long lastIndex = -1;

    public PS5FrameCapture(Region region, int fps) { this.region = region; this.fps = Math.Max(1, fps); }

    public void Start()
    {
        timer = new Timer(_ => Tick(), null, 0, 1000 / fps);
        Log.Info($"Capture started '{region.name}' PS5 nhúng {region.rect} @{fps}fps");
    }

    public void Stop() { timer?.Dispose(); timer = null; }

    void Tick()
    {
        var latest = PS5Stream.shared.LatestFrame();
        if (latest == null || latest.Value.index == lastIndex) return;
        lastIndex = latest.Value.index;
        var c = latest.Value.frame.CropNormalized(region.rect);
        if (c != null) onFrame?.Invoke(c);
    }
}
