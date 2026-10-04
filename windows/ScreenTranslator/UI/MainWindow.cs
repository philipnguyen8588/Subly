using System;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ScreenTranslator;

/// Cửa sổ chính: header, thanh tab (Màn hình / Nhật ký / Nhân vật), modal ảnh dịch màn hình.
public sealed class MainWindow : Window
{
    readonly ContentControl content = new();
    readonly StackPanel tabBar = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 0, 12, 8) };
    readonly HeaderBar header = new();
    SourceTab? sourceTab; LogTab? logTab; SpeakersTab? speakersTab;
    public bool reallyClose;

    public MainWindow()
    {
        Title = "ScreenTranslator";
        Width = 1000; Height = 700; MinWidth = 860; MinHeight = 560;
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

        var root = new Grid();
        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);
        DockPanel.SetDock(tabBar, Dock.Top);
        dock.Children.Add(tabBar);
        var div = new Border { Height = 1, Background = Ui.Res("CardStroke") };
        DockPanel.SetDock(div, Dock.Top);
        dock.Children.Add(div);
        dock.Children.Add(content);
        root.Children.Add(dock);
        root.Children.Add(new ShotModal());
        Content = root;

        AppNav.shared.PropertyChanged += (_, _) => ShowTab();
        AppNav.shared.NewProfileRequested += () => Dispatcher.BeginInvoke(() => new NewProfileDialog { Owner = this }.ShowDialog());
        AppSettings.shared.Changed += k => { if (k is "speakers" or "showsSpeakerNames" or "activeProfile" or "profiles" or "activeProfileID") Dispatcher.BeginInvoke(BuildTabBar); };
        ShowTab();

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

    void BuildTabBar()
    {
        tabBar.Children.Clear();
        var s = AppSettings.shared;
        foreach (var (t, glyph, title) in new[] { (AppNav.Tab.source, "", "Màn hình"), (AppNav.Tab.log, "", "Nhật ký"), (AppNav.Tab.speakers, "", "Nhân vật") })
        {
            bool sel = AppNav.shared.tab == t;
            var label = Ui.H(6, Ui.Icon(glyph, 12, sel ? Brushes.White : null), Ui.Text(title, 13, sel, sel ? Brushes.White : null, wrap: false));
            if (t == AppNav.Tab.speakers && s.showsSpeakerNames && s.speakers.Count > 0)
                label.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(5, 0, 5, 0), Margin = new Thickness(6, 0, 0, 0),
                    Background = sel ? new SolidColorBrush(Color.FromArgb(64, 255, 255, 255)) : Ui.Res("CardFill"),
                    Child = Ui.Text($"{s.speakers.Count}", 10.5, true, sel ? Brushes.White : null) });
            var b = new Border { Child = label, Padding = new Thickness(12, 6, 12, 6), CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 4, 0),
                Background = sel ? Ui.AccentGradient : Brushes.Transparent, Cursor = Cursors.Hand };
            var tab = t;
            b.MouseLeftButtonUp += (_, _) => AppNav.shared.tab = tab;
            tabBar.Children.Add(b);
        }
    }

    void ShowTab()
    {
        BuildTabBar();
        content.Content = AppNav.shared.tab switch
        {
            AppNav.Tab.source => sourceTab ??= new SourceTab(),
            AppNav.Tab.log => logTab ??= new LogTab(),
            _ => speakersTab ??= new SpeakersTab(),
        };
    }
}

/// Thanh trên cùng: Bắt đầu/Dừng, Dịch màn hình, trạng thái engine, chọn game, voice/overlay, tắt màn hình, cài đặt.
public sealed class HeaderBar : Border
{
    readonly Button startBtn, analyzeBtn;
    readonly Border pill = new() { CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 3, 10, 3) };
    readonly ToggleButton voiceBtn = new(), overlayBtn = new();
    readonly Button profileBtn = new();

    public HeaderBar()
    {
        Padding = new Thickness(14, 8, 14, 8);
        Height = 52;
        var pipeline = Pipeline.shared; var s = AppSettings.shared;
        startBtn = Ui.Btn("", pipeline.Toggle, primary: true);
        startBtn.MinWidth = 100;
        analyzeBtn = Ui.Btn("", pipeline.AnalyzeScreen);
        voiceBtn.Content = Ui.Icon("", 14);
        overlayBtn.Content = Ui.Icon("", 14);
        voiceBtn.IsChecked = s.voiceEnabled; overlayBtn.IsChecked = s.overlayEnabled;
        voiceBtn.Click += (_, _) => s.voiceEnabled = voiceBtn.IsChecked == true;
        overlayBtn.Click += (_, _) => { s.overlayEnabled = overlayBtn.IsChecked == true; if (!s.overlayEnabled) pipeline.overlay.Hide(); };
        var moon = Ui.IconBtn("", () => DisplayPower.shared.SleepDisplay(), "Tắt màn hình để tiết kiệm điện (app vẫn dịch và đọc). Di chuột hoặc gõ phím để bật lại");
        var gear = Ui.IconBtn("", App.ShowSettings, "Cài đặt: ngôn ngữ, Gemini, voice, overlay, thuật ngữ, phím tắt");
        profileBtn.Click += (_, _) => ProfileMenu().Also(m => { m.PlacementTarget = profileBtn; m.IsOpen = true; });
        profileBtn.ToolTip = "Game đang dịch. Mỗi game có nguồn hình, khung phụ đề, thuật ngữ và tên nhân vật riêng";

        var logo = Ui.H(8, new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Resources/AppIcon.png")), Width = 22, Height = 22 }, Ui.Text("ScreenTranslator", 14, true, wrap: false));
        var left = Ui.H(10, logo, startBtn, analyzeBtn, pill);
        Child = Ui.Row(left, profileBtn, voiceBtn, overlayBtn, moon, gear);

        pipeline.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Pipeline.isRunning)) Dispatcher.BeginInvoke(Refresh); };
        pipeline.analyzer.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        pipeline.router.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        s.Changed += _ => Dispatcher.BeginInvoke(Refresh);
        Refresh();
    }

    void Refresh()
    {
        var pipeline = Pipeline.shared; var s = AppSettings.shared; var router = pipeline.router; var an = pipeline.analyzer;
        startBtn.Content = Ui.IconLabel(pipeline.isRunning ? "" : "", pipeline.isRunning ? "Dừng" : "Bắt đầu");
        startBtn.Background = pipeline.isRunning ? Ui.Danger : Ui.AccentGradient;
        startBtn.ToolTip = $"Bắt đầu/Dừng dịch phụ đề ({s.hotkeyToggle.display})";
        analyzeBtn.Content = Ui.IconLabel("", an.isRunning ? (an.progress.Length == 0 ? "Đang dịch…" : an.progress) : "Dịch màn hình");
        analyzeBtn.IsEnabled = !an.isRunning;
        analyzeBtn.ToolTip = $"Chụp màn hình game, dịch toàn bộ chữ và mở ảnh với bản dịch đặt đè đúng vị trí ({s.hotkeyAnalyze.display})";
        var color = router.state.level switch { 0 => Ui.Gemini, 1 => Ui.Orange, _ => Ui.Danger };
        var detail = s.geminiAPIKey.Length == 0 ? "" : $"  {router.usedToday}/{s.rpd}";
        pill.Background = new SolidColorBrush(((SolidColorBrush)color).Color) { Opacity = 0.14 };
        pill.Child = Ui.H(6, Ui.Dot(color, 7), Ui.Text(router.state.label + detail, 12, color: color, wrap: false));
        pill.MaxWidth = 300;
        voiceBtn.IsChecked = s.voiceEnabled;
        voiceBtn.Content = Ui.Icon(s.voiceEnabled ? "" : "", 14);
        voiceBtn.ToolTip = $"Đọc bản dịch bằng giọng nói ({s.hotkeyVoice.display})";
        overlayBtn.IsChecked = s.overlayEnabled;
        overlayBtn.ToolTip = $"Hiện phụ đề dịch trên màn hình ({s.hotkeyOverlay.display})";
        profileBtn.Content = Ui.IconLabel("", s.activeProfile.name + "  ▾");
    }

    static ContextMenu ProfileMenu()
    {
        var s = AppSettings.shared;
        var m = new ContextMenu();
        foreach (var p in s.profiles)
        {
            var mi = new MenuItem { Header = $"{p.name}  ·  {Labels.Of(p.source)}", IsCheckable = true, IsChecked = p.id == s.activeProfileID };
            var prof = p;
            mi.Click += (_, _) => AppNav.shared.SwitchProfile(prof);
            m.Items.Add(mi);
        }
        m.Items.Add(new Separator());
        var add = new MenuItem { Header = "Game mới…", InputGestureText = "Ctrl+N" };
        add.Click += (_, _) => AppNav.shared.ShowNewProfile();
        m.Items.Add(add);
        var manage = new MenuItem { Header = "Đổi tên, xoá game…" };
        manage.Click += (_, _) => App.ShowSettings("profile");
        m.Items.Add(manage);
        return m;
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

// MARK: - Tab: Nhân vật

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
        }
        var v = Ui.V(0, Ui.Card(top));
        if (on)
        {
            var addBtn = Ui.Btn("Thêm", Add);
            var right = new System.Collections.Generic.List<UIElement> { newName, addBtn };
            if (s.speakers.Count > 0) right.Add(Ui.Btn("Xoá hết", () => { if (Ui.Confirm("Xoá hết tên nhân vật đã học của game này?")) s.speakers = new(); }));
            var head = Ui.Row(Ui.H(8, Ui.Text("Nhân vật đã học", 14, true), new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 6, 0), Background = Ui.Res("CardFill"), Child = Ui.Text($"{s.speakers.Count}", 11, true) }), right.ToArray());
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
                    var del = Ui.IconBtn("", () => { var list = s.speakers; list.RemoveAll(x => x == n); s.speakers = list; }, "Xoá tên này");
                    del.Padding = new Thickness(3, 1, 3, 1); del.BorderThickness = new Thickness(0); del.Background = Brushes.Transparent;
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
