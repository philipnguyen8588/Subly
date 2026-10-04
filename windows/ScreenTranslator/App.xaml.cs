using System;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace ScreenTranslator;

public partial class App : Application
{
    static MainWindow? main;
    static SettingsWindow? settingsWindow;
    static System.Windows.Forms.NotifyIcon? tray;
    static bool hiddenNoticeShown;
    static string[] args = Array.Empty<string>();

    // MARK: tiện ích luồng UI (thay @MainActor)

    public static void RunOnUI(Action a)
    {
        var d = Current?.Dispatcher;
        if (d == null) { a(); return; }
        if (d.CheckAccess()) a(); else d.BeginInvoke(a);
    }

    public static Task InvokeOnUI(Action a)
    {
        var d = Current?.Dispatcher;
        if (d == null || d.CheckAccess()) { a(); return Task.CompletedTask; }
        return d.InvokeAsync(a).Task;
    }

    public static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { Log.Error($"Không mở được {url}: {e.Message}"); }
    }

    // MARK: cửa sổ

    public static void ShowMain()
    {
        main ??= new MainWindow();
        if (!main.IsVisible) main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
    }

    /// Thu nhỏ cửa sổ chính khi vẽ vùng trên màn hình để thấy game bên dưới.
    public static void HideMainForPicking()
    {
        if (main != null && main.IsVisible) main.WindowState = WindowState.Minimized;
        if (settingsWindow != null && settingsWindow.IsVisible) settingsWindow.WindowState = WindowState.Minimized;
    }

    public static void ShowSettings() => ShowSettings(null);

    public static void ShowSettings(string? tab)
    {
        if (settingsWindow == null)
        {
            settingsWindow = new SettingsWindow();
            settingsWindow.Closed += (_, _) => settingsWindow = null;
        }
        if (tab != null) settingsWindow.Select(tab);
        if (!settingsWindow.IsVisible) settingsWindow.Show();
        if (settingsWindow.WindowState == WindowState.Minimized) settingsWindow.WindowState = WindowState.Normal;
        settingsWindow.Activate();
    }

    public static void NotifyHidden()
    {
        if (hiddenNoticeShown || tray == null) return;
        hiddenNoticeShown = true;
        tray.ShowBalloonTip(3000, "ScreenTranslator vẫn chạy nền", "Bấm biểu tượng ở khay hệ thống để mở lại. Chọn Thoát trong menu để tắt hẳn.", System.Windows.Forms.ToolTipIcon.Info);
    }

    public static void Quit()
    {
        Log.Info("Thoát app");
        Pipeline.shared.Stop();
        AppSettings.shared.SaveNow();
        if (tray != null) { tray.Visible = false; tray.Dispose(); tray = null; }
        if (main != null) { main.reallyClose = true; main.Close(); }
        Log.Flush();
        Current.Shutdown();
    }

    // MARK: khởi động

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        args = e.Args;
        DispatcherUnhandledException += (_, ex) =>
        {
            Log.Error($"Lỗi không xử lý: {ex.Exception}");
            ex.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) => Log.Error($"Lỗi nghiêm trọng: {ex.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, ex) => { Log.Warn($"Task lỗi: {ex.Exception?.InnerException?.Message}"); ex.SetObserved(); };

        var s = AppSettings.shared;
        Log.Info($"ScreenTranslator (Windows) launched. Profile '{s.activeProfile.name}', regions: {s.regions.Count}");
        SetupTray();
        HandleCommandLine();
        WebServer.shared.Apply();
        AppSettings.shared.Changed += k => { if (k is "webServerEnabled" or "webServerPort") RunOnUI(WebServer.shared.Apply); };
        RegionActions.FillMissingWindowOffsets();
        RegisterHotkeys();
        if (!Has("--hidden")) ShowMain();
        if (Has("--open-settings")) ShowSettings();
    }

    static bool Has(string flag) => args.Contains(flag);
    static string? Arg(string flag)
    {
        int i = Array.IndexOf(args, flag);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    void SetupTray()
    {
        try
        {
            var iconStream = GetResourceStream(new Uri("pack://application:,,,/Resources/AppIcon.ico"))?.Stream;
            tray = new System.Windows.Forms.NotifyIcon
            {
                Icon = iconStream != null ? new System.Drawing.Icon(iconStream) : System.Drawing.SystemIcons.Application,
                Text = "ScreenTranslator", Visible = true,
            };
            var menu = new System.Windows.Forms.ContextMenuStrip();
            menu.Items.Add("Mở cửa sổ chính", null, (_, _) => RunOnUI(ShowMain));
            menu.Items.Add("Bắt đầu / Dừng dịch", null, (_, _) => RunOnUI(Pipeline.shared.Toggle));
            menu.Items.Add("Dịch màn hình", null, (_, _) => RunOnUI(Pipeline.shared.AnalyzeScreen));
            menu.Items.Add("Tắt màn hình", null, (_, _) => RunOnUI(() => DisplayPower.shared.SleepDisplay()));
            menu.Items.Add("Cài đặt…", null, (_, _) => RunOnUI(ShowSettings));
            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add("Thoát", null, (_, _) => RunOnUI(Quit));
            tray.ContextMenuStrip = menu;
            tray.MouseClick += (_, ev) => { if (ev.Button == System.Windows.Forms.MouseButtons.Left) RunOnUI(ShowMain); };
        }
        catch (Exception ex) { Log.Warn($"Không tạo được biểu tượng khay: {ex.Message}"); }
    }

    // MARK: phím tắt

    static void RegisterHotkeys()
    {
        var s = AppSettings.shared;
        var hm = HotkeyManager.shared;
        hm.Pressed += a =>
        {
            var p = Pipeline.shared;
            switch (a)
            {
                case HotkeyManager.HotkeyAction.toggle: p.Toggle(); break;
                case HotkeyManager.HotkeyAction.analyze: p.AnalyzeScreen(); break;
                case HotkeyManager.HotkeyAction.voice:
                    s.voiceEnabled = !s.voiceEnabled;
                    if (!s.voiceEnabled) p.speaker.Stop();
                    p.overlay.Hud(s.voiceEnabled ? "Voice: bật" : "Voice: tắt", 1.5);
                    break;
                case HotkeyManager.HotkeyAction.overlay:
                    s.overlayEnabled = !s.overlayEnabled;
                    if (s.overlayEnabled) p.overlay.Hud("Overlay: bật", 1.5); else p.overlay.Hide();
                    break;
            }
        };
        var failed = hm.Apply();
        if (failed.Count > 0 && !s.suppressAlerts)
            p_overlayLater($"Không đăng ký được phím tắt: {string.Join(", ", failed)} (đã bị app khác dùng). Đổi trong Cài đặt → Phím tắt.");
    }

    static void p_overlayLater(string msg)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        t.Tick += (_, _) => { t.Stop(); Pipeline.shared.overlay.Hud(msg, 5); };
        t.Start();
    }

    // MARK: dòng lệnh (test / automation)
    //   --add-region x,y,w,h[,Tên[,manual]]   toạ độ pixel toàn cục (gốc trên-trái màn hình chính)
    //   --test-region x,y,w,h[,Tên]          vùng tạm, không lưu
    //   --clear-regions  --autostart  --mute  --quiet  --hidden  --analyze-once  --no-web  --web-port N  --no-overlay
    //   --gemini-base-url <url>  --gemini-key <key>  --profile <tên>  --delete-profile <tên>
    //   --translate "a|b"  --translate-engine auto|google  --speak "a|b"  --voice-engine windows|local|edge
    //   --feed "a|b"  --download-voice <id>  --ps5-import  --ps5-connect  --ps5-discover  --show-shot  --tab source|log|speakers
    //   --quit-after <giây>  (tự thoát, dùng khi kiểm thử tự động)
    void HandleCommandLine()
    {
        var settings = AppSettings.shared;
        if (Has("--mute")) { settings.forceMute = true; Log.Info("Muted by --mute"); }
        if (Has("--quiet")) settings.suppressAlerts = true;
        if (Arg("--tab") is string tab)
        {
            var map = new System.Collections.Generic.Dictionary<string, AppNav.Tab>
            {
                ["source"] = AppNav.Tab.source, ["ps5"] = AppNav.Tab.source, ["regions"] = AppNav.Tab.source,
                ["log"] = AppNav.Tab.log, ["live"] = AppNav.Tab.log, ["analysis"] = AppNav.Tab.log, ["speakers"] = AppNav.Tab.speakers,
            };
            if (map.TryGetValue(tab, out var t)) AppNav.shared.tab = t;
        }
        if (Has("--no-overlay")) settings.forceNoOverlay = true;
        if (Has("--no-web")) settings.forceNoWeb = true;
        if (Arg("--web-port") is string wp && int.TryParse(wp, out var port)) settings.forceWebPort = port;
        if (Arg("--voice-engine") is string ve)
        {
            if (ve == "apple") ve = "windows";
            if (Enum.TryParse<VoiceEngine>(ve, out var eng)) settings.forceEngine = eng;
        }
        if (Arg("--translate-engine") is string te)
        {
            if (te is "appleTranslation" or "appleIntelligence") te = "google";
            if (Enum.TryParse<TranslationEngine>(te, out var eng)) settings.forceTranslationEngine = eng;
        }
        // --profile "Tên": chuyển sang game đó (tạo mới với nguồn app ngoài nếu chưa có). --delete-profile "Tên": xoá.
        if (Arg("--delete-profile") is string del && settings.profiles.Count > 1)
        {
            settings.profiles = settings.profiles.Where(p => p.name != del).ToList();
            if (!settings.profiles.Any(p => p.id == settings.activeProfileID)) settings.activeProfileID = settings.profiles.FirstOrDefault()?.id;
        }
        if (Arg("--profile") is string pn)
        {
            if (settings.profiles.FirstOrDefault(p => p.name == pn) is Profile p) settings.activeProfileID = p.id;
            else { var np = new Profile { name = pn }; var ps = settings.profiles; ps.Add(np); settings.profiles = ps; settings.activeProfileID = np.id; }
        }
        if (Has("--clear-regions")) settings.regions = new();
        if (Arg("--gemini-base-url") is string gb) settings.geminiBaseURL = gb;
        if (Arg("--gemini-key") is string gk) settings.geminiAPIKey = gk;
        for (int i = 0; i < args.Length; i++)
        {
            if ((args[i] == "--test-region" || args[i] == "--add-region") && i + 1 < args.Length)
            {
                var parts = args[i + 1].Split(',');
                if (parts.Length >= 4 && double.TryParse(parts[0], out var x) && double.TryParse(parts[1], out var y)
                    && double.TryParse(parts[2], out var w) && double.TryParse(parts[3], out var h))
                {
                    var test = args[i] == "--test-region";
                    var kind = parts.Length > 5 && parts[5] == "manual" ? RegionKind.manual : RegionKind.subtitle;
                    var name = parts.Length > 4 ? parts[4] : (test ? "Test" : $"Vùng {settings.regions.Count + 1}");
                    var r = new Region { name = name, x = x, y = y, width = w, height = h, kind = kind };
                    RegionActions.AttachWindow(r);
                    if (test) settings.ephemeralRegions.Add(r);
                    else { var rs = settings.regions; rs.Add(r); settings.regions = rs; }
                    Log.Info($"{(test ? "Test" : "Added")} {kind} region '{name}' {x},{y} {w}x{h} app={r.appName ?? "-"}");
                }
                i++;
            }
        }
        // --translate "câu 1|câu 2": dịch thử qua router (không OCR, không voice), ghi kết quả vào log.
        if (Arg("--translate") is string tr)
        {
            var lines = tr.Split('|');
            _ = Task.Run(async () =>
            {
                await Task.Delay(1500);
                var router = Pipeline.shared.router;
                foreach (var l in lines)
                {
                    var o = await router.Translate(l);
                    if (o != null) Log.Info($"TEST-TR[{o.backend}] {o.ms}ms: {l} → {o.text}");
                    else Log.Warn($"TEST-TR thất bại: {l} ({router.state.label})");
                }
                Log.Info($"TEST-TR xong, trạng thái: {router.state.label}");
            });
        }
        if (Arg("--download-voice") is string dv) VoiceCatalog.shared.Download(dv);
        // --speak "câu 1|câu 2": đọc thử bằng engine giọng hiện tại (kèm --mute để không phát tiếng).
        if (Arg("--speak") is string sp)
        {
            var lines = sp.Split('|');
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(1000);
                    while (VoiceCatalog.shared.downloading.Count > 0) await Task.Delay(500);
                    await InvokeOnUI(() =>
                    {
                        var p = Pipeline.shared;
                        p.ApplyVoiceSettings();
                        p.speaker.interrupt = false;
                        Log.Info($"TEST-SPEAK engine={p.speaker.engine} lang={p.speaker.language}");
                    });
                    foreach (var l in lines) { RunOnUI(() => Pipeline.shared.speaker.Speak(l)); await Task.Delay(1200); }
                }
                catch (Exception e) { Log.Error($"TEST-SPEAK lỗi: {e}"); }
            });
        }
        // --feed "khối 1|khối 2": đưa lần lượt từng khối vào hàng đợi dịch (cách nhau 0,3 s) để kiểm thứ tự + thời gian.
        if (Arg("--feed") is string feed)
        {
            var batches = feed.Split('|');
            _ = Task.Run(async () =>
            {
                await Task.Delay(2500);
                Log.Info("FEED bắt đầu");
                foreach (var b in batches) { RunOnUI(() => Pipeline.shared.TestFeed(b)); await Task.Delay(300); }
            });
        }
        if (Has("--ps5-import")) Log.Info($"PS5 import: {PS5Stream.shared.ImportFromChiaki()}");
        if (Has("--ps5-discover"))
            _ = Task.Run(() =>
            {
                var found = PS5Stream.Discover(PS5Stream.BroadcastAddresses());
                Log.Info($"PS5 discover: {(ChiakiNative.Available ? $"{found.Count} máy" : ChiakiNative.LoadError)} {string.Join("; ", found.Select(f => $"{f.name} {f.addr} ps5={f.ps5} state={f.stateLabel}"))}");
            });
        if (Has("--ps5-connect")) Delay(1.5, PS5Coordinator.Connect);
        // --show-shot: mở modal ảnh "dịch màn hình" mới nhất còn lưu (kiểm tra giao diện).
        if (Has("--show-shot") && HistoryStore.shared.analyses.FirstOrDefault(a => a.hasImage) is ScreenAnalysis a) Delay(0.5, () => ShotViewer.Show(a.id));
        // --snap <thư mục>: chụp từng vùng ra PNG và OCR thử (kiểm tra toạ độ / chụp cửa sổ).
        if (Arg("--snap") is string snapDir)
            _ = Task.Run(async () =>
            {
                await Task.Delay(800);
                System.IO.Directory.CreateDirectory(snapDir);
                foreach (var r in settings.regions)
                {
                    try
                    {
                        var f = ScreenCapture.Capture(r, 1);
                        var path = System.IO.Path.Combine(snapDir, $"{r.name}.png");
                        System.IO.File.WriteAllBytes(path, f.ToPng());
                        var o = await new WinOcr().RecognizeLines(f);
                        Log.Info($"SNAP[{r.name}] {f.Width}×{f.Height} follows={r.followsWindow} window={(r.followsWindow ? WindowFinder.Bounds(WindowFinder.FindWindow(r))?.ToString() : "-")} → {path} OCR({o?.ms:0}ms): {o?.text ?? WinOcr.LastError}");
                    }
                    catch (Exception e) { Log.Error($"SNAP[{r.name}] lỗi: {e.Message}"); }
                }
            });
        // --render-ui <thư mục>: vẽ từng tab của cửa sổ chính và từng trang Cài đặt ra PNG (kiểm tra giao diện).
        if (Arg("--render-ui") is string uiDir) Delay(2, () => RenderUi(uiDir));
        if (Has("--autostart")) Delay(0.5, () => _ = Pipeline.shared.Start());
        if (Has("--analyze-once")) Delay(2, Pipeline.shared.AnalyzeScreen);
        if (Arg("--quit-after") is string qa && double.TryParse(qa, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var sec))
            Delay(sec, Quit);
    }

    static async void RenderUi(string dir)
    {
        System.IO.Directory.CreateDirectory(dir);
        static void Save(FrameworkElement el, string path)
        {
            el.UpdateLayout();
            var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(el);
            var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap((int)(el.ActualWidth * dpi.DpiScaleX), (int)(el.ActualHeight * dpi.DpiScaleY),
                96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, System.Windows.Media.PixelFormats.Pbgra32);
            rtb.Render(el);
            var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
            enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
            using var fs = System.IO.File.Create(path);
            enc.Save(fs);
            Log.Info($"RENDER {path}");
        }
        ShowMain();
        foreach (var t in new[] { AppNav.Tab.source, AppNav.Tab.log, AppNav.Tab.speakers })
        {
            AppNav.shared.tab = t;
            await Task.Delay(700);
            Save((FrameworkElement)main!.Content, System.IO.Path.Combine(dir, $"main-{t}.png"));
        }
        if (HistoryStore.shared.analyses.FirstOrDefault(a => a.hasImage) is ScreenAnalysis shot)
        {
            ShotViewer.Show(shot.id);
            await Task.Delay(700);
            Save((FrameworkElement)main!.Content, System.IO.Path.Combine(dir, "main-shot.png"));
            ShotViewer.Close();
        }
        ShowSettings();
        foreach (var k in new[] { "translate", "capture", "voice", "overlay", "glossary", "profile", "hotkeys", "web" })
        {
            settingsWindow!.Select(k);
            await Task.Delay(500);
            Save((FrameworkElement)settingsWindow.Content, System.IO.Path.Combine(dir, $"settings-{k}.png"));
        }
    }

    static void Delay(double seconds, Action a)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); a(); };
        t.Start();
    }
}
