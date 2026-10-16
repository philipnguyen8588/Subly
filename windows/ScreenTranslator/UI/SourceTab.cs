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
        Pipeline.shared.analyzer.PropertyChanged += (_, e) => { if (e.PropertyName is "lastError" or "isRunning") Dispatcher.BeginInvoke(Refresh); };
        Refresh();
    }

    public void Refresh()
    {
        var p = Pipeline.shared;
        var v = Ui.V(4);
        if (p.router.lastError is string e) v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(e, 11.5, color: Ui.Danger)));
        // Luồng chụp / nhận dạng chữ hỏng (ví dụ OCR treo) và lỗi của lần Dịch màn hình gần nhất.
        foreach (var we in p.workerErrors.Values.OfType<string>().OrderBy(x => x, StringComparer.Ordinal))
            v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(we, 11.5, color: Ui.Danger)));
        if (p.analyzer.lastError is string ae && !p.analyzer.isRunning)
            v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text($"Dịch màn hình: {ae}", 11.5, color: Ui.Danger)));
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

    public static Border Toolbar(UIElement content) => new()
    {
        Child = content, Height = 52, Padding = new Thickness(14, 0, 14, 0), Background = Brushes.White,
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
    readonly SubtitleStrip strip = new(() => "Bấm “Bắt đầu dịch” để dịch phụ đề.");
    readonly Popup windowsPopup = new() { StaysOpen = false, Placement = PlacementMode.Bottom, AllowsTransparency = true };
    readonly WindowListView windowList = new();
    readonly ExternalMirror mirror = ExternalMirror.shared;

    public ExternalSourceView()
    {
        LastChildFill = true;
        var tb = SourceTab.Toolbar(toolbarSlot);
        SetDock(tb, Dock.Top);
        Children.Add(tb);
        Children.Add(body);
        // App ngoài chỉ có một khung phụ đề: vẽ mới hay kéo / đổi cỡ đều đặt lại khung đó.
        screen.onDrawNew = RegionActions.SetExternalSubtitle;
        screen.onUpdate = (_, r) => RegionActions.SetExternalSubtitle(r);
        screen.onEditingEnded = () => drawToggle.IsChecked = false;
        drawToggle.Checked += (_, _) => screen.Editing = true;
        drawToggle.Unchecked += (_, _) => screen.Editing = false;
        mirror.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        windowList.onPicked = () => windowsPopup.IsOpen = false;
        windowsPopup.Child = new Border
        {
            Width = 400, Height = 440, Padding = new Thickness(14), CornerRadius = new CornerRadius(12), Background = Brushes.White,
            BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), Child = windowList,
        };
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
        // Thanh công cụ: chỉ còn công cụ khung (chọn nguồn / cửa sổ nằm ở màn hình Bắt đầu).
        var hint = Ui.Caption(mirror.error ?? "Kéo khung vàng tới đúng chỗ phụ đề hiện trên hình game.", mirror.error == null ? null : Ui.Danger);
        hint.TextWrapping = TextWrapping.NoWrap; hint.TextTrimming = TextTrimming.CharacterEllipsis;
        var change = Ui.Btn(Ui.IconLabel("\uE7F4", "Đổi cửa sổ"), () => { windowList.Reload(); windowsPopup.IsOpen = true; }, tip: "Chọn cửa sổ khác làm màn hình game, hoặc vẽ vùng thủ công");
        windowsPopup.PlacementTarget = change;
        if (area != null)
        {
            var cap = Ui.Btn(Ui.IconLabel("\uE722", mirror.capturing ? "Đang chụp…" : "Chụp lại hình"), () => mirror.Capture(AppSettings.shared.externalArea!),
                tip: "Chụp lại hình hiện tại của game để xem và đặt khung phụ đề. App không chụp liên tục để máy nhẹ." + (mirror.capturedAt is DateTime t ? $" Ảnh lúc {t:HH:mm:ss}." : ""), minWidth: 130);
            cap.IsEnabled = !mirror.capturing;
            drawToggle.IsEnabled = mirror.image != null;
            toolbarSlot.Content = Ui.Row(hint, cap, drawToggle, change);
        }
        else toolbarSlot.Content = Ui.Row(hint, change);

        // Nội dung
        if (area == null)
        {
            var v = Ui.EmptyState("\uE7F4", "Chưa chọn cửa sổ game", "Bấm “Đổi cửa sổ” ở trên để chọn cửa sổ đang chạy game hoặc phim trên máy này.");
            ((FrameworkElement)v).VerticalAlignment = VerticalAlignment.Center;
            body.Content = v;
            return;
        }
        screen.SetStill(mirror.image, mirror.imageSize);
        screen.SetFrames(SubtitleRect() is RectD sr && s.externalSubtitle is Region sub ? new[] { new EditableFrame(sub.id, sr, true, "Phụ đề") } : Array.Empty<EditableFrame>());
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
    readonly ToggleButton drawToggle = new()
    {
        Content = Ui.IconLabel("", "Thêm khu vực dịch"),
        ToolTip = "Bật rồi kéo chuột trên hình để thêm một khu vực dịch (chỉ dịch chữ trong khung, không lấy tên, bản dịch hiện ngay tại đó)",
    };
    readonly ContentControl toolbarSlot = new();
    readonly ContentControl body = new();
    readonly SubtitleStrip strip;
    readonly PS5Stream stream = PS5Stream.shared;

    public PS5SourceView()
    {
        strip = new SubtitleStrip(() => PS5Stream.shared.isStreaming ? "Bấm “Bắt đầu dịch” để dịch phụ đề." : " ");
        LastChildFill = true;
        var tb = SourceTab.Toolbar(toolbarSlot);
        SetDock(tb, Dock.Top);
        Children.Add(tb);
        Children.Add(body);
        screen.Hint = "Kéo chuột quanh vùng chữ muốn dịch thêm";
        screen.onDrawNew = r => PS5Coordinator.AddSubtitleRegion(r);
        screen.onUpdate = PS5Coordinator.UpdateSubtitleRect;
        screen.onSelectionChanged = _ => RefreshToolbar();
        screen.onEditingEnded = () => drawToggle.IsChecked = false;
        drawToggle.Checked += (_, _) => screen.Editing = true;
        drawToggle.Unchecked += (_, _) => screen.Editing = false;
        Pipeline.shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Pipeline.regionCaptions)) Dispatcher.BeginInvoke(PushCaptions); };
        // Trạng thái phiên (vào màn chính, tự kết nối lại…) do PS5Coordinator.Install theo dõi; view này chỉ vẽ lại.
        System.ComponentModel.PropertyChangedEventHandler onStream = (_, e) => Dispatcher.BeginInvoke(() =>
        {
            if (e.PropertyName is nameof(PS5Stream.fps) or nameof(PS5Stream.videoSize)) return;
            Refresh();
        });
        Loaded += (_, _) => { stream.PropertyChanged -= onStream; stream.PropertyChanged += onStream; };
        Unloaded += (_, _) => stream.PropertyChanged -= onStream;
        Refresh();
    }

    void RefreshToolbar()
    {
        var hint = Ui.Caption("Kéo khung vàng tới chỗ phụ đề hiện; thêm khu vực để dịch chữ ở chỗ khác trên màn hình.");
        hint.TextWrapping = TextWrapping.NoWrap; hint.TextTrimming = TextTrimming.CharacterEllipsis;
        if (stream.host is not PS5Host host) { toolbarSlot.Content = hint; return; }
        var right = new System.Collections.Generic.List<UIElement>();
        drawToggle.IsEnabled = stream.isStreaming;
        right.Add(drawToggle);
        // Khu vực dịch thêm đang chọn → cho xoá (không xoá được khung phụ đề chính).
        if (SubtitleRegions().FirstOrDefault(r => r.id == screen.Selection && r.extra) is Region selExtra)
            right.Add(Ui.Btn(Ui.IconLabel("\uE74D", "Xoá khu vực"), () => PS5Coordinator.RemoveSubtitleRegion(selExtra.id), tip: $"Xoá khu vực dịch “{selExtra.name}”"));
        right.Add(Ui.IconBtn("\uE946", () => new PS5ConfigWindow(host, Window.GetWindow(this)).ShowDialog(),
            "Xem cấu hình kết nối Remote Play (IP, MAC, account, khoá đăng ký)"));
        toolbarSlot.Content = Ui.Row(hint, right.ToArray());
    }

    public void Refresh()
    {
        RefreshToolbar();
        if (stream.host == null)
        {
            body.Content = Ui.EmptyState("\uE7FC", "Chưa có máy PS5", "Bấm Đổi game để quay về màn hình bắt đầu và thiết lập PS5.").Also(v => ((FrameworkElement)v).VerticalAlignment = VerticalAlignment.Center);
            return;
        }
        screen.SetLive(stream.isStreaming);
        screen.SetFrames(SubtitleRegions().Select(r => new EditableFrame(r.id, r.rect, !r.extra, r.extra ? r.name : "Phụ đề chính")).ToList());
        PushCaptions();
        var dim = new SolidColorBrush(Color.FromArgb(190, 255, 255, 255));
        screen.Placeholder = Ui.V(8, Ui.Icon("", 42, new SolidColorBrush(Color.FromArgb(128, 255, 255, 255))),
            Ui.Text(stream.state.kind == PS5Stream.StateKind.idle ? "Chưa kết nối PS5" : stream.state.label, color: dim).Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 520; }),
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

    static System.Collections.Generic.List<Region> SubtitleRegions() =>
        AppSettings.shared.regions.Where(r => r.embedded && r.kind == RegionKind.subtitle).ToList();

    /// Bản dịch của từng khu vực dịch thêm → vẽ ngay tại khung trên hình.
    void PushCaptions() =>
        screen.SetCaptions(Pipeline.shared.regionCaptions.ToDictionary(k => k.Key, k => k.Value.translated));
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
