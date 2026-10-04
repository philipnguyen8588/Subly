using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;

namespace ScreenTranslator;

/// Tìm cửa sổ / app trên Windows (thay CGWindowList + NSWorkspace). "Bundle ID" là tên process (vd "msedge").
public static class WindowFinder
{
    public record AppInfo(string bundleID, string name);
    public record WindowInfo(AppInfo app, IntPtr hwnd, RectD bounds, string title);

    static readonly int myPid = Environment.ProcessId;

    /// Khung cửa sổ (pixel vật lý). Dùng GetWindowRect vì PrintWindow vẽ đúng khung này.
    public static RectD? Bounds(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !Win32.IsWindow(hwnd)) return null;
        if (!Win32.GetWindowRect(hwnd, out var r)) return null;
        return r.ToRectD();
    }

    static bool IsCloaked(IntPtr h)
    {
        try { return Win32.DwmGetWindowAttribute(h, Win32.DWMWA_CLOAKED, out int v, 4) == 0 && v != 0; }
        catch { return false; }
    }

    static string Title(IntPtr h)
    {
        int n = Win32.GetWindowTextLength(h);
        if (n <= 0) return "";
        var sb = new StringBuilder(n + 1);
        Win32.GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    static readonly Dictionary<uint, AppInfo?> appCache = new();

    public static AppInfo? AppOf(IntPtr hwnd)
    {
        Win32.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == 0) return null;
        lock (appCache)
        {
            if (appCache.TryGetValue(pid, out var cached)) return cached;
            AppInfo? info = null;
            try
            {
                using var p = Process.GetProcessById((int)pid);
                var name = p.ProcessName;
                string display = name;
                try
                {
                    var path = ProcessPath(pid);
                    if (path != null)
                    {
                        var fvi = FileVersionInfo.GetVersionInfo(path);
                        if (!string.IsNullOrWhiteSpace(fvi.FileDescription)) display = fvi.FileDescription!;
                    }
                }
                catch { }
                info = new AppInfo(name, display);
            }
            catch { }
            appCache[pid] = info;
            return info;
        }
    }

    static string? ProcessPath(uint pid)
    {
        var h = Win32.OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024); uint size = (uint)sb.Capacity;
            return Win32.QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null;
        }
        finally { Win32.CloseHandle(h); }
    }

    /// Các cửa sổ cấp cao đang hiện, theo thứ tự trên → dưới, bỏ qua cửa sổ của chính app.
    public static List<WindowInfo> VisibleWindows()
    {
        var list = new List<WindowInfo>();
        Win32.EnumWindows((h, _) =>
        {
            if (!Win32.IsWindowVisible(h) || Win32.IsIconic(h) || IsCloaked(h)) return true;
            Win32.GetWindowThreadProcessId(h, out var pid);
            if (pid == myPid) return true;
            long ex = Win32.GetWindowLongPtr(h, Win32.GWL_EXSTYLE).ToInt64();
            if ((ex & Win32.WS_EX_TOOLWINDOW) != 0 && (ex & Win32.WS_EX_TRANSPARENT) != 0) return true;
            if (!Win32.GetWindowRect(h, out var r) || r.Width < 50 || r.Height < 30) return true;
            var app = AppOf(h);
            if (app == null) return true;
            list.Add(new WindowInfo(app, h, r.ToRectD(), Title(h)));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// Cửa sổ trên cùng chứa điểm (pixel vật lý toàn cục), bỏ qua chính app này.
    public static WindowInfo? WindowUnder(double x, double y)
    {
        foreach (var w in VisibleWindows())
        {
            if (!w.bounds.Contains(x, y)) continue;
            // Bỏ cửa sổ nền desktop/taskbar
            var cls = new StringBuilder(64);
            Win32.GetClassName(w.hwnd, cls, 64);
            var c = cls.ToString();
            if (c is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") continue;
            return w;
        }
        return null;
    }

    public static AppInfo? AppUnder(double x, double y) => WindowUnder(x, y)?.app;

    /// Các app đang có cửa sổ, để gắn thủ công.
    public static List<AppInfo> RunningApps() =>
        VisibleWindows().Select(w => w.app).GroupBy(a => a.bundleID).Select(g => g.First())
            .OrderBy(a => a.name.ToLowerInvariant()).ToList();

    public static string? FrontmostBundleID
    {
        get
        {
            var h = Win32.GetForegroundWindow();
            return h == IntPtr.Zero ? null : AppOf(h)?.bundleID;
        }
    }

    /// Cửa sổ app để chụp cho vùng bám cửa sổ: ưu tiên HWND lúc vẽ, không thì cửa sổ lớn nhất của process.
    public static IntPtr FindWindow(Region region)
    {
        if (region.appBundleID == null) return IntPtr.Zero;
        if (region.windowID is long id && id != 0)
        {
            var h = new IntPtr(id);
            if (Win32.IsWindow(h) && AppOf(h)?.bundleID == region.appBundleID) return h;
        }
        var cands = new List<(IntPtr h, double area)>();
        Win32.EnumWindows((h, _) =>
        {
            if (!Win32.IsWindowVisible(h)) return true;
            if (AppOf(h)?.bundleID != region.appBundleID) return true;
            if (!Win32.GetWindowRect(h, out var r) || r.Width < 100 || r.Height < 60) return true;
            cands.Add((h, (double)r.Width * r.Height));
            return true;
        }, IntPtr.Zero);
        return cands.OrderByDescending(c => c.area).Select(c => c.h).FirstOrDefault();
    }

    /// Vị trí vùng trên màn hình lúc này: vùng bám cửa sổ thì đi theo cửa sổ, còn lại dùng toạ độ đã lưu.
    public static RectD CurrentRect(Region region)
    {
        if (region.followsWindow)
        {
            var h = FindWindow(region);
            if (Bounds(h) is RectD b && region.LocalRect(b.Width, b.Height) is RectD l)
                return new RectD(b.X + l.X, b.Y + l.Y, l.Width, l.Height);
        }
        return region.rect;
    }
}
