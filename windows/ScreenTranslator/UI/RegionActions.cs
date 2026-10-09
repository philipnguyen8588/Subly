using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;

namespace ScreenTranslator;

/// Thao tác vùng dùng chung cho cửa sổ chính.
public static class RegionActions
{
    // MARK: App ngoài: đúng hai khung (màn hình game + phụ đề)

    /// Vẽ khung toàn bộ khu vực hiển thị game trên màn hình. Thay khung cũ; khung phụ đề đặt lại về dải dưới.
    public static void PickGameArea()
    {
        var settings = AppSettings.shared;
        App.HideMainForPicking();
        RegionPicker.shared.Begin(rect =>
        {
            App.ShowMain();
            if (rect is not RectD r) return;
            var area = new Region { name = "Màn hình game", x = r.X, y = r.Y, width = r.Width, height = r.Height, kind = RegionKind.manual };
            AttachWindow(area);
            var regions = settings.regions.Where(x => x.embedded).ToList();      // giữ vùng PS5 (nếu có), bỏ các khung app ngoài cũ
            regions.Add(area);
            settings.regions = regions;
            Log.Info($"Vùng game: {(int)r.Width}×{(int)r.Height} {(area.appName != null ? $"gắn với {area.appName}" : "(không gắn app)")}");
            SetExternalSubtitle(new RectD(0.10, 0.74, 0.80, 0.22));
        });
    }

    /// Đặt khung phụ đề theo tỉ lệ (0...1) bên trong khung màn hình game. Khung phụ đề bám cùng cửa sổ với khung game.
    public static void SetExternalSubtitle(RectD n)
    {
        var settings = AppSettings.shared;
        if (settings.externalArea is not Region area) return;
        var a = WindowFinder.CurrentRect(area);
        var rect = new RectD(Math.Round(a.X + n.X * a.Width), Math.Round(a.Y + n.Y * a.Height), Math.Round(n.Width * a.Width), Math.Round(n.Height * a.Height));
        var sub = settings.externalSubtitle ?? new Region { name = "Phụ đề" };
        sub.displayID = area.displayID;
        sub.rect = rect;
        sub.appBundleID = area.appBundleID; sub.appName = area.appName; sub.windowID = area.windowID; sub.appMode = area.appMode;
        var h = area.followsWindow ? WindowFinder.FindWindow(area) : IntPtr.Zero;
        if (area.followsWindow && WindowFinder.Bounds(h) is RectD b)
        {
            sub.winOffsetX = rect.X - b.X; sub.winOffsetY = rect.Y - b.Y;
            sub.winWidth = b.Width; sub.winHeight = b.Height;
        }
        else { sub.winOffsetX = null; sub.winOffsetY = null; sub.winWidth = null; sub.winHeight = null; }
        var regions = settings.regions.Where(r => r.embedded || r.kind == RegionKind.manual).ToList();   // chỉ một khung phụ đề app ngoài
        regions.Add(sub);
        settings.regions = regions;
        Log.Info($"Khung phụ đề app ngoài: x {n.X:0.00} y {n.Y:0.00} w {n.Width:0.00} h {n.Height:0.00}");
        Pipeline.shared.RestartIfRunning();
    }

    /// Gắn cửa sổ cho một Region mới tạo (dùng chung cho vẽ tay và --add-region).
    public static void AttachWindow(Region r)
    {
        var w = WindowFinder.WindowUnder(r.rect.MidX, r.rect.MidY);
        if (w == null) return;
        r.appBundleID = w.app.bundleID; r.appName = w.app.name;
        r.windowID = w.hwnd.ToInt64();
        r.winOffsetX = r.x - w.bounds.X; r.winOffsetY = r.y - w.bounds.Y; r.winWidth = w.bounds.Width; r.winHeight = w.bounds.Height;
    }

    /// Vùng có app nhưng chưa có offset → bổ sung nếu cửa sổ của đúng app đó đang nằm dưới vùng.
    public static void FillMissingWindowOffsets()
    {
        var settings = AppSettings.shared;
        var regions = settings.regions;
        bool changed = false;
        foreach (var r in regions.Where(r => r.appBundleID != null && r.winOffsetX == null && !r.embedded))
        {
            var w = WindowFinder.WindowUnder(r.rect.MidX, r.rect.MidY);
            if (w != null && w.app.bundleID == r.appBundleID)
            {
                r.windowID = w.hwnd.ToInt64();
                r.winOffsetX = r.x - w.bounds.X; r.winOffsetY = r.y - w.bounds.Y; r.winWidth = w.bounds.Width; r.winHeight = w.bounds.Height;
                changed = true;
                Log.Info($"Bổ sung offset cửa sổ cho vùng '{r.name}'");
            }
        }
        if (changed) settings.regions = regions;
    }

    public static void SetAppMode(Region r, RegionAppMode mode) => Mutate(r, x => x.appMode = mode);
    public static void Toggle(Region r) => Mutate(r, x => x.enabled = !x.enabled);
    public static void Remove(Region r)
    {
        var settings = AppSettings.shared;
        settings.regions = settings.regions.Where(x => x.id != r.id).ToList();
        RegionPreviewProvider.shared.Remove(r.id);
        if (r.kind == RegionKind.subtitle) Pipeline.shared.RestartIfRunning();
    }

    static void Mutate(Region r, Action<Region> f)
    {
        var settings = AppSettings.shared;
        var regions = settings.regions;
        var x = regions.FirstOrDefault(y => y.id == r.id);
        if (x == null) return;
        f(x);
        settings.regions = regions;
        if (r.kind == RegionKind.subtitle) Pipeline.shared.RestartIfRunning();
    }
}

/// Điều hướng dùng chung: tab đang mở, hộp tạo game mới, đổi profile.
public sealed class AppNav : INotifyPropertyChanged
{
    public static readonly AppNav shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    public enum Tab { source, log, speakers, glossary }
    Tab _tab = Tab.source;
    public Tab tab { get => _tab; set { _tab = value; PropertyChanged?.Invoke(this, new(nameof(tab))); } }
    public event Action? NewProfileRequested;
    public void ShowNewProfile() => NewProfileRequested?.Invoke();

    public void SwitchProfile(Profile p)
    {
        var settings = AppSettings.shared;
        if (p.id == settings.activeProfileID) return;
        Pipeline.shared.Stop();
        ShotViewer.Close();
        settings.activeProfileID = p.id;
        Pipeline.shared.router.ResetContext();
        settings.NotifyAll();
        Log.Info($"Đổi sang game '{p.name}' ({Labels.Of(p.source)})");
    }

    public void CreateProfile(string name, ProfileSource source)
    {
        var settings = AppSettings.shared;
        var n = name.Trim();
        var p = new Profile { name = n.Length == 0 ? $"Game {settings.profiles.Count + 1}" : n, source = source };
        var ps = settings.profiles; ps.Add(p); settings.profiles = ps;
        SwitchProfile(p);
        tab = Tab.source;
    }

    /// Đổi nguồn hình của game đang chọn.
    public void SetSource(ProfileSource s)
    {
        var settings = AppSettings.shared;
        if (settings.source == s) return;
        Pipeline.shared.Stop();
        ShotViewer.Close();
        settings.source = s;
    }
}

/// Ảnh chụp vùng "màn hình game" của app ngoài, hiện trong tab Màn hình để nhìn và đặt khung phụ đề.
/// KHÔNG chụp liên tục (tốn CPU): chỉ chụp một tấm khi mở tab, khi đổi vùng, hoặc khi người dùng bấm "Chụp màn hình game".
public sealed class ExternalMirror : INotifyPropertyChanged
{
    public static readonly ExternalMirror shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise() => App.RunOnUI(() => PropertyChanged?.Invoke(this, new(null)));

    public BitmapSource? image { get; private set; }
    public (int w, int h) imageSize { get; private set; }
    public bool capturing { get; private set; }
    public string? error { get; private set; }
    public DateTime? capturedAt { get; private set; }
    string? areaKey;

    static string Key(Region a) => $"{a.id}|{a.x}|{a.y}|{a.width}|{a.height}|{a.appBundleID}";

    /// Chụp nếu chưa có ảnh của vùng này (mở tab lần đầu, đổi game, vẽ lại vùng).
    public void Ensure(Region? area)
    {
        if (area == null) { image = null; areaKey = null; error = null; Raise(); return; }
        if (Key(area) != areaKey || image == null) Capture(area);
    }

    /// Chụp lại ngay một tấm.
    public void Capture(Region area)
    {
        if (capturing) return;
        areaKey = Key(area);
        capturing = true;
        Raise();
        _ = Task.Run(() =>
        {
            try
            {
                var f = ScreenCapture.Capture(area, 1).Downscale(1800);
                var bs = f.ToBitmapSource();
                image = bs; imageSize = (f.Width, f.Height);
                capturedAt = DateTime.Now;
                error = null;
            }
            catch (Exception e)
            {
                error = e.Message;
                Log.Warn($"Chụp màn hình game lỗi: {e.Message}");
            }
            capturing = false;
            Raise();
        });
    }
}

/// Điều phối giữa phiên PS5 nhúng và pipeline dịch: vùng mặc định, tự bắt đầu/dừng dịch.
public static class PS5Coordinator
{
    /// Tạo vùng PS5 mặc định (phụ đề ở dải dưới + toàn màn hình) trong game đang chọn nếu chưa có.
    public static void PrepareProfile()
    {
        var settings = AppSettings.shared;
        var regions = settings.regions;
        bool changed = false;
        if (!regions.Any(r => r.embedded && r.kind == RegionKind.subtitle))
        {
            regions.Add(new Region { name = "Phụ đề PS5", x = 0.10, y = 0.72, width = 0.80, height = 0.24, embedded = true });
            changed = true;
        }
        if (!regions.Any(r => r.embedded && r.kind == RegionKind.manual))
        {
            regions.Add(new Region { name = "Màn hình PS5", x = 0, y = 0, width = 1, height = 1, kind = RegionKind.manual, embedded = true });
            changed = true;
        }
        if (changed) settings.regions = regions;
    }

    public static void Connect()
    {
        var settings = AppSettings.shared;
        PrepareProfile();
        PS5Stream.shared.Connect(settings.ps5Resolution, settings.ps5FPS);
    }

    public static void StateChanged(PS5Stream.State s)
    {
        var settings = AppSettings.shared;
        if (settings.source != ProfileSource.ps5) return;
        switch (s.kind)
        {
            case PS5Stream.StateKind.streaming:
                if (settings.ps5AutoTranslate && !Pipeline.shared.isRunning) _ = Pipeline.shared.Start();
                break;
            case PS5Stream.StateKind.idle:
            case PS5Stream.StateKind.failed:
                if (Pipeline.shared.isRunning) Pipeline.shared.Stop();
                break;
        }
    }

    public static void SetSubtitleRect(RectD r)
    {
        var settings = AppSettings.shared;
        var regions = settings.regions;
        var sub = regions.FirstOrDefault(x => x.embedded && x.kind == RegionKind.subtitle);
        if (sub != null) sub.rect = r;
        else regions.Add(new Region { name = "Phụ đề PS5", x = r.X, y = r.Y, width = r.Width, height = r.Height, embedded = true });
        settings.regions = regions;
        Log.Info($"PS5: vùng phụ đề = x {r.X:0.00} y {r.Y:0.00} w {r.Width:0.00} h {r.Height:0.00}");
        Pipeline.shared.RestartIfRunning();
    }
}
