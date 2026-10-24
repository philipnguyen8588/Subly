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

    /// Dùng cả một cửa sổ app làm màn hình game (chọn từ danh sách ở màn Bắt đầu). Vùng bám theo cửa sổ nên
    /// cửa sổ bị che hay dời chỗ vẫn chụp được. Khung phụ đề giữ tỉ lệ cũ nếu đã có, không thì đặt ở dải dưới.
    public static void UseWindow(WindowFinder.WindowInfo w)
    {
        var settings = AppSettings.shared;
        var keep = ExternalSubtitleNormalized();
        var area = new Region
        {
            name = "Màn hình game", x = w.bounds.X, y = w.bounds.Y, width = w.bounds.Width, height = w.bounds.Height, kind = RegionKind.manual,
            appBundleID = w.app.bundleID, appName = w.app.name, windowID = w.hwnd.ToInt64(),
            winOffsetX = 0, winOffsetY = 0, winWidth = w.bounds.Width, winHeight = w.bounds.Height,
        };
        var regions = settings.regions.Where(x => x.embedded).ToList();      // giữ vùng PS5 (nếu có), bỏ các khung app ngoài cũ
        regions.Add(area);
        settings.regions = regions;
        Log.Info($"Vùng game = cửa sổ {w.app.name}{(w.title.Length > 0 ? $" “{w.title}”" : "")} {(int)w.bounds.Width}×{(int)w.bounds.Height}");
        SetExternalSubtitle(keep ?? new RectD(0.10, 0.74, 0.80, 0.22));
    }

    /// Khung phụ đề app ngoài theo tỉ lệ bên trong khung màn hình game (null nếu chưa có).
    public static RectD? ExternalSubtitleNormalized()
    {
        var s = AppSettings.shared;
        if (s.externalArea is not Region area || s.externalSubtitle is not Region sub) return null;
        var a = WindowFinder.CurrentRect(area); var r = WindowFinder.CurrentRect(sub);
        if (a.Width <= 1 || a.Height <= 1) return null;
        double x = Math.Clamp((r.X - a.X) / a.Width, 0, 1), y = Math.Clamp((r.Y - a.Y) / a.Height, 0, 1);
        double w = Math.Min(r.Width / a.Width, 1 - x), h = Math.Min(r.Height / a.Height, 1 - y);
        return w > 0.03 && h > 0.02 ? new RectD(x, y, w, h) : null;
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

/// Điều hướng dùng chung: màn hình đang hiện (Bắt đầu / chơi), tab, hộp tạo game mới, quản lý game, vào và rời phiên chơi.
public sealed class AppNav : INotifyPropertyChanged
{
    public static readonly AppNav shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => App.RunOnUI(() => PropertyChanged?.Invoke(this, new(n)));
    public enum Tab { source, story, subtitles, screens, search, game, skipped }
    /// Hai màn hình của cửa sổ chính: Bắt đầu (chọn game + nguồn hình) và màn hình chơi.
    public enum Screen { start, main }
    Tab _tab = Tab.source;
    public Tab tab { get => _tab; set { _tab = value; Raise(nameof(tab)); } }
    Screen _screen = Screen.start;
    public Screen screen { get => _screen; set { if (_screen == value) return; _screen = value; Raise(nameof(screen)); } }
    string? _notice;
    /// Thông báo ở đầu màn Bắt đầu (ví dụ lý do vừa bị đưa về: mất kết nối PS5).
    public string? notice { get => _notice; set { _notice = value; Raise(nameof(notice)); } }
    bool _entering;
    /// Đang kết nối PS5 từ màn Bắt đầu; có hình thì vào màn hình chính.
    public bool entering { get => _entering; private set { _entering = value; Raise(nameof(entering)); } }
    bool _browsing;
    /// Màn hình chính mở ở chế độ chỉ xem (nút "Xem" ở danh sách game): đọc cốt truyện, phụ đề, ảnh đã dịch
    /// mà không cần kết nối PS5 / chọn cửa sổ. Không có nút dịch, chỉ có nút quay lại để kết nối.
    public bool browsing { get => _browsing; private set { _browsing = value; Raise(nameof(browsing)); } }
    public event Action? NewProfileRequested;
    public void ShowNewProfile() { if (screen == Screen.start) NewProfileRequested?.Invoke(); }

    // MARK: vào / rời phiên

    /// Nút "Bắt đầu" / "Kết nối & bắt đầu" ở màn Bắt đầu.
    public void Enter()
    {
        var settings = AppSettings.shared;
        if (screen != Screen.start || entering) return;
        notice = null;
        if (settings.source == ProfileSource.external)
        {
            if (settings.externalArea == null || settings.externalSubtitle == null)
            {
                Pipeline.shared.ShowAlert("Chưa chọn cửa sổ game", "Chọn cửa sổ đang chạy game ở cột Nguồn hình (hoặc vẽ vùng thủ công) rồi bấm Bắt đầu.");
                return;
            }
            if (!Readiness.Ensure()) return;
            browsing = false;
            screen = Screen.main;
            tab = Tab.source;
            _ = Pipeline.shared.Start();
        }
        else
        {
            if (PS5Stream.shared.host == null)
            {
                Pipeline.shared.ShowAlert("Chưa thiết lập PS5", "Bấm “Thiết lập PS5” ở cột Nguồn hình để nhập máy từ chiaki-ng hoặc đăng ký bằng mã PIN.");
                return;
            }
            if (!Readiness.Ensure()) return;
            entering = true;
            PS5Reconnector.shared.Cancel();
            if (PS5Stream.shared.isStreaming) EnteredPS5(); else PS5Coordinator.Connect();
        }
    }

    /// PS5 đã có hình sau khi bấm "Kết nối & bắt đầu".
    public void EnteredPS5()
    {
        if (!entering) return;
        entering = false;
        browsing = false;
        screen = Screen.main;
        tab = Tab.source;
        _ = Pipeline.shared.Start();
    }

    /// Nút "Xem" ở danh sách game: vào màn hình chính của game đó mà không kết nối nguồn hình.
    public void Browse(Profile p)
    {
        if (screen != Screen.start) return;
        if (entering) CancelEnter();
        if (PS5Stream.shared.state.kind != PS5Stream.StateKind.idle) PS5Stream.shared.Disconnect();
        SwitchProfile(p);
        notice = null;
        browsing = true;
        if (tab is Tab.source or Tab.game) tab = Tab.story;
        screen = Screen.main;
        Log.Info($"Xem game '{p.name}' (chưa kết nối)");
    }

    /// Kết nối PS5 từ màn Bắt đầu thất bại: ở lại màn Bắt đầu và hiện lý do.
    public void EnterFailed(string reason)
    {
        if (!entering) return;
        entering = false;
        notice = reason;
    }

    public void CancelEnter()
    {
        if (!entering) return;
        entering = false;
        PS5Stream.shared.Disconnect();
    }

    /// Rời màn hình chính: dừng dịch, ngắt PS5, đóng mọi thứ đang mở rồi về màn Bắt đầu.
    public void LeaveToStart(string? reason = null)
    {
        PS5Reconnector.shared.Cancel();
        Pipeline.shared.Stop();
        if (PS5Stream.shared.state.kind != PS5Stream.StateKind.idle) PS5Stream.shared.Disconnect();
        ShotViewer.Close();
        entering = false;
        browsing = false;
        screen = Screen.start;
        notice = reason;
        if (reason != null) Log.Info($"Về màn hình Bắt đầu: {reason}");
    }

    /// Nút "Đổi game" ở màn hình chính (hỏi lại nếu đang dịch).
    public void ChangeGame()
    {
        if (browsing) { LeaveToStart(); return; }
        if ((Pipeline.shared.isRunning || PS5Stream.shared.state.isBusy) && !AppSettings.shared.suppressAlerts)
        {
            var msg = AppSettings.shared.source == ProfileSource.ps5
                ? "App sẽ dừng dịch và ngắt kết nối PS5, rồi quay về màn hình chọn game."
                : "App sẽ dừng dịch rồi quay về màn hình chọn game.";
            if (System.Windows.MessageBox.Show(msg, "Đổi game?", System.Windows.MessageBoxButton.OKCancel, System.Windows.MessageBoxImage.Question)
                != System.Windows.MessageBoxResult.OK) return;
        }
        LeaveToStart();
    }

    /// Phím tắt Bắt đầu-Dừng: ở màn Bắt đầu thì đi qua bước kiểm tra và kết nối như bấm nút Bắt đầu.
    public void ToggleTranslation()
    {
        if (screen == Screen.start) { App.ShowMain(); Enter(); return; }
        if (browsing) { App.ShowMain(); LeaveToStart(); Enter(); return; }
        Pipeline.shared.Toggle();
    }

    // MARK: game (profile)

    public void SwitchProfile(Profile p)
    {
        var settings = AppSettings.shared;
        if (p.id == settings.activeProfileID) return;
        Pipeline.shared.Stop();
        ShotViewer.Close();
        settings.activeProfileID = p.id;
        Pipeline.shared.router.ResetContext();
        settings.NotifyAll();
        notice = null;
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

    /// Thêm các game mẫu đã chọn (kèm thuật ngữ, phong cách dịch, ghi chú AI…) rồi chuyển sang game đầu tiên.
    public void AddSampleGames(IList<GameCatalog.Game> games, ProfileSource source)
    {
        if (games.Count == 0) return;
        var settings = AppSettings.shared;
        var ps = settings.profiles;
        var created = games.Select(g => g.MakeProfile(source)).ToList();
        foreach (var p in created) ps.Add(p);
        settings.profiles = ps;
        Log.Info($"Thêm {created.Count} game mẫu: {string.Join(", ", created.Select(p => p.name))}");
        SwitchProfile(created[0]);
        tab = Tab.source;
    }

    public void RenameProfile(Profile p, System.Windows.Window? owner = null)
    {
        var settings = AppSettings.shared;
        if (Ui.Ask("Tên game", "Ví dụ: God of War Ragnarök", p.name, owner) is not string n) return;
        var ps = settings.profiles;
        if (ps.FirstOrDefault(x => x.id == p.id) is Profile x) { x.name = n; settings.profiles = ps; settings.NotifyAll(); }
    }

    public void DuplicateProfile(Profile p)
    {
        var settings = AppSettings.shared;
        var c = p.Clone();
        c.id = Guid.NewGuid(); c.name += " (bản sao)";
        foreach (var r in c.regions) r.id = Guid.NewGuid();
        var ps = settings.profiles; ps.Add(c); settings.profiles = ps;
        SwitchProfile(c);
    }

    public void DeleteProfile(Profile p) => DeleteProfiles(new[] { p.id });

    /// Xoá nhiều game một lần (hỏi xác nhận). Luôn giữ lại ít nhất một game. Trả về true nếu đã xoá.
    public bool DeleteProfiles(ICollection<Guid> ids)
    {
        var settings = AppSettings.shared;
        var doomed = settings.profiles.Where(p => ids.Contains(p.id)).ToList();
        if (doomed.Count == 0 || doomed.Count >= settings.profiles.Count) return false;
        if (!settings.suppressAlerts)
        {
            string msg;
            if (doomed.Count == 1)
                msg = $"Xoá game “{doomed[0].name}”?\nKhung phụ đề, thuật ngữ và tên nhân vật riêng của game này sẽ bị xoá. Nhật ký đã dịch vẫn giữ.";
            else
            {
                var shown = string.Join("\n", doomed.Take(8).Select(p => $"• {p.name}"));
                var more = doomed.Count > 8 ? $"\n…và {doomed.Count - 8} game khác" : "";
                msg = $"Xoá {doomed.Count} game?\n{shown}{more}\n\nKhung phụ đề, thuật ngữ và tên nhân vật riêng của các game này sẽ bị xoá. Nhật ký đã dịch vẫn giữ.";
            }
            if (!Ui.Confirm(msg, "Xoá game")) return false;
        }
        if (settings.activeProfileID is Guid active && ids.Contains(active)
            && settings.profiles.FirstOrDefault(p => !ids.Contains(p.id)) is Profile other) SwitchProfile(other);
        settings.profiles = settings.profiles.Where(p => !ids.Contains(p.id)).ToList();
        settings.NotifyAll();
        Log.Info($"Xoá {doomed.Count} game: {string.Join(", ", doomed.Select(p => p.name))}");
        return true;
    }

    /// Đổi nguồn hình của game đang chọn.
    public void SetSource(ProfileSource s)
    {
        var settings = AppSettings.shared;
        if (settings.source == s) return;
        if (entering) CancelEnter();
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

    static bool installed;
    static PS5Stream.StateKind lastKind = PS5Stream.StateKind.idle;

    /// Theo dõi trạng thái PS5 suốt đời app (một lần, không phụ thuộc view nào đang hiện).
    public static void Install()
    {
        if (installed) return;
        installed = true;
        var stream = PS5Stream.shared;
        stream.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(PS5Stream.state)) return;
            App.RunOnUI(() =>
            {
                var kind = stream.state.kind;
                if (kind == lastKind) return;
                var prev = lastKind;
                lastKind = kind;
                StateChanged(stream.state, prev);
            });
        };
    }

    /// Nối trạng thái phiên PS5 với màn hình: vào màn chính khi có hình, tự kết nối lại / về màn Bắt đầu khi rớt.
    public static void StateChanged(PS5Stream.State s, PS5Stream.StateKind prev)
    {
        var settings = AppSettings.shared;
        var nav = AppNav.shared;
        var reconnector = PS5Reconnector.shared;
        if (settings.source != ProfileSource.ps5) return;
        switch (s.kind)
        {
            case PS5Stream.StateKind.streaming:
                if (nav.entering) nav.EnteredPS5();
                else if (reconnector.active) reconnector.StreamingResumed();
                break;
            case PS5Stream.StateKind.failed:
            {
                bool wasTranslating = Pipeline.shared.isRunning;
                if (wasTranslating) Pipeline.shared.Stop();
                if (nav.entering) nav.EnterFailed(s.label);
                else if (nav.screen == AppNav.Screen.main && !nav.browsing) reconnector.ConnectionLost(s.label, wasTranslating);
                break;
            }
            case PS5Stream.StateKind.idle:
                if (Pipeline.shared.isRunning) Pipeline.shared.Stop();
                // Phiên kết thúc "bình thường" mà người dùng không bấm Đổi game (ví dụ tắt Remote Play trên PS5).
                if (nav.screen == AppNav.Screen.main && !nav.browsing && !reconnector.active && prev == PS5Stream.StateKind.streaming)
                    reconnector.ConnectionLost("PS5 đã đóng phiên Remote Play", true);
                break;
        }
    }

    /// Dời / đổi cỡ một khung đã có (khung phụ đề chính hoặc khu vực dịch thêm) theo id.
    public static void UpdateSubtitleRect(Guid id, RectD r)
    {
        var settings = AppSettings.shared;
        var regions = settings.regions;
        var x = regions.FirstOrDefault(q => q.id == id);
        if (x == null) return;
        x.rect = r;
        settings.regions = regions;
        Log.Info($"PS5: khung '{x.name}' = x {r.X:0.00} y {r.Y:0.00} w {r.Width:0.00} h {r.Height:0.00}");
        Pipeline.shared.RestartIfRunning();
    }

    /// Thêm một khu vực dịch mới trên hình PS5: chỉ dịch chữ trong khung, không lấy tên, không đọc thành tiếng,
    /// bản dịch hiện ngay tại khung. Nếu chưa có khung phụ đề chính nào thì khung đầu tiên làm khung chính.
    public static Guid AddSubtitleRegion(RectD r)
    {
        var settings = AppSettings.shared;
        var regions = settings.regions;
        bool hasPrimary = regions.Any(q => q.embedded && q.kind == RegionKind.subtitle && !q.extra);
        int count = regions.Count(q => q.embedded && q.kind == RegionKind.subtitle);
        var n = new Region { name = hasPrimary ? $"Khu vực {count + 1}" : "Phụ đề PS5", x = r.X, y = r.Y, width = r.Width, height = r.Height, embedded = true, extra = hasPrimary };
        regions.Add(n);
        settings.regions = regions;
        Log.Info($"PS5: thêm {(n.extra ? "khu vực dịch" : "khung phụ đề chính")} '{n.name}' = x {r.X:0.00} y {r.Y:0.00} w {r.Width:0.00} h {r.Height:0.00}");
        Pipeline.shared.RestartIfRunning();
        return n.id;
    }

    /// Xoá một khu vực dịch thêm (không cho xoá khung phụ đề chính).
    public static void RemoveSubtitleRegion(Guid id)
    {
        var settings = AppSettings.shared;
        var r = settings.regions.FirstOrDefault(q => q.id == id);
        if (r == null || !r.extra) return;
        settings.regions = settings.regions.Where(q => q.id != id).ToList();
        Pipeline.shared.ClearRegionCaption(id);
        Log.Info($"PS5: xoá khu vực dịch '{r.name}'");
        Pipeline.shared.RestartIfRunning();
    }
}
