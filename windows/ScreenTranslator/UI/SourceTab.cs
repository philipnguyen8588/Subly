using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace ScreenTranslator;

/// Dải phụ đề dưới hình: chỉ hiện bản dịch.
public sealed class SubtitleStrip : Border
{
    readonly Func<string> idleHint;

    public SubtitleStrip(Func<string> idleHint)
    {
        this.idleHint = idleHint;
        Padding = new Thickness(16, 10, 16, 10);
        MinHeight = 72;
        Background = Brushes.White;
        BorderBrush = Ui.Res("CardStroke"); BorderThickness = new Thickness(0, 1, 0, 0);
        Pipeline.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        Pipeline.shared.router.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        Refresh();
    }

    public void Refresh()
    {
        var p = Pipeline.shared;
        var v = Ui.V(4);
        if (p.router.lastError is string e) v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(e, 11.5, color: Ui.Danger)));
        if (p.skippedUI.Values.FirstOrDefault() is string skipped)
            v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Secondary), Ui.Text($"Đang bỏ qua chữ giao diện (menu/cài đặt): {(skipped.Length > 70 ? skipped[..70] : skipped)}", 11.5, color: Ui.Secondary, wrap: false)));
        if (p.lastTranslated.Length == 0)
            v.Children.Add(Ui.Text(p.isRunning ? "Đang chờ phụ đề xuất hiện…" : idleHint(), 17, color: Ui.Tertiary).Also(t => t.TextAlignment = TextAlignment.Center));
        else
        {
            var t = Ui.Styled(p.lastTranslated, 20, weight: FontWeights.SemiBold);
            t.TextAlignment = TextAlignment.Center; t.MaxHeight = 120;
            v.Children.Add(t);
        }
        foreach (FrameworkElement c in v.Children) c.HorizontalAlignment = HorizontalAlignment.Center;
        Child = v;
    }
}

/// Tab Màn hình: nguồn hình của game (app ngoài hoặc PS5).
public sealed class SourceTab : Border
{
    public SourceTab()
    {
        AppSettings.shared.Changed += k => { if (k is "source" or "activeProfile" or "activeProfileID" or "profiles" or "regions") Dispatcher.BeginInvoke(Rebuild); };
        Rebuild();
    }

    ProfileSource? built;
    Guid builtProfile;

    void Rebuild()
    {
        var s = AppSettings.shared;
        if (built == s.source && builtProfile == s.activeProfile.id && Child != null)
        {
            (Child as ExternalSourceView)?.Refresh();
            (Child as PS5SourceView)?.Refresh();
            return;
        }
        built = s.source; builtProfile = s.activeProfile.id;
        Child = s.source == ProfileSource.ps5 ? new PS5SourceView() : new ExternalSourceView();
    }

    /// Bộ chọn nguồn hình, đặt ở đầu thanh điều khiển của cả hai chế độ.
    public static UIElement SourcePicker()
    {
        var s = AppSettings.shared;
        var ext = new RadioButton { Content = Ui.IconLabel("", Labels.Of(ProfileSource.external)), IsChecked = s.source == ProfileSource.external, GroupName = "src", Style = (Style)Application.Current.FindResource(typeof(ToggleButton)) };
        var ps5 = new RadioButton { Content = Ui.IconLabel("", Labels.Of(ProfileSource.ps5)), IsChecked = s.source == ProfileSource.ps5, GroupName = "src", Style = (Style)Application.Current.FindResource(typeof(ToggleButton)) };
        ext.Checked += (_, _) => AppNav.shared.SetSource(ProfileSource.external);
        ps5.Checked += (_, _) => AppNav.shared.SetSource(ProfileSource.ps5);
        var h = Ui.H(0, ext, ps5);
        h.ToolTip = $"Nguồn hình của game “{s.activeProfile.name}”";
        return h;
    }

    public static Border Toolbar(UIElement content) => new()
    {
        Child = content, Padding = new Thickness(14, 8, 14, 8), Background = Brushes.White,
        BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(0, 0, 0, 1),
    };
}

// MARK: App ngoài

public sealed class ExternalSourceView : DockPanel
{
    readonly GameScreenView screen = new();
    readonly ToggleButton drawToggle = new() { Content = Ui.IconLabel("", "Vẽ khung phụ đề"), ToolTip = "Bật rồi kéo chuột trên hình để chọn chỗ phụ đề xuất hiện" };
    readonly ContentControl toolbarSlot = new();
    readonly ContentControl body = new();
    readonly SubtitleStrip strip = new(() => "Bấm Bắt đầu để dịch phụ đề.");
    readonly ExternalMirror mirror = ExternalMirror.shared;

    public ExternalSourceView()
    {
        LastChildFill = true;
        var tb = SourceTab.Toolbar(toolbarSlot);
        SetDock(tb, Dock.Top);
        Children.Add(tb);
        Children.Add(body);
        screen.onDraw = RegionActions.SetExternalSubtitle;
        screen.onEditingEnded = () => drawToggle.IsChecked = false;
        drawToggle.Checked += (_, _) => screen.Editing = true;
        drawToggle.Unchecked += (_, _) => screen.Editing = false;
        mirror.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        Loaded += (_, _) => { mirror.Ensure(AppSettings.shared.externalArea); Refresh(); };
        Refresh();
    }

    /// Khung phụ đề theo tỉ lệ bên trong khung màn hình game.
    static RectD? SubtitleRect()
    {
        var s = AppSettings.shared;
        if (s.externalArea is not Region area || s.externalSubtitle is not Region sub) return null;
        var a = WindowFinder.CurrentRect(area); var r = WindowFinder.CurrentRect(sub);
        if (a.Width <= 1 || a.Height <= 1) return null;
        return new RectD((r.X - a.X) / a.Width, (r.Y - a.Y) / a.Height, r.Width / a.Width, r.Height / a.Height);
    }

    public void Refresh()
    {
        var s = AppSettings.shared;
        var area = s.externalArea;
        // Thanh công cụ
        var left = Ui.H(10, SourceTab.SourcePicker());
        if (area != null)
        {
            var info = mirror.error ?? $"{(int)area.width}×{(int)area.height}{(area.followsWindow ? " · bám theo cửa sổ" : "")}{(mirror.capturedAt is DateTime t ? $" · ảnh lúc {t:HH:mm:ss}" : "")}";
            left.Children.Add(Ui.H(8, Ui.Dot(mirror.error == null ? Brushes.LimeGreen : Ui.Danger),
                Ui.V(1, Ui.Text(area.appName ?? "Vùng màn hình", bold: true, wrap: false), Ui.Caption(info, mirror.error == null ? null : Ui.Danger))).Also(x => x.Margin = new Thickness(10, 0, 0, 0)));
        }
        if (area != null)
        {
            var cap = Ui.Btn(Ui.IconLabel("", mirror.capturing ? "Đang chụp…" : "Chụp màn hình game"), () => mirror.Capture(AppSettings.shared.externalArea!),
                tip: "Chụp lại hình hiện tại của game để xem và đặt khung phụ đề. App không chụp toàn màn hình liên tục để máy nhẹ.");
            cap.IsEnabled = !mirror.capturing;
            drawToggle.IsEnabled = mirror.image != null;
            var repick = Ui.IconBtn("", RegionActions.PickGameArea, "Chọn lại vùng game: vẽ lại khung toàn bộ khu vực hiển thị game trên màn hình");
            toolbarSlot.Content = Ui.Row(left, cap, drawToggle, repick);
        }
        else toolbarSlot.Content = left;

        // Nội dung
        if (area == null)
        {
            var pick = Ui.Btn(Ui.IconLabel("", "Chọn vùng game"), RegionActions.PickGameArea, primary: true);
            var v = Ui.V(14,
                Ui.EmptyState("", "Chọn vùng hiển thị game",
                    "Mở game hoặc phim trên máy này, rồi vẽ một khung quanh toàn bộ khu vực hình của nó. App chụp một tấm ảnh của vùng đó để bạn đặt khung phụ đề.",
                    "Bấm “Chọn vùng game” và kéo chuột quanh màn hình game", "Kéo chuột trên ảnh để đặt khung phụ đề (đã có sẵn ở dải dưới)", "Bấm Bắt đầu"),
                pick);
            pick.HorizontalAlignment = HorizontalAlignment.Center;
            if (s.externalSubtitle != null)
                v.Children.Add(Ui.Caption("Game này đã có khung phụ đề từ trước nên vẫn dịch được; chọn vùng game để xem hình trong app và dùng Dịch màn hình.").Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 460; }));
            v.VerticalAlignment = VerticalAlignment.Center;
            body.Content = v;
            return;
        }
        screen.SetStill(mirror.image, mirror.imageSize);
        screen.SetSubtitle(SubtitleRect());
        screen.Placeholder = Ui.V(8, Ui.Icon("", 40, new SolidColorBrush(Color.FromArgb(128, 255, 255, 255))),
            Ui.Text(mirror.error ?? (mirror.capturing ? "Đang chụp…" : "Bấm “Chụp màn hình game” để lấy hình hiện tại"), color: new SolidColorBrush(Color.FromArgb(190, 255, 255, 255))))
            .Also(x => { foreach (FrameworkElement c in x.Children) c.HorizontalAlignment = HorizontalAlignment.Center; });
        if (body.Content is not DockPanel)
        {
            var d = new DockPanel();
            SetDock(strip, Dock.Bottom);
            d.Children.Add(strip);
            d.Children.Add(screen);
            body.Content = d;
        }
        strip.Refresh();
    }
}

// MARK: PS5

public sealed class PS5SourceView : DockPanel
{
    readonly GameScreenView screen = new();
    readonly ToggleButton drawToggle = new() { Content = Ui.IconLabel("", "Vẽ khung phụ đề"), ToolTip = "Bật rồi kéo chuột trên hình để chọn chỗ phụ đề xuất hiện" };
    readonly ContentControl toolbarSlot = new();
    readonly ContentControl body = new();
    readonly SubtitleStrip strip;
    readonly PS5Stream stream = PS5Stream.shared;
    PS5Stream.StateKind lastKind = PS5Stream.StateKind.idle;

    public PS5SourceView()
    {
        strip = new SubtitleStrip(() => PS5Stream.shared.isStreaming ? "Bấm Bắt đầu để dịch phụ đề." : " ");
        LastChildFill = true;
        var tb = SourceTab.Toolbar(toolbarSlot);
        SetDock(tb, Dock.Top);
        Children.Add(tb);
        Children.Add(body);
        screen.onDraw = PS5Coordinator.SetSubtitleRect;
        screen.onEditingEnded = () => drawToggle.IsChecked = false;
        drawToggle.Checked += (_, _) => screen.Editing = true;
        drawToggle.Unchecked += (_, _) => screen.Editing = false;
        lastKind = stream.state.kind;
        stream.PropertyChanged += (_, e) => Dispatcher.BeginInvoke(() =>
        {
            if (e.PropertyName == nameof(PS5Stream.state) && stream.state.kind != lastKind)
            {
                lastKind = stream.state.kind;
                PS5Coordinator.StateChanged(stream.state);
            }
            if (e.PropertyName is nameof(PS5Stream.fps) or nameof(PS5Stream.videoSize)) RefreshToolbar();
            else Refresh();
        });
        Refresh();
    }

    Brush StatusColor => stream.state.kind switch
    {
        PS5Stream.StateKind.streaming => Brushes.LimeGreen,
        PS5Stream.StateKind.failed => Ui.Danger,
        PS5Stream.StateKind.idle => Ui.Secondary,
        _ => Ui.Orange,
    };

    void RefreshToolbar()
    {
        var s = AppSettings.shared;
        var left = Ui.H(10, SourceTab.SourcePicker());
        if (stream.host is not PS5Host host) { toolbarSlot.Content = left; return; }
        left.Children.Add(Ui.H(8, Ui.Dot(StatusColor),
            Ui.V(1, Ui.Text(host.nickname, bold: true, wrap: false),
                Ui.Caption(stream.isStreaming ? $"{stream.videoSize.w}×{stream.videoSize.h} · {stream.fps} fps" : stream.state.label))).Also(x => x.Margin = new Thickness(10, 0, 0, 0)));
        var right = new System.Collections.Generic.List<UIElement>();
        if (stream.state.kind == PS5Stream.StateKind.needsPin)
        {
            var pin = new PasswordBox { Width = 150, ToolTip = "Mã PIN đăng nhập PS5" };
            right.Add(pin);
            right.Add(Ui.Btn("Gửi", () => { stream.SendPin(pin.Password); pin.Password = ""; }));
        }
        drawToggle.IsEnabled = stream.isStreaming;
        right.Add(drawToggle);
        // Menu chất lượng
        var menuBtn = Ui.IconBtn("", () => { }, "Chất lượng hình có hiệu lực ở lần kết nối sau");
        var menu = new ContextMenu();
        MenuItem Check(string text, bool on, Action a) { var m = new MenuItem { Header = text, IsCheckable = true, IsChecked = on }; m.Click += (_, _) => a(); return m; }
        menu.Items.Add(Check("1080p (chữ nét nhất)", s.ps5Resolution == 4, () => s.ps5Resolution = 4));
        menu.Items.Add(Check("720p (nhẹ hơn)", s.ps5Resolution == 3, () => s.ps5Resolution = 3));
        menu.Items.Add(new Separator());
        menu.Items.Add(Check("30 fps", s.ps5FPS == 30, () => s.ps5FPS = 30));
        menu.Items.Add(Check("60 fps", s.ps5FPS == 60, () => s.ps5FPS = 60));
        menu.Items.Add(new Separator());
        menu.Items.Add(Check("Tự bắt đầu dịch khi có hình", s.ps5AutoTranslate, () => s.ps5AutoTranslate = !s.ps5AutoTranslate));
        menu.Items.Add(new Separator());
        var forget = new MenuItem { Header = "Quên máy này…" };
        forget.Click += (_, _) => { if (Ui.Confirm($"Quên máy {host.nickname}? Phải đăng ký lại để dùng.")) { stream.Disconnect(); stream.SetHost(null); } };
        menu.Items.Add(forget);
        menuBtn.Click += (_, _) => { menu.PlacementTarget = menuBtn; menu.IsOpen = true; };
        right.Add(menuBtn);
        right.Add(stream.state.isBusy ? Ui.Btn("Ngắt", stream.Disconnect) : Ui.Btn(Ui.IconLabel("", "Kết nối"), PS5Coordinator.Connect, primary: true));
        toolbarSlot.Content = Ui.Row(left, right.ToArray());
    }

    public void Refresh()
    {
        RefreshToolbar();
        if (stream.host == null)
        {
            if (body.Content is not PS5SetupView) body.Content = new PS5SetupView();
            return;
        }
        var sub = AppSettings.shared.regions.FirstOrDefault(r => r.embedded && r.kind == RegionKind.subtitle);
        screen.SetLive(stream.isStreaming);
        screen.SetSubtitle(sub?.rect);
        var dim = new SolidColorBrush(Color.FromArgb(190, 255, 255, 255));
        screen.Placeholder = Ui.V(8, Ui.Icon("", 42, new SolidColorBrush(Color.FromArgb(128, 255, 255, 255))),
            Ui.Text(stream.state.kind == PS5Stream.StateKind.idle ? "Bấm Kết nối để lấy hình từ PS5" : stream.state.label, color: dim).Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 520; }),
            Ui.Caption("App chỉ nhận hình để dịch. Bạn điều khiển bằng tay cầm nối thẳng với PS5.", new SolidColorBrush(Color.FromArgb(115, 255, 255, 255))))
            .Also(x => { foreach (FrameworkElement c in x.Children) c.HorizontalAlignment = HorizontalAlignment.Center; });
        if (body.Content is not DockPanel)
        {
            var d = new DockPanel();
            SetDock(strip, Dock.Bottom);
            d.Children.Add(strip);
            d.Children.Add(screen);
            body.Content = d;
        }
        strip.Refresh();
    }
}

/// Chưa có máy: nhập từ chiaki-ng hoặc đăng ký mới bằng mã PIN.
public sealed class PS5SetupView : ScrollViewer
{
    readonly TextBox ip = new(), account = new(), pin = new(), pasted = new();
    readonly StackPanel foundList = Ui.V(2);
    readonly TextBlock message = Ui.Text("", color: Ui.Danger);
    readonly TextBlock psnMessage = Ui.Caption("");
    readonly TextBlock registMsg = Ui.Caption("");
    readonly Button searchBtn, fetchBtn, registBtn;

    public PS5SetupView()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        var stream = PS5Stream.shared;
        searchBtn = Ui.Btn("Tìm trong mạng", Search);
        fetchBtn = Ui.Btn("Lấy Account ID", FetchAccountID);
        registBtn = Ui.Btn("Đăng ký", Register);
        stream.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            registBtn.Content = stream.registering ? "Đang đăng ký…" : "Đăng ký";
            registBtn.IsEnabled = !stream.registering;
            registMsg.Text = stream.registMessage;
        });
        TextBox Hint(TextBox tb, string hint) { tb.ToolTip = hint; tb.Tag = hint; return tb; }
        Hint(ip, "Địa chỉ IP của PS5 (ví dụ 192.168.1.20)");
        Hint(account, "PSN Account ID (dạng base64, 12 ký tự, ví dụ AbCdEfGhIjk=)");
        Hint(pin, "Mã PIN 8 số trên PS5");
        Hint(pasted, "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=…");

        var native = ChiakiNative.Available ? null : Ui.Card(Ui.H(8, Ui.Icon("", 16, Ui.Orange), Ui.Text(ChiakiNative.LoadError ?? "Thiếu st_chiaki.dll", color: Ui.Orange)), 10);

        var way1 = Ui.Section("Cách 1 – Dùng lại máy đã đăng ký trong chiaki-ng",
            Ui.Row(Ui.Text("Nếu bạn đã đăng ký PS5 trong chiaki-ng trên máy này, app lấy lại khoá đăng ký đó, không cần mã PIN.", color: Ui.Secondary),
                   Ui.Btn("Nhập từ chiaki-ng", () => message.Text = stream.ImportFromChiaki() ? "" : "Không thấy máy nào đã đăng ký trong chiaki-ng.", primary: true)));

        UIElement Field(string label, TextBox tb, params UIElement[] right) => Ui.V(3, Ui.Caption(label), right.Length == 0 ? tb : Ui.Row(tb, right));
        var psnBox = Ui.Card(Ui.V(6,
            Ui.Text("Chưa có PSN Account ID? Lấy bằng cách đăng nhập PSN:", bold: true),
            Ui.H(6, Ui.Text("1."), Ui.LinkBtn("Mở trang đăng nhập PSN", () => App.OpenUrl(PSNAccount.LoginURL)), Ui.Text("rồi đăng nhập tài khoản của bạn trên trang của Sony.", color: Ui.Secondary)),
            Ui.Text("2. Khi trang chuyển sang địa chỉ có chữ “redirect” (trang trắng hoặc báo lỗi cũng được), copy toàn bộ địa chỉ trên thanh URL và dán vào đây:", color: Ui.Secondary),
            Ui.Row(pasted, Ui.Btn("Dán", () => { try { pasted.Text = Clipboard.GetText(); } catch { } }), fetchBtn),
            psnMessage,
            Ui.Caption("App chỉ gửi mã trong URL tới máy chủ của Sony để đổi lấy số tài khoản. Mật khẩu của bạn chỉ nhập trên trang của Sony, app không thấy và không lưu token.")), 10);

        var way2 = Ui.Section("Cách 2 – Đăng ký mới",
            Field("Địa chỉ IP của PS5 (ví dụ 192.168.1.20)", ip, searchBtn),
            foundList,
            Field("PSN Account ID (dạng base64, 12 ký tự, ví dụ AbCdEfGhIjk=)", account),
            psnBox,
            Field("Mã PIN 8 số trên PS5", pin),
            Ui.Caption("Trên PS5: Settings → System → Remote Play → bật Enable Remote Play → Link Device để lấy mã PIN. PSN Account ID không phải tên đăng nhập; chiaki-ng có nút lấy mã này bằng cách đăng nhập PSN."),
            Ui.H(10, registBtn, registMsg));

        var header = Ui.H(10, Ui.Icon("", 28, Ui.AccentStart),
            Ui.V(2, Ui.Text("Lấy hình PS5 ngay trong app", 17, true),
                Ui.Text("App kết nối Remote Play để nhận hình và dịch phụ đề. Không gửi điều khiển, không phát tiếng: bạn vẫn chơi bằng tay cầm nối thẳng với PS5.", color: Ui.Secondary).Also(t => t.MaxWidth = 620)));
        var v = Ui.V(16, header, native, way1, way2, message);
        v.Margin = new Thickness(24);
        v.MaxWidth = 760;
        v.HorizontalAlignment = HorizontalAlignment.Left;
        Content = v;
    }

    void Search()
    {
        searchBtn.IsEnabled = false; searchBtn.Content = "Đang tìm…";
        Task.Run(() =>
        {
            var r = PS5Stream.Discover(PS5Stream.BroadcastAddresses());
            Dispatcher.BeginInvoke(() =>
            {
                searchBtn.IsEnabled = true; searchBtn.Content = "Tìm trong mạng";
                foundList.Children.Clear();
                foreach (var f in r) foundList.Children.Add(Ui.LinkBtn($"{f.name} – {f.addr} ({f.stateLabel})", () => ip.Text = f.addr));
                message.Text = r.Count == 0 ? (ChiakiNative.Available ? "Không thấy PS5 nào trả lời. Kiểm tra PS5 đã bật và cùng mạng." : ChiakiNative.LoadError ?? "") : "";
                if (ip.Text.Length == 0 && r.FirstOrDefault() is { } first) ip.Text = first.addr;
            });
        });
    }

    async void FetchAccountID()
    {
        fetchBtn.IsEnabled = false; fetchBtn.Content = "Đang lấy…";
        psnMessage.Text = "";
        try
        {
            var id = await PSNAccount.AccountID(pasted.Text);
            account.Text = id;
            psnMessage.Text = "Đã lấy được Account ID và điền vào ô phía trên.";
            psnMessage.Foreground = Brushes.Green;
            pasted.Text = "";
            Log.Info("PSN: đã lấy Account ID");
        }
        catch (Exception e)
        {
            psnMessage.Text = e.Message;
            psnMessage.Foreground = Ui.Danger;
            Log.Warn($"PSN: lấy Account ID lỗi: {e.Message}");
        }
        fetchBtn.IsEnabled = true; fetchBtn.Content = "Lấy Account ID";
    }

    void Register()
    {
        if (PS5Store.AccountID(account.Text) is not byte[] acc) { message.Text = "PSN Account ID không đúng dạng (cần base64 của 8 byte)."; return; }
        var digits = new string(pin.Text.Where(char.IsDigit).ToArray());
        if (digits.Length != 8 || !uint.TryParse(digits, out var p)) { message.Text = "Mã PIN phải gồm 8 chữ số."; return; }
        if (ip.Text.Trim().Length == 0) { message.Text = "Nhập địa chỉ IP của PS5."; return; }
        message.Text = "";
        PS5Stream.shared.Register(ip.Text.Trim(), acc, p);
    }
}
