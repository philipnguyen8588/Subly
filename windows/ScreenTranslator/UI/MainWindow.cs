using System;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Cửa sổ chính: màn hình Bắt đầu (StartView) hoặc màn hình chơi (header, thanh tab, nội dung, thanh trạng thái), modal ảnh dịch màn hình.
public sealed class MainWindow : Window
{
    readonly ContentControl screenHost = new();
    readonly StartView start = new();
    readonly DockPanel mainScreen = new() { LastChildFill = true };
    readonly ContentControl content = new();
    readonly StackPanel tabBar = new() { Orientation = Orientation.Horizontal };
    readonly ContentControl tabTrailing = new();
    readonly HeaderBar header = new();
    SourceTab? sourceTab; LogTab? logTab; GameSetupView? gameTab;
    public bool reallyClose;

    public MainWindow()
    {
        Title = "Subly";
        Width = 1000; Height = 700; MinWidth = 920; MinHeight = 560;
        Background = Ui.Res("WindowBg");
        Icon = new BitmapImage(new Uri("pack://application:,,,/Resources/AppIcon.ico"));
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        if (AppSettings.shared.mainWindowFrame is double[] f && f.Length == 4 && f[2] >= MinWidth && f[3] >= MinHeight
            && SystemParameters.VirtualScreenWidth > 0 && f[0] > SystemParameters.VirtualScreenLeft - 50 && f[1] > SystemParameters.VirtualScreenTop - 50
            && f[0] < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100)
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = f[0]; Top = f[1]; Width = f[2]; Height = f[3];
        }

        // Màn hình chơi.
        DockPanel.SetDock(header, Dock.Top);
        mainScreen.Children.Add(header);
        var tabRow = new DockPanel { Margin = new Thickness(14, 0, 14, 8), LastChildFill = true };
        DockPanel.SetDock(tabTrailing, Dock.Right);
        tabRow.Children.Add(tabTrailing);
        tabRow.Children.Add(tabBar);
        DockPanel.SetDock(tabRow, Dock.Top);
        mainScreen.Children.Add(tabRow);
        var div = new Border { Height = 1, Background = Ui.Res("CardStroke") };
        DockPanel.SetDock(div, Dock.Top);
        mainScreen.Children.Add(div);
        var status = new StatusBar();
        DockPanel.SetDock(status, Dock.Bottom);
        mainScreen.Children.Add(status);
        var body = new Grid();
        body.Children.Add(content);
        body.Children.Add(new ReconnectOverlay());
        mainScreen.Children.Add(body);

        var root = new Grid();
        root.Children.Add(screenHost);
        root.Children.Add(new ShotModal());
        Content = root;

        AppNav.shared.PropertyChanged += (_, e) => Dispatcher.BeginInvoke(() =>
        {
            if (e.PropertyName == nameof(AppNav.screen)) ShowScreen();
            else if (e.PropertyName == nameof(AppNav.tab)) ShowTab();
        });
        AppNav.shared.NewProfileRequested += () => Dispatcher.BeginInvoke(() => new NewProfileDialog { Owner = this }.ShowDialog());
        HistoryStore.shared.Changed += () => Dispatcher.BeginInvoke(BuildTabBar);
        ShowScreen();

        // Đóng cửa sổ thì app vẫn chạy nền (biểu tượng ở khay hệ thống); chọn Thoát ở menu khay để tắt hẳn.
        Closing += (_, e) =>
        {
            SaveFrame();
            if (reallyClose) return;
            e.Cancel = true;
            Hide();
            App.NotifyHidden();
        };
        PreviewKeyDown += (_, e) =>
        {
            if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.OemComma) { App.ShowSettings(); e.Handled = true; }
            else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.N) { AppNav.shared.ShowNewProfile(); e.Handled = true; }
        };
    }

    void SaveFrame()
    {
        if (WindowState == WindowState.Normal) AppSettings.shared.mainWindowFrame = new[] { Left, Top, Width, Height };
    }

    void ShowScreen()
    {
        screenHost.Content = AppNav.shared.screen == AppNav.Screen.start ? start : mainScreen;
        if (AppNav.shared.screen == AppNav.Screen.main) ShowTab();
    }

    static readonly (AppNav.Tab tab, string glyph, string title)[] tabs =
    {
        (AppNav.Tab.source, "", "Màn hình"), (AppNav.Tab.story, "", "Cốt truyện"), (AppNav.Tab.subtitles, "", "Phụ đề"),
        (AppNav.Tab.screens, "", "Dịch màn hình"), (AppNav.Tab.game, "", "Thiết lập game"),
    };

    void BuildTabBar()
    {
        tabBar.Children.Clear();
        var store = HistoryStore.shared;
        foreach (var (t, glyph, title) in tabs)
        {
            bool sel = AppNav.shared.tab == t;
            var label = Ui.H(6, Ui.Icon(glyph, 13, sel ? Brushes.White : null), Ui.Text(title, 13, sel, sel ? Brushes.White : null, wrap: false));
            int badge = t switch { AppNav.Tab.subtitles => store.entries.Count, AppNav.Tab.screens => store.analyses.Count, _ => 0 };
            if (badge > 0)
                label.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(5, 0, 5, 0), Margin = new Thickness(6, 0, 0, 0),
                    Background = sel ? new SolidColorBrush(Color.FromArgb(64, 255, 255, 255)) : Ui.Res("CardFill"),
                    Child = Ui.Text($"{badge}", 10.5, true, sel ? Brushes.White : null) });
            var b = new Border { Child = label, Height = 34, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 0, 4, 0),
                Background = sel ? Ui.AccentGradient : Brushes.Transparent, Cursor = Cursors.Hand };
            var tab = t;
            b.MouseLeftButtonUp += (_, _) => AppNav.shared.tab = tab;
            tabBar.Children.Add(b);
        }
    }

    void ShowTab()
    {
        BuildTabBar();
        var t = AppNav.shared.tab;
        if (t is AppNav.Tab.story or AppNav.Tab.subtitles or AppNav.Tab.screens)
        {
            logTab ??= new LogTab();
            logTab.ShowSection(t);
            tabTrailing.Content = Ui.Detach(logTab.Toolbar);
            content.Content = logTab;
        }
        else
        {
            tabTrailing.Content = null;
            content.Content = t == AppNav.Tab.game ? (gameTab ??= new GameSetupView()) : (sourceTab ??= new SourceTab());
        }
    }
}

/// Thanh trên cùng màn hình chơi: Đổi game + game đang chơi, hai nút chính (Bắt đầu dịch / Dịch màn hình),
/// các nút biểu tượng (voice, overlay, cốt truyện, tắt màn hình, hướng dẫn, cài đặt) cùng cỡ 36×36.
public sealed class HeaderBar : Border
{
    readonly Button startBtn, analyzeBtn;
    readonly ToggleButton voiceBtn, overlayBtn, storyBtn;
    readonly TextBlock gameName = Ui.Text("", 15, weight: FontWeights.Bold, wrap: false);
    readonly TextBlock gameStatus = Ui.Caption("");
    readonly System.Windows.Shapes.Ellipse statusDot = Ui.Dot(Brushes.Gray, 7);
    readonly TextBlock sourceIcon = Ui.Icon("", 18, Ui.AccentStart);

    public HeaderBar()
    {
        Padding = new Thickness(14, 0, 14, 0);
        Height = 60;
        var pipeline = Pipeline.shared; var s = AppSettings.shared;
        var back = Ui.Btn(Ui.IconLabel("", "Đổi game"), AppNav.shared.ChangeGame, tip: "Dừng dịch và quay về màn hình chọn game");
        startBtn = Ui.Btn("", pipeline.Toggle, primary: true, minWidth: 150);
        analyzeBtn = Ui.Btn("", pipeline.AnalyzeScreen, kind: Ui.Kind.tinted, minWidth: 150);
        analyzeBtn.MaxWidth = 230;
        voiceBtn = Ui.IconToggle("");
        overlayBtn = Ui.IconToggle("");
        storyBtn = Ui.IconToggle("", "Tự viết cốt truyện game từ phụ đề khi đang dịch (xem ở tab Cốt truyện)");
        voiceBtn.Click += (_, _) => s.voiceEnabled = voiceBtn.IsChecked == true;
        overlayBtn.Click += (_, _) => { s.overlayEnabled = overlayBtn.IsChecked == true; if (!s.overlayEnabled) pipeline.overlay.Hide(); };
        storyBtn.Click += (_, _) => s.storyEnabled = storyBtn.IsChecked == true;
        var moon = Ui.IconBtn("", () => DisplayPower.shared.SleepDisplay(), "Tắt màn hình để tiết kiệm điện (app vẫn dịch và đọc). Di chuột hoặc gõ phím để bật lại");
        var help = Ui.IconBtn("", OpenGuide, "Hướng dẫn sử dụng app");
        var gear = Ui.IconBtn("", App.ShowSettings, "Cài đặt: ngôn ngữ, AI, voice, overlay, thuật ngữ, phím tắt");
        var sep = new Border { Width = 1, Height = 22, Background = Ui.Res("CardStroke"), Margin = new Thickness(2, 0, 2, 0) };

        var game = Ui.H(10, sourceIcon, Ui.V(2, gameName, Ui.H(5, statusDot, gameStatus)));
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 120 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = Ui.H(12, back, game);
        var center = Ui.H(8, startBtn, analyzeBtn); center.Margin = new Thickness(12, 0, 12, 0);
        var right = Ui.H(6, voiceBtn, overlayBtn, storyBtn, sep, moon, help, gear);
        left.VerticalAlignment = center.VerticalAlignment = right.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumnSpan(left, 2); Grid.SetColumn(center, 2); Grid.SetColumn(right, 3);
        grid.Children.Add(left); grid.Children.Add(center); grid.Children.Add(right);
        Child = grid;

        pipeline.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Pipeline.isRunning)) Dispatcher.BeginInvoke(Refresh); };
        pipeline.analyzer.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        PS5Stream.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        PS5Reconnector.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        ExternalMirror.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        s.Changed += _ => Dispatcher.BeginInvoke(Refresh);
        Refresh();
    }

    void Refresh()
    {
        var pipeline = Pipeline.shared; var s = AppSettings.shared; var an = pipeline.analyzer;
        var reconnecting = PS5Reconnector.shared.active;
        startBtn.Content = Ui.IconLabel(pipeline.isRunning ? "" : "", pipeline.isRunning ? "Dừng dịch" : "Bắt đầu dịch");
        startBtn.Style = (Style)Application.Current.FindResource(pipeline.isRunning ? "AppButtonDanger" : "AppButtonPrimary");
        startBtn.ToolTip = $"Bắt đầu / dừng dịch phụ đề ({s.hotkeyToggle.display})";
        startBtn.IsEnabled = !reconnecting;
        analyzeBtn.Content = Ui.IconLabel("", an.isRunning ? (an.progress.Length == 0 ? "Đang dịch…" : an.progress) : "Dịch màn hình");
        analyzeBtn.IsEnabled = !an.isRunning && !reconnecting;
        analyzeBtn.ToolTip = $"Chụp màn hình game, dịch toàn bộ chữ và mở ảnh với bản dịch đặt đè đúng vị trí ({s.hotkeyAnalyze.display})";
        voiceBtn.IsChecked = s.voiceEnabled;
        voiceBtn.Content = Ui.Icon(s.voiceEnabled ? "" : "", 15);
        voiceBtn.ToolTip = $"Đọc bản dịch bằng giọng nói ({s.hotkeyVoice.display})";
        overlayBtn.IsChecked = s.overlayEnabled;
        overlayBtn.ToolTip = $"Hiện phụ đề dịch trên màn hình ({s.hotkeyOverlay.display})";
        storyBtn.IsChecked = s.storyEnabled;

        gameName.Text = s.activeProfile.name;
        sourceIcon.Text = s.source == ProfileSource.ps5 ? "" : "";
        Brush color; string text;
        if (s.source == ProfileSource.ps5)
        {
            var st = PS5Stream.shared;
            var name = st.host?.nickname ?? "PS5";
            if (reconnecting) { color = Ui.Orange; text = "Đang kết nối lại PS5…"; }
            else switch (st.state.kind)
            {
                case PS5Stream.StateKind.streaming: color = Brushes.LimeGreen; text = $"{name} · {st.videoSize.h}p · {st.fps} fps"; break;
                case PS5Stream.StateKind.failed: color = Ui.Danger; text = $"{name} · {st.state.label}"; break;
                case PS5Stream.StateKind.idle: color = Ui.Secondary; text = $"{name} · chưa kết nối"; break;
                default: color = Ui.Orange; text = $"{name} · {st.state.label}"; break;
            }
        }
        else if (s.externalArea is Region area)
        {
            color = ExternalMirror.shared.error == null ? Brushes.LimeGreen : Ui.Danger;
            text = area.appName ?? $"Vùng màn hình {(int)area.width}×{(int)area.height}";
        }
        else { color = Ui.Secondary; text = "Chưa chọn cửa sổ game"; }
        statusDot.Fill = color;
        gameStatus.Text = text;
    }

    /// Mở file hướng dẫn HTML đóng kèm app bằng trình duyệt mặc định.
    public static void OpenGuide()
    {
        var path = System.IO.Path.Combine(AppContext.BaseDirectory, "guide", "index.html");
        if (System.IO.File.Exists(path)) App.OpenUrl(path);
        else { Log.Warn($"Không thấy file hướng dẫn: {path}"); App.OpenUrl("https://t.me/subly_ps"); }
    }

    /// Thêm các game mẫu còn thiếu rồi báo kết quả.
    public static void AddSampleGames()
    {
        var added = AppSettings.shared.AddMissingSampleGames();
        if (added.Count == 0)
            MessageBox.Show("Tất cả game mẫu có sẵn đều đã nằm trong danh sách của bạn.", "Đã có đủ game mẫu",
                MessageBoxButton.OK, MessageBoxImage.Information);
        else
            MessageBox.Show(string.Join(", ", added) + ".\nMỗi game đã có sẵn thuật ngữ; bạn chỉ cần chọn nguồn hình và bấm Bắt đầu.",
                $"Đã thêm {added.Count} game", MessageBoxButton.OK, MessageBoxImage.Information);
    }
}

/// Thanh trạng thái cuối màn hình chơi: đang dịch hay không, engine dịch và quota, phím tắt.
public sealed class StatusBar : Border
{
    public StatusBar()
    {
        Height = 28; Padding = new Thickness(14, 0, 14, 0);
        Background = Ui.Res("CardFill"); BorderBrush = Ui.Res("CardStroke"); BorderThickness = new Thickness(0, 1, 0, 0);
        var p = Pipeline.shared;
        p.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Pipeline.isRunning)) Dispatcher.BeginInvoke(Refresh); };
        p.router.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        AppSettings.shared.Changed += k => { if (k.StartsWith("hotkey") || k is "translationEngine" or "geminiAPIKeys") Dispatcher.BeginInvoke(Refresh); };
        Refresh();
    }

    void Refresh()
    {
        var p = Pipeline.shared; var s = AppSettings.shared; var router = p.router;
        var color = router.state.level switch { 0 => Ui.Gemini, 1 => Ui.Orange, _ => Ui.Danger };
        var left = Ui.H(8, Ui.Dot(p.isRunning ? Brushes.LimeGreen : Ui.Tertiary, 7), Ui.Text(p.isRunning ? "Đang dịch" : "Đã dừng", 11.5, true, wrap: false),
            Ui.Text("·", 11.5, color: Ui.Tertiary), Ui.Dot(color, 7), Ui.Text(router.state.label, 11.5, wrap: false));
        if (s.engine == TranslationEngine.auto && s.geminiAPIKeys.Count > 0)
            left.Children.Add(Ui.Text($"{router.usedToday}/{s.geminiRPD} hôm nay", 11.5, color: Ui.Secondary, wrap: false));
        Child = Ui.Row(left, Ui.Text($"{s.hotkeyToggle.display} bắt đầu/dừng · {s.hotkeyAnalyze.display} dịch màn hình", 11.5, color: Ui.Tertiary, wrap: false));
    }
}

/// Phủ lên nội dung màn hình chơi khi PS5 mất kết nối và app đang tự kết nối lại.
public sealed class ReconnectOverlay : Grid
{
    readonly PS5Reconnector rc = PS5Reconnector.shared;
    readonly TextBlock line = Ui.Text("", 14, weight: FontWeights.Medium);
    readonly TextBlock error = Ui.Caption("");
    readonly Button retry;
    readonly PasswordBox pin = new() { Width = 180 };
    readonly StackPanel pinRow;
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(1) };

    public ReconnectOverlay()
    {
        Background = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0));
        retry = Ui.Btn(Ui.IconLabel("", "Thử ngay"), rc.RetryNow, minWidth: 180);
        var home = Ui.Btn(Ui.IconLabel("", "Về màn hình bắt đầu"), () => AppNav.shared.LeaveToStart("Đã dừng tự kết nối lại PS5."), kind: Ui.Kind.danger, minWidth: 180);
        pinRow = Ui.H(8, pin, Ui.Btn("Gửi", () => { PS5Stream.shared.SendPin(pin.Password); pin.Password = ""; }, primary: true));
        var card = new Border
        {
            Background = Brushes.White, CornerRadius = new CornerRadius(16), Padding = new Thickness(28), MaxWidth = 460,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Child = Ui.V(14, new ProgressBar { IsIndeterminate = true, Width = 80, Height = 4 }, Ui.Text("Mất kết nối PS5", 20, weight: FontWeights.Bold),
                line, error, pinRow, Ui.H(10, retry, home)),
        };
        foreach (FrameworkElement c in ((StackPanel)card.Child).Children) c.HorizontalAlignment = HorizontalAlignment.Center;
        error.TextAlignment = TextAlignment.Center; error.MaxWidth = 380;
        Children.Add(card);
        tick.Tick += (_, _) => Refresh();
        rc.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        PS5Stream.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        Refresh();
    }

    void Refresh()
    {
        Visibility = rc.active ? Visibility.Visible : Visibility.Collapsed;
        if (!rc.active) { tick.Stop(); return; }
        if (!tick.IsEnabled) tick.Start();
        if (rc.nextRetryAt is DateTime at)
        {
            int sec = Math.Max(0, (int)Math.Ceiling((at - DateTime.Now).TotalSeconds));
            line.Text = rc.attempt == 0 ? $"Tự kết nối lại sau {sec} giây…" : $"Lần {rc.attempt} chưa được. Thử lại sau {sec} giây…";
        }
        else line.Text = $"Đang kết nối lại (lần {Math.Max(1, rc.attempt)}/{rc.maxAttempts}): {PS5Stream.shared.state.label}";
        error.Text = rc.lastError;
        error.Visibility = rc.lastError.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        pinRow.Visibility = PS5Stream.shared.state.kind == PS5Stream.StateKind.needsPin ? Visibility.Visible : Visibility.Collapsed;
        retry.IsEnabled = rc.nextRetryAt != null;
    }
}

/// Tạo game mới: tên game + nguồn hình.
public sealed class NewProfileDialog : Window
{
    ProfileSource source = ProfileSource.external;

    public NewProfileDialog()
    {
        Title = "Game mới";
        Width = 480; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Ui.Res("WindowBg");
        var name = new TextBox { ToolTip = "Tên game (ví dụ: God of War Ragnarök)" };
        var options = Ui.V(8);
        void BuildOptions()
        {
            options.Children.Clear();
            foreach (var s in new[] { ProfileSource.external, ProfileSource.ps5 })
            {
                bool sel = source == s;
                var desc = s == ProfileSource.external
                    ? "Game, phim, trình duyệt… đang mở trên máy này. Bạn vẽ khung quanh màn hình game."
                    : "App kết nối Remote Play để lấy hình PS5. Bạn chơi bằng tay cầm nối thẳng với máy.";
                var row = Ui.Row(Ui.H(10, Ui.Icon(s == ProfileSource.external ? "" : "", 18), Ui.V(2, Ui.Text(Labels.Of(s), bold: true), Ui.Caption(desc).Also(t => t.MaxWidth = 340))),
                                 Ui.Icon(sel ? "" : "", 14, sel ? Ui.AccentStart : Ui.Secondary));
                var card = new Border
                {
                    Child = row, Padding = new Thickness(10), CornerRadius = new CornerRadius(9), Cursor = Cursors.Hand,
                    Background = sel ? new SolidColorBrush(Color.FromArgb(26, 97, 111, 250)) : Brushes.White,
                    BorderBrush = sel ? new SolidColorBrush(Color.FromArgb(153, 97, 111, 250)) : Ui.Res("CardStroke"), BorderThickness = new Thickness(1),
                };
                var src = s;
                card.MouseLeftButtonUp += (_, _) => { source = src; BuildOptions(); };
                options.Children.Add(card);
            }
        }
        BuildOptions();
        var create = Ui.Btn("Tạo", () => { AppNav.shared.CreateProfile(name.Text, source); DialogResult = true; }, primary: true);
        create.IsDefault = true;
        var cancel = Ui.Btn("Huỷ", () => DialogResult = false);
        cancel.IsCancel = true;
        var buttons = Ui.H(8, cancel, create); buttons.HorizontalAlignment = HorizontalAlignment.Right;
        Content = new Border
        {
            Padding = new Thickness(20),
            Child = Ui.V(14,
                Ui.H(8, Ui.Icon("", 18, Ui.AccentStart), Ui.Text("Game mới", 17, true)),
                Ui.Text("Mỗi game giữ riêng nguồn hình, khung phụ đề, thuật ngữ và tên nhân vật.", color: Ui.Secondary),
                Ui.V(3, Ui.Caption("Tên game (ví dụ: God of War Ragnarök)"), name),
                Ui.V(8, Ui.Text("Lấy hình từ đâu?", bold: true), options),
                buttons),
        };
        Loaded += (_, _) => name.Focus();
    }
}

// MARK: - Thiết lập game

/// Tab "Thiết lập game": phong cách dịch, tên người nói đã học, thuật ngữ riêng của game đang chơi.
public sealed class GameSetupView : DockPanel
{
    readonly ContentControl body = new();
    readonly StackPanel seg = new() { Orientation = Orientation.Horizontal };
    SpeakersTab? speakers; GlossaryTab? glossary;

    public GameSetupView()
    {
        LastChildFill = true;
        var bar = new Border { Height = 52, Padding = new Thickness(14, 0, 14, 0), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(0, 0, 0, 1), Child = seg };
        seg.VerticalAlignment = VerticalAlignment.Center;
        SetDock(bar, Dock.Top);
        Children.Add(bar);
        Children.Add(body);
        AppSettings.shared.Changed += k => { if (k is "speakers" or "showsSpeakerNames" or "profiles" or "activeProfile" or "activeProfileID" or "glossary") Dispatcher.BeginInvoke(BuildBar); };
        Show(AppSettings.shared.Get("gameSetupPart", "glossary"));
    }

    void BuildBar()
    {
        var s = AppSettings.shared;
        var part = s.Get("gameSetupPart", "glossary");
        seg.Children.Clear();
        foreach (var (key, title) in new[]
        {
            ("style", "Phong cách dịch"),
            ("speakers", s.showsSpeakerNames && s.speakers.Count > 0 ? $"Tên người nói  {s.speakers.Count}" : "Tên người nói"),
            ("glossary", s.glossary.Count > 0 ? $"Thuật ngữ  {s.glossary.Count}" : "Thuật ngữ"),
        })
        {
            var rb = new RadioButton { Content = title, GroupName = "gamesetup", IsChecked = key == part, MinWidth = 110,
                Style = (Style)Application.Current.FindResource(typeof(ToggleButton)) };
            var k = key;
            rb.Checked += (_, _) => Show(k);
            seg.Children.Add(rb);
        }
    }

    void Show(string part)
    {
        AppSettings.shared.Set("gameSetupPart", part, "gameSetupPart");
        BuildBar();
        body.Content = part switch
        {
            "style" => Ui.Scroll(GlossaryTab.TranslationStyleBox().Also(b => ((FrameworkElement)b).Margin = new Thickness(16))),
            "speakers" => speakers ??= new SpeakersTab(),
            _ => glossary ??= new GlossaryTab(),
        };
    }
}

// MARK: - Thiết lập game → Tên người nói

public sealed class SpeakersTab : ScrollViewer
{
    readonly TextBox newName = new() { Width = 180, ToolTip = "Thêm tên…" };

    public SpeakersTab()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        AppSettings.shared.Changed += k => { if (k is "speakers" or "showsSpeakerNames" or "activeProfile" or "profiles" or "activeProfileID") Dispatcher.BeginInvoke(Rebuild); };
        newName.KeyDown += (_, e) => { if (e.Key == Key.Enter) Add(); };
        Rebuild();
    }

    void Add()
    {
        var n = newName.Text.Trim();
        if (n.Length > 0) AppSettings.shared.LearnSpeaker(n);
        newName.Text = "";
    }

    void Rebuild()
    {
        var s = AppSettings.shared;
        var on = s.showsSpeakerNames;
        var toggle = Ui.Toggle("", () => s.showsSpeakerNames, v => s.showsSpeakerNames = v);
        toggle.Content = Ui.V(3, Ui.Text("Game này có hiện tên người nói", 16, true),
            Ui.Text("Phụ đề dạng “Atreus: câu thoại”. Tắt với game/phim chỉ hiện câu thoại, không có tên.", color: Ui.Secondary));
        var top = Ui.V(8, toggle);
        if (on)
        {
            top.Children.Add(Ui.Divider());
            foreach (var (g, t) in new[]
            {
                ("", $"Tự học tên từ câu có dạng “Tên: …” và lưu theo game “{s.activeProfile.name}”."),
                ("", "Khi OCR đọc sai dấu hai chấm (“Angrboda, …”) vẫn nhận ra tên đã học và sửa lại."),
                ("", "Không đọc tên khi phát voice; Gemini giữ nguyên tên, không dịch."),
                ("", "Mỗi nhân vật có một màu riêng; tên hiện theo màu đó ở phụ đề, overlay và nhật ký."),
            }) top.Children.Add(Ui.H(8, Ui.Icon(g, 13, Ui.Secondary), Ui.Text(t, color: Ui.Secondary)));
            top.Children.Add(Ui.Divider());
            var place = Ui.V(4, Ui.Text("Tên hiện ở đâu", bold: true));
            foreach (var (above, text) in new[] { (false, "Cùng dòng: “Tên: câu thoại”"), (true, "Dòng riêng phía trên câu thoại") })
            {
                var rb = new RadioButton { Content = Ui.Text(text), GroupName = "speakerAbove", IsChecked = s.speakerAbove == above };
                var v0 = above;
                rb.Checked += (_, _) => { if (s.speakerAbove != v0) s.speakerAbove = v0; };
                place.Children.Add(rb);
            }
            if (s.speakerAbove)
                place.Children.Add(Ui.Caption("Dòng đầu trong khung phụ đề, nếu ngắn (1–4 từ Viết Hoa, không dấu câu) hoặc là tên đã học, được coi là tên của câu bên dưới. Nhớ vẽ khung phụ đề bao cả dòng tên."));
            top.Children.Add(place);
        }
        var v = Ui.V(0, Ui.Card(top));
        if (on)
        {
            var addBtn = Ui.Btn("Thêm", Add);
            var right = new System.Collections.Generic.List<UIElement> { newName, addBtn };
            if (s.speakers.Count > 0) right.Add(Ui.Btn("Xoá hết", () => { if (Ui.Confirm("Xoá hết tên nhân vật đã học của game này?")) s.speakers = new(); }));
            var head = Ui.Row(Ui.H(8, Ui.Text("Tên người nói đã học", 14, true), new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 6, 0), Background = Ui.Res("CardFill"), Child = Ui.Text($"{s.speakers.Count}", 11, true) }), right.ToArray());
            var body = Ui.V(10, head);
            if (s.speakers.Count == 0)
                body.Children.Add(Ui.Text("Chưa có. Tên sẽ tự xuất hiện ở đây khi app gặp câu thoại có tên người nói.", color: Ui.Tertiary));
            else
            {
                var wrap = new WrapPanel();
                foreach (var name in s.speakers)
                {
                    var color = new SolidColorBrush(SpeakerColors.ColorFor(name, false, s.speakers));
                    var n = name;
                    var del = Ui.InlineIconBtn("", () => { var list = s.speakers; list.RemoveAll(x => x == n); s.speakers = list; }, "Xoá tên này");
                    var chip = new Border
                    {
                        Child = Ui.H(6, Ui.Dot(color, 10), Ui.Text(name, bold: true, color: color, wrap: false).Also(t => t.MaxWidth = 140), del),
                        Padding = new Thickness(10, 4, 6, 4), Margin = new Thickness(0, 0, 8, 8), CornerRadius = new CornerRadius(8),
                        Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), MinWidth = 150,
                    };
                    wrap.Children.Add(chip);
                }
                body.Children.Add(wrap);
            }
            v.Children.Add(Ui.Card(body));
        }
        v.Margin = new Thickness(16);
        Content = v;
    }
}

// MARK: - Thiết lập game → Thuật ngữ

/// Bảng thuật ngữ riêng của game đang chọn (phong cách dịch nằm ở mục riêng của Thiết lập game).
public sealed class GlossaryTab : DockPanel
{
    (Guid id, string name)? shown;

    public GlossaryTab()
    {
        Margin = new Thickness(16);
        // Chỉ dựng lại khi đổi game hoặc đổi tên game; sửa thuật ngữ / ghi chú cũng ghi vào "profiles" nhưng không cần dựng lại.
        AppSettings.shared.Changed += k => { if (k is "activeProfileID" or "profiles" or "activeProfile") Dispatcher.BeginInvoke(() => { if (Key() != shown) Rebuild(); }); };
        Rebuild();
    }

    static (Guid id, string name) Key() { var p = AppSettings.shared.activeProfile; return (p.id, p.name); }

    void Rebuild()
    {
        Children.Clear();
        shown = Key();
        var s = AppSettings.shared;
        var (id, name) = shown.Value;
        // Bảng cũ còn ghi khi bị gỡ (Unloaded) sau lúc đã đổi game: chỉ ghi vào đúng game của nó.
        Children.Add(new GlossaryEditor(() => s.glossary, v => { if (s.activeProfile.id == id) s.glossary = v; }, $"thuat-ngu-{name}.csv",
            $"Thuật ngữ riêng của game “{name}”: tên riêng, địa danh, chiêu thức… Khi trùng với thuật ngữ chung (Cài đặt → Thuật ngữ chung) thì bảng này được ưu tiên. Để trống bản dịch = giữ nguyên."));
    }

    /// Phong cách dịch và ghi chú cho người dịch của game đang chọn (đầu tab Thuật ngữ).
    public static UIElement TranslationStyleBox()
    {
        var s = AppSettings.shared;
        var guess = Labels.Of(TranslationStyles.Guess(s.activeProfile.name));
        var picker = Ui.Picker("", Enum.GetValues<TranslationStyle>().Select(x => (x, x == TranslationStyle.auto ? $"{Labels.Of(x)} (đang là: {guess})" : Labels.Of(x))),
            () => s.translationStyle, v => s.translationStyle = v, 320);
        var note = new TextBox { Text = s.translationNote, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 54, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        note.TextChanged += (_, _) => { if (note.Text != s.translationNote) s.translationNote = note.Text; };
        return Ui.Card(Ui.V(8,
            Ui.H(10, Ui.Text("Phong cách dịch", 14, true, wrap: false), picker),
            Ui.Caption("Quyết định giọng văn và cách xưng hô khi dịch: hiện đại (tôi – cậu, tao – mày), kỳ ảo trung cổ (tôi – ngài, ta – ngươi, Sir → ngài), thần thoại (ta – ngươi, cha – con)."),
            Ui.Text("Ghi chú cho người dịch (tuỳ chọn)", weight: FontWeights.Medium),
            note,
            Ui.Caption("Ví dụ: “Clive và Jill xưng anh – em”, “Cid gọi Clive là cậu”. Gửi kèm mỗi câu dịch, nên viết ngắn.")), 12);
    }
}
