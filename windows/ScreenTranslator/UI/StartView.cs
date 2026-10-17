using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Màn hình Bắt đầu (tương đương StartView.swift): chọn game (cột phải), chọn nguồn hình + xem AI dịch đã sẵn sàng chưa
/// (cột trái), rồi bấm Bắt đầu / Kết nối & bắt đầu mới vào màn hình chính.
public sealed class StartView : DockPanel
{
    readonly AppSettings s = AppSettings.shared;
    readonly AppNav nav = AppNav.shared;
    readonly PS5Stream stream = PS5Stream.shared;
    readonly Border notice = new() { Padding = new Thickness(16, 6, 16, 6), BorderThickness = new Thickness(0, 0, 0, 1) };
    readonly ContentControl tiles = new(), detail = new(), engineCard = new(), cta = new(), gameList = new();
    readonly TextBlock gameCount = Ui.Text("", 11, true, wrap: false);
    readonly TextBox search = new() { BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalContentAlignment = VerticalAlignment.Center };
    readonly WindowListView windowList = new();
    PS5Panel? ps5Panel;
    bool pending;
    string testError = "";
    bool testing;

    public StartView()
    {
        LastChildFill = true;
        Background = Ui.Res("WindowBg");
        // Thanh đầu: logo + hướng dẫn + cài đặt.
        var head = new Border
        {
            Height = 56, Padding = new Thickness(16, 0, 16, 0), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(0, 0, 0, 1),
            Child = Ui.Row(Logo(), Ui.IconBtn("", HeaderBar.OpenGuide, "Hướng dẫn sử dụng app"), Ui.IconBtn("", App.ShowSettings, "Cài đặt: dịch, AI, voice, overlay, phím tắt…")),
        };
        SetDock(head, Dock.Top); Children.Add(head);
        SetDock(notice, Dock.Top); Children.Add(notice);
        var support = Ui.SupportBanner();
        SetDock(support, Dock.Bottom); Children.Add(support);

        // Cột trái: nguồn hình.
        var left = new DockPanel { LastChildFill = true };
        var leftTop = Ui.V(12, Ui.Text("NGUỒN HÌNH", 11, true, Ui.Secondary), tiles);
        leftTop.Margin = new Thickness(0, 0, 0, 12);
        SetDock(leftTop, Dock.Top); left.Children.Add(leftTop);
        var leftBottom = Ui.V(12, engineCard, cta);
        leftBottom.Margin = new Thickness(0, 12, 0, 0);
        SetDock(leftBottom, Dock.Bottom); left.Children.Add(leftBottom);
        left.Children.Add(detail);
        var leftCard = Card(left);

        // Cột phải: danh sách game.
        var right = new DockPanel { LastChildFill = true };
        var newGame = Ui.Btn(Ui.IconLabel("", "Game mới"), nav.ShowNewProfile, primary: true, minWidth: 120);
        var searchBox = new Border
        {
            Height = 36, CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 0, 10, 0), Background = Brushes.White,
            BorderBrush = Ui.Hex("#1F000000"), BorderThickness = new Thickness(1), Margin = new Thickness(0, 12, 0, 12),
            Child = new DockPanel().Also(d =>
            {
                var ic = Ui.Icon("", 13, Ui.Tertiary); ic.Margin = new Thickness(0, 0, 6, 0);
                DockPanel.SetDock(ic, Dock.Left); d.Children.Add(ic); d.Children.Add(search);
            }),
        };
        Ui.OnSearch(search, BuildGames);
        var countPill = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 6, 0), Background = Ui.Res("CardFill"), Child = gameCount };
        var rightTop = Ui.V(0, Ui.Row(Ui.H(8, Ui.Text("CHỌN GAME", 11, true, Ui.Secondary), countPill), newGame), searchBox);
        SetDock(rightTop, Dock.Top); right.Children.Add(rightTop);
        var samples = Ui.Btn(Ui.IconLabel("", "Thêm game mẫu có sẵn"), HeaderBar.AddSampleGames, kind: Ui.Kind.ghost);
        samples.HorizontalAlignment = HorizontalAlignment.Left; samples.Margin = new Thickness(0, 10, 0, 0);
        SetDock(samples, Dock.Bottom); right.Children.Add(samples);
        right.Children.Add(Ui.Scroll(gameList));
        var rightCard = Card(right);

        var grid = new Grid { Margin = new Thickness(16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(400), MinWidth = 360 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(rightCard, 2);
        grid.Children.Add(leftCard); grid.Children.Add(rightCard);
        Children.Add(grid);

        s.Changed += _ => Schedule();
        nav.PropertyChanged += (_, _) => Schedule();
        stream.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(PS5Stream.state) or nameof(PS5Stream.host)) Schedule(); };
        IsVisibleChanged += (_, _) => { if (IsVisible) { windowList.Reload(); Rebuild(); } };
        Rebuild();
    }

    static Border Card(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(14), CornerRadius = new CornerRadius(12),
        Background = Brushes.White, BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1),
    };

    static UIElement Logo()
    {
        var title = Ui.V(0, Ui.Text("Subly", 16, weight: FontWeights.Bold, wrap: false), Ui.Text(AppInfo.VersionLabel, 10, color: Ui.Tertiary, wrap: false));
        return Ui.H(9, new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Resources/AppIcon.png")), Width = 24, Height = 24 }, title);
    }

    /// Gộp nhiều thay đổi liên tiếp thành một lần vẽ lại.
    void Schedule()
    {
        if (pending) return;
        pending = true;
        Dispatcher.BeginInvoke(() => { pending = false; if (IsVisible) Rebuild(); }, DispatcherPriority.Background);
    }

    void Rebuild()
    {
        // Thông báo (ví dụ vừa mất kết nối PS5).
        if (nav.notice is string n)
        {
            var c = ((SolidColorBrush)Ui.Danger).Color;
            notice.Visibility = Visibility.Visible;
            notice.Background = new SolidColorBrush(Color.FromArgb(26, c.R, c.G, c.B));
            notice.BorderBrush = new SolidColorBrush(Color.FromArgb(64, c.R, c.G, c.B));
            notice.Child = Ui.Row(Ui.H(10, Ui.Icon("", 14, Ui.Danger), Ui.Text(n, weight: FontWeights.Medium)),
                Ui.IconBtn("", () => nav.notice = null, "Đóng", Ui.Kind.ghost));
        }
        else notice.Visibility = Visibility.Collapsed;

        tiles.Content = TilesRow();
        if (s.source == ProfileSource.external)
        {
            windowList.Refresh();
            if (!ReferenceEquals(detail.Content, windowList)) detail.Content = Ui.Detach(windowList);
        }
        else
        {
            ps5Panel ??= new PS5Panel();
            ps5Panel.Refresh();
            if (!ReferenceEquals(detail.Content, ps5Panel)) detail.Content = ps5Panel;
        }
        engineCard.Content = EngineCard();
        cta.Content = Cta();
        BuildGames();
    }

    // MARK: nguồn hình

    UIElement TilesRow()
    {
        var g = new UniformGrid { Columns = 2 };
        foreach (var src in new[] { ProfileSource.external, ProfileSource.ps5 })
        {
            bool sel = s.source == src;
            var accent = ((SolidColorBrush)Ui.AccentStart).Color;
            var fg = sel ? Ui.AccentStart : Brushes.Black;
            var row = Ui.Row(Ui.H(10, Ui.Icon(src == ProfileSource.external ? "" : "", 18, fg),
                    Ui.Text(src == ProfileSource.external ? "App trên máy" : "PS5 qua Chiaki", 14, true, fg, wrap: false)),
                Ui.Icon(sel ? "" : "", 13, sel ? Ui.AccentStart : Ui.Tertiary));
            var tile = new Border
            {
                Child = row, Height = 52, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(10), Cursor = Cursors.Hand,
                Margin = new Thickness(src == ProfileSource.external ? 0 : 5, 0, src == ProfileSource.external ? 5 : 0, 0),
                Background = sel ? new SolidColorBrush(Color.FromArgb(26, accent.R, accent.G, accent.B)) : Ui.Hex("#0F000000"),
                BorderBrush = sel ? new SolidColorBrush(Color.FromArgb(180, accent.R, accent.G, accent.B)) : Ui.Hex("#1F000000"),
                BorderThickness = new Thickness(sel ? 1.5 : 1),
                ToolTip = src == ProfileSource.external ? "Game, phim, trình duyệt… đang mở trên máy này" : "Nhận hình PS5 qua Remote Play (Chiaki) ngay trong app",
            };
            var v = src;
            tile.MouseLeftButtonUp += (_, _) => nav.SetSource(v);
            g.Children.Add(tile);
        }
        return g;
    }

    // MARK: AI dịch

    UIElement EngineCard()
    {
        var issues = Readiness.allTasks.Select(t => (t, issue: Readiness.IssueOf(t))).ToList();
        bool blocking = issues.Any(x => x.issue != null && Readiness.IsRequired(x.t));
        bool canTest = issues.Any(x => x.issue?.tab == "translate");
        var tools = new List<UIElement>();
        if (canTest)
            tools.Add(Ui.Btn(testing ? "Đang kiểm tra…" : "Kiểm tra", TestAll, kind: Ui.Kind.tinted, minWidth: 96).Also(b => b.IsEnabled = !testing));
        tools.Add(Ui.IconBtn("", () => App.ShowSettings(issues.FirstOrDefault(x => x.issue != null).issue?.tab ?? "translate"), "Cài đặt dịch: chọn AI, model, key"));
        var v = Ui.V(8, Ui.Row(Ui.Text("AI DỊCH", 11, true, Ui.Secondary), tools.ToArray()));
        foreach (var (t, issue) in issues)
        {
            var e = Readiness.Engine(t);
            bool required = Readiness.IsRequired(t);
            var line = e.keyless ? $"{e.name} · không cần key" : $"{e.name} · {(e.model.Length == 0 ? "chưa chọn model" : e.model)}";
            var info = Ui.H(10, Ui.Icon(Readiness.TaskGlyph(t), 14, Ui.AccentStart),
                Ui.V(1, Ui.Text(Readiness.TaskTitle(t), 11, color: Ui.Secondary, wrap: false), Ui.Text(line, 13, true, wrap: false).Also(x => x.MaxWidth = 230)));
            UIElement status = issue == null
                ? Ui.H(5, Ui.Icon("", 12, Ui.Hex("#FF2E9E4F")), Ui.Text("Sẵn sàng", 11.5, true, Ui.Hex("#FF2E9E4F"), wrap: false))
                : Ui.H(5, Ui.Icon(required ? "" : "", 12, required ? Ui.Orange : Ui.Secondary),
                    Ui.Text(issue.title, 11.5, true, required ? Ui.Orange : Ui.Secondary, wrap: false)).Also(x => x.ToolTip = required ? issue.detail : issue.detail + " (Không bắt buộc khi chưa bật tự viết cốt truyện.)");
            v.Children.Add(Ui.Row(info, status));
        }
        if (testError.Length > 0) v.Children.Add(Ui.Caption(testError, Ui.Danger));
        var o = ((SolidColorBrush)Ui.Orange).Color;
        return new Border
        {
            Child = v, Padding = new Thickness(12), CornerRadius = new CornerRadius(10),
            Background = blocking ? new SolidColorBrush(Color.FromArgb(20, o.R, o.G, o.B)) : Ui.Hex("#0F000000"),
            BorderBrush = blocking ? new SolidColorBrush(Color.FromArgb(90, o.R, o.G, o.B)) : Ui.Hex("#1F000000"), BorderThickness = new Thickness(1),
        };
    }

    async void TestAll()
    {
        testing = true; testError = ""; Rebuild();
        var err = await Readiness.TestAll();
        testing = false; testError = err == null ? "" : $"Lỗi – {err}";
        Rebuild();
    }

    UIElement Cta()
    {
        if (nav.entering)
        {
            var bar = new ProgressBar { IsIndeterminate = true, Width = 36, Height = 4 };
            return Ui.V(6, Ui.H(8, bar, Ui.Caption(stream.state.label)),
                Ui.Btn(Ui.IconLabel("", "Huỷ kết nối"), nav.CancelEnter, large: true).Also(b => b.HorizontalAlignment = HorizontalAlignment.Stretch));
        }
        var b = Ui.Btn(Ui.IconLabel("", s.source == ProfileSource.ps5 ? "Kết nối & bắt đầu" : "Bắt đầu"), nav.Enter, primary: true, large: true,
            tip: $"Vào màn hình chơi của “{s.activeProfile.name}” và bắt đầu dịch phụ đề ({s.hotkeyToggle.display})");
        b.HorizontalAlignment = HorizontalAlignment.Stretch;
        b.IsDefault = true;
        return b;
    }

    // MARK: danh sách game

    void BuildGames()
    {
        var all = s.profiles;
        gameCount.Text = $"{all.Count}";
        var q = search.Text.Trim().ToLowerInvariant();
        var games = q.Length == 0 ? all : all.Where(p => p.name.ToLowerInvariant().Contains(q)).ToList();
        var v = Ui.V(8);
        foreach (var p in games) v.Children.Add(GameCard(p, p.id == s.activeProfile.id));
        if (games.Count == 0)
            v.Children.Add(Ui.Text(q.Length == 0 ? "Chưa có game nào." : $"Không có game nào khớp “{search.Text}”.", color: Ui.Secondary)
                .Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 24, 0, 0); }));
        v.Margin = new Thickness(0, 0, 4, 0);
        gameList.Content = v;
    }

    UIElement GameCard(Profile p, bool selected)
    {
        var accent = ((SolidColorBrush)Ui.AccentStart).Color;
        var parts = new List<string> { p.source == ProfileSource.ps5 ? "PS5 qua Chiaki" : "App trên máy" };
        if (p.glossary.Count > 0) parts.Add($"{p.glossary.Count} thuật ngữ");
        if (p.speakers.Count > 0) parts.Add($"{p.speakers.Count} nhân vật");
        var icon = new Border
        {
            Width = 42, Height = 42, CornerRadius = new CornerRadius(10), Background = selected ? Ui.AccentGradient : Ui.Hex("#0F000000"),
            Child = Ui.Icon(p.source == ProfileSource.ps5 ? "" : "", 18, selected ? Brushes.White : Ui.Secondary).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
        };
        var menu = new ContextMenu();
        void Item(string text, Action a, bool enabled = true) { var mi = new MenuItem { Header = text, IsEnabled = enabled }; mi.Click += (_, _) => a(); menu.Items.Add(mi); }
        Item("Xem cốt truyện, phụ đề…", () => nav.Browse(p));
        menu.Items.Add(new Separator());
        Item("Đổi tên…", () => nav.RenameProfile(p, Window.GetWindow(this)));
        Item("Nhân bản", () => nav.DuplicateProfile(p));
        menu.Items.Add(new Separator());
        Item("Xoá…", () => nav.DeleteProfile(p), s.profiles.Count > 1);
        var more = Ui.InlineIconBtn("", () => { }, "Đổi tên, nhân bản, xoá game");
        more.Width = 32; more.Height = 32;
        more.Click += (_, e) => { menu.PlacementTarget = more; menu.IsOpen = true; e.Handled = true; };
        var right = new List<UIElement>();
        if (selected) right.Add(Ui.Icon("", 16, Ui.AccentStart));
        right.Add(Ui.Btn(Ui.IconLabel("\uE7B3", "Xem"), () => nav.Browse(p), kind: Ui.Kind.ghost,
            tip: "Vào xem cốt truyện, phụ đề và ảnh đã dịch của game này mà không cần kết nối"));
        right.Add(more);
        var row = Ui.Row(Ui.H(12, icon, Ui.V(3, Ui.Text(p.name, 15, true, wrap: false), Ui.Caption(string.Join(" · ", parts)))), right.ToArray());
        var card = new Border
        {
            Child = row, Height = 64, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(12), Cursor = Cursors.Hand,
            Background = selected ? new SolidColorBrush(Color.FromArgb(26, accent.R, accent.G, accent.B)) : Ui.Hex("#08000000"),
            BorderBrush = selected ? new SolidColorBrush(Color.FromArgb(180, accent.R, accent.G, accent.B)) : Ui.Res("CardStroke"),
            BorderThickness = new Thickness(selected ? 1.5 : 1), ContextMenu = menu,
        };
        card.MouseEnter += (_, _) => { if (!selected) card.Background = Ui.Hex("#12000000"); };
        card.MouseLeave += (_, _) => { if (!selected) card.Background = Ui.Hex("#08000000"); };
        card.MouseLeftButtonUp += (_, _) => nav.SwitchProfile(p);
        return card;
    }
}

/// Danh sách cửa sổ đang mở để chọn làm màn hình game. Dùng ở màn Bắt đầu và ở nút "Đổi cửa sổ" của tab Màn hình.
public sealed class WindowListView : DockPanel
{
    readonly StackPanel rows = Ui.V(6);
    List<WindowFinder.WindowInfo> windows = new();
    public Action? onPicked;

    public WindowListView()
    {
        LastChildFill = true;
        var head = Ui.Row(Ui.Text("Chọn cửa sổ đang chạy game", bold: true),
            Ui.IconBtn("", Reload, "Làm mới danh sách cửa sổ"),
            Ui.IconBtn("", () => { onPicked?.Invoke(); RegionActions.PickGameArea(); }, "Vẽ vùng thủ công: kéo chuột quanh khu vực hình của game trên màn hình"));
        head.Margin = new Thickness(0, 0, 0, 8);
        SetDock(head, Dock.Top); Children.Add(head);
        Children.Add(Ui.Scroll(rows));
        Loaded += (_, _) =>
        {
            if (Window.GetWindow(this) is Window w) w.Activated += (_, _) => { if (IsVisible) Reload(); };
            Reload();
        };
    }

    /// Đọc lại danh sách cửa sổ rồi vẽ lại.
    public void Reload()
    {
        windows = WindowFinder.GameCandidates();
        Refresh();
    }

    bool IsCurrent(WindowFinder.WindowInfo w, Region? area)
    {
        if (area == null) return false;
        if (area.windowID is long id && windows.Any(x => x.hwnd.ToInt64() == id)) return w.hwnd.ToInt64() == id;
        return area.appBundleID == w.app.bundleID && windows.FirstOrDefault(x => x.app.bundleID == w.app.bundleID)?.hwnd == w.hwnd;
    }

    /// Vẽ lại (đánh dấu cửa sổ đang dùng) mà không đọc lại danh sách.
    public void Refresh()
    {
        var area = AppSettings.shared.externalArea;
        rows.Children.Clear();
        if (area != null && !windows.Any(w => IsCurrent(w, area)))
            rows.Children.Add(Row(Ui.Icon("", 16, Ui.AccentStart), area.appName ?? "Vùng vẽ thủ công",
                area.followsWindow ? "Đang dùng · cửa sổ hiện không thấy trên màn hình" : $"Đang dùng · {(int)area.width}×{(int)area.height}", true, null));
        foreach (var w in windows)
        {
            var img = WindowFinder.AppIcon(w.hwnd);
            UIElement icon = img != null ? new Image { Source = img, Width = 28, Height = 28 } : Ui.Icon("", 18);
            var sub = $"{(int)w.bounds.Width}×{(int)w.bounds.Height}";
            var win = w;
            rows.Children.Add(Row(icon, w.app.name, $"{w.title} · {sub}", IsCurrent(w, area), () => { RegionActions.UseWindow(win); onPicked?.Invoke(); }));
        }
        if (windows.Count == 0)
            rows.Children.Add(Ui.Text("Không thấy cửa sổ nào. Mở game hoặc phim trên máy này rồi bấm Làm mới.", color: Ui.Secondary)
                .Also(t => { t.TextAlignment = TextAlignment.Center; t.Margin = new Thickness(0, 20, 0, 0); }));
    }

    static UIElement Row(UIElement icon, string title, string sub, bool selected, Action? onClick)
    {
        var accent = ((SolidColorBrush)Ui.AccentStart).Color;
        var right = selected ? new UIElement[] { Ui.Icon("", 14, Ui.AccentStart) } : Array.Empty<UIElement>();
        var b = new Border
        {
            Height = 48, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(9), Cursor = onClick != null ? Cursors.Hand : null,
            Background = selected ? new SolidColorBrush(Color.FromArgb(26, accent.R, accent.G, accent.B)) : Brushes.Transparent,
            BorderBrush = selected ? new SolidColorBrush(Color.FromArgb(150, accent.R, accent.G, accent.B)) : Ui.Res("CardStroke"), BorderThickness = new Thickness(1),
            Child = Ui.Row(Ui.H(10, icon, Ui.V(2, Ui.Text(title, 13, true, wrap: false), Ui.Caption(sub).Also(t => { t.TextWrapping = TextWrapping.NoWrap; t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 260; }))), right),
        };
        if (onClick != null)
        {
            b.MouseEnter += (_, _) => { if (!selected) b.Background = Ui.Hex("#0F000000"); };
            b.MouseLeave += (_, _) => { if (!selected) b.Background = Brushes.Transparent; };
            b.MouseLeftButtonUp += (_, _) => onClick();
        }
        return b;
    }
}

/// Khung PS5 ở màn Bắt đầu: máy đã đăng ký, trạng thái, chất lượng hình, tự kết nối lại; chưa có máy thì nút Thiết lập PS5.
public sealed class PS5Panel : ContentControl
{
    readonly PS5Stream stream = PS5Stream.shared;
    readonly AppSettings s = AppSettings.shared;
    readonly PasswordBox pin = new() { Width = 180 };

    public void Refresh()
    {
        if (stream.host is not PS5Host host)
        {
            var v = Ui.V(10, Ui.Icon("", 34, Ui.AccentStart), Ui.Text("Chưa có máy PS5", 15, true),
                Ui.Text("Nhập máy đã đăng ký trong chiaki-ng, hoặc đăng ký mới bằng mã PIN trên PS5.", color: Ui.Secondary).Also(t => t.TextAlignment = TextAlignment.Center),
                Ui.Btn(Ui.IconLabel("", "Thiết lập PS5"), OpenSetup, kind: Ui.Kind.tinted));
            foreach (FrameworkElement c in v.Children) c.HorizontalAlignment = HorizontalAlignment.Center;
            v.Margin = new Thickness(0, 16, 0, 0);
            Content = v;
            return;
        }
        var color = stream.state.kind switch
        {
            PS5Stream.StateKind.streaming => Brushes.LimeGreen, PS5Stream.StateKind.failed => Ui.Danger,
            PS5Stream.StateKind.idle => Ui.Secondary, _ => Ui.Orange,
        };
        var list = Ui.V(12,
            Ui.Row(Ui.H(10, Ui.Icon("", 22, Ui.AccentStart), Ui.V(2, Ui.Text(host.nickname, 15, true, wrap: false),
                    Ui.Caption($"{(host.ps5 ? "PS5" : "PS4")} · {(host.host.Length == 0 ? "tự dò theo MAC" : host.host)}"))),
                Ui.IconBtn("", () => new PS5ConfigWindow(host, Window.GetWindow(this)).ShowDialog(), "Xem cấu hình Remote Play (IP, MAC, account, khoá đăng ký)")),
            Ui.H(6, Ui.Dot(color), Ui.Caption(stream.state.label)));
        if (stream.state.kind == PS5Stream.StateKind.needsPin)
            list.Children.Add(Ui.H(8, Ui.Detach(pin), Ui.Btn("Gửi", () => { stream.SendPin(pin.Password); pin.Password = ""; }, primary: true)));
        list.Children.Add(Ui.BlockRow("Chất lượng", Segmented(new[] { (4, "1080p"), (3, "720p") }, s.ps5Resolution, v => s.ps5Resolution = v)));
        list.Children.Add(Ui.BlockRow("Khung hình", Segmented(new[] { (30, "30 fps"), (60, "60 fps") }, s.ps5FPS, v => s.ps5FPS = v)));
        var auto = Ui.Toggle("", () => s.ps5AutoReconnect, v => s.ps5AutoReconnect = v);
        auto.Content = Ui.V(2, Ui.Text("Tự kết nối lại khi mất kết nối", weight: FontWeights.SemiBold),
            Ui.Caption($"Thử lại tối đa {s.ps5ReconnectAttempts} lần, màn hình chính hiện trạng thái trong lúc chờ. Tắt = quay về màn hình này."));
        list.Children.Add(auto);
        list.Children.Add(Ui.Btn(Ui.IconLabel("", "Quên máy này"), () =>
        {
            if (Ui.Confirm($"Quên máy {host.nickname}? Phải đăng ký lại để dùng.")) { stream.Disconnect(); stream.SetHost(null); }
        }, kind: Ui.Kind.ghost).Also(b => { b.HorizontalAlignment = HorizontalAlignment.Left; b.IsEnabled = !stream.state.isBusy; }));
        Content = Ui.Scroll(list);
    }

    UIElement Segmented((int value, string text)[] items, int current, Action<int> set)
    {
        var h = Ui.H(0);
        foreach (var (v, t) in items)
        {
            var b = new RadioButton { Content = t, GroupName = Guid.NewGuid().ToString(), IsChecked = v == current, MinWidth = 90, IsEnabled = !stream.state.isBusy,
                Style = (Style)Application.Current.FindResource(typeof(ToggleButton)) };
            var val = v;
            b.Checked += (_, _) => { if (val != current) set(val); };
            h.Children.Add(b);
        }
        // Cùng một nhóm cho các nút của hàng này.
        var group = Guid.NewGuid().ToString();
        foreach (var rb in h.Children.OfType<RadioButton>()) rb.GroupName = group;
        return h;
    }

    void OpenSetup()
    {
        var w = new Window
        {
            Title = "Thiết lập PS5", Width = 720, Height = 640, Owner = Window.GetWindow(this), WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Ui.Res("WindowBg"), Content = new PS5SetupView(),
        };
        System.ComponentModel.PropertyChangedEventHandler? h = null;
        h = (_, e) => { if (e.PropertyName == nameof(PS5Stream.host) && stream.host != null) App.RunOnUI(() => { if (w.IsVisible) w.Close(); }); };
        stream.PropertyChanged += h;
        w.Closed += (_, _) => stream.PropertyChanged -= h;
        w.ShowDialog();
    }
}
