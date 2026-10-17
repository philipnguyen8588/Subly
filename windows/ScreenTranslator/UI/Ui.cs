using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;

namespace ScreenTranslator;

/// Bộ dựng giao diện WPF bằng code (thay SwiftUI): thẻ, hàng, nút, công tắc, thanh trượt gắn với cài đặt.
public static class Ui
{
    public static Brush Res(string key) => (Brush)Application.Current.FindResource(key);
    public static Brush AccentStart => Res("AccentStart");
    public static Brush AccentGradient => Res("AccentGradient");
    public static Brush Secondary => Res("Secondary");
    public static Brush Tertiary => Res("Tertiary");
    public static Brush Danger => Res("Danger");
    public static Brush Gemini => Res("Gemini");
    public static Brush Orange => Res("Apple");
    public static Brush Hex(string hex) => (SolidColorBrush)new BrushConverter().ConvertFromString(hex)!;

    public static TextBlock Text(string s, double size = 13, bool bold = false, Brush? color = null, bool wrap = true, FontWeight? weight = null)
    {
        var t = new TextBlock
        {
            Text = s, FontSize = size, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            FontWeight = weight ?? (bold ? FontWeights.SemiBold : FontWeights.Normal),
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
        };
        if (color != null) t.Foreground = color;
        return t;
    }

    public static TextBlock Caption(string s, Brush? color = null) => Text(s, 11.5, color: color ?? Secondary);

    /// Dòng "app miễn phí" + 2 link Telegram bấm được (khớp bản macOS).
    public static TextBlock SupportText(double size = 13)
    {
        var tb = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = size, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        tb.Inlines.Add("Đây là app ");
        tb.Inlines.Add(new Run("miễn phí") { FontWeight = FontWeights.Bold });
        tb.Inlines.Add(". Cần hỗ trợ cài đặt, liên hệ Telegram ");
        tb.Inlines.Add(TgLink(AppInfo.TelegramGroup));
        tb.Inlines.Add(".");
        return tb;
    }

    static Hyperlink TgLink(string handle)
    {
        var link = new Hyperlink(new Run("@" + handle))
        {
            NavigateUri = new Uri("https://t.me/" + handle),
            Foreground = AccentStart, Cursor = System.Windows.Input.Cursors.Hand,
        };
        link.RequestNavigate += (_, e) => App.OpenUrl(e.Uri.AbsoluteUri);
        return link;
    }

    static Color AccentColor => ((SolidColorBrush)AccentStart).Color;

    /// Dải hỗ trợ nổi bật dưới header cửa sổ chính (hiện ở mọi bản).
    public static Border SupportBanner()
    {
        var gift = Icon("", 12, AccentStart);
        gift.Margin = new Thickness(0, 0, 7, 0);
        DockPanel.SetDock(gift, Dock.Left);
        var row = new DockPanel { LastChildFill = true };
        row.Children.Add(gift);
        row.Children.Add(SupportText());
        return new Border
        {
            Padding = new Thickness(14, 6, 14, 6),
            Background = new SolidColorBrush(AccentColor) { Opacity = 0.12 },
            BorderThickness = new Thickness(0, 0, 0, 1),
            BorderBrush = new SolidColorBrush(AccentColor) { Opacity = 0.25 },
            Child = row,
        };
    }

    /// Hộp "app miễn phí" nổi bật (dùng trong màn hỏi email).
    public static Border SupportBox()
    {
        return new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14, 10, 14, 10),
            MaxWidth = 400,
            Background = new SolidColorBrush(AccentColor) { Opacity = 0.12 },
            BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(AccentColor) { Opacity = 0.3 },
            Child = SupportText().Also(t => t.TextAlignment = TextAlignment.Center),
        };
    }

    public static TextBlock Styled(string s, double size, bool onDark = false, FontWeight? weight = null, Brush? color = null)
    {
        var t = new TextBlock { FontSize = size, TextWrapping = TextWrapping.Wrap };
        t.Inlines.AddRange(SpeakerColors.Styled(s, onDark, weight));
        if (color != null) t.Foreground = color;
        return t;
    }

    /// Icon chữ (Segoe MDL2 / Fluent Icons).
    public static TextBlock Icon(string glyph, double size = 14, Brush? color = null)
    {
        var t = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = size, VerticalAlignment = VerticalAlignment.Center };
        if (color != null) t.Foreground = color;
        return t;
    }

    public static StackPanel H(double spacing, params UIElement?[] children) => Stack(Orientation.Horizontal, spacing, children);
    public static StackPanel V(double spacing, params UIElement?[] children) => Stack(Orientation.Vertical, spacing, children);

    /// Tách phần tử khỏi cha cũ để dùng lại khi dựng lại giao diện (WPF chỉ cho một cha).
    public static T Detach<T>(T e) where T : UIElement
    {
        switch (LogicalTreeHelper.GetParent(e) ?? System.Windows.Media.VisualTreeHelper.GetParent(e))
        {
            case Panel p: p.Children.Remove(e); break;
            case ContentControl cc when cc.Content == e: cc.Content = null; break;
            case Decorator d when d.Child == e: d.Child = null; break;
            case ContentPresenter cp when cp.Content == e: cp.Content = null; break;
        }
        return e;
    }

    /// Khoảng cách giữa các phần tử là một ô trống riêng, không sửa Margin của phần tử (dựng lại nhiều lần không bị cộng dồn).
    static StackPanel Stack(Orientation o, double spacing, UIElement?[] children)
    {
        var p = new StackPanel { Orientation = o };
        bool first = true;
        foreach (var c in children)
        {
            if (c == null) continue;
            if (!first && spacing > 0)
                p.Children.Add(o == Orientation.Horizontal ? new Border { Width = spacing } : new Border { Height = spacing });
            p.Children.Add(Detach(c));
            if (o == Orientation.Horizontal && c is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
            first = false;
        }
        return p;
    }

    /// Hàng ngang có phần giữa giãn ra (như HStack + Spacer).
    public static DockPanel Row(UIElement left, params UIElement[] right)
    {
        var d = new DockPanel { LastChildFill = true };
        var r = H(8, right);
        DockPanel.SetDock(r, Dock.Right);
        d.Children.Add(r);
        d.Children.Add(Detach(left));
        return d;
    }

    public static Border Card(UIElement child, double padding = 14) => new()
    {
        Child = child, Padding = new Thickness(padding), CornerRadius = new CornerRadius(12),
        Background = Brushes.White, BorderBrush = Res("CardStroke"), BorderThickness = new Thickness(1),
        Margin = new Thickness(0, 0, 0, 12),
    };

    /// Nhóm trong trang cài đặt (tiêu đề + thẻ).
    public static UIElement Section(string title, params UIElement?[] rows)
    {
        var v = V(8, rows);
        return V(6, Text(title.ToUpperInvariant(), 11, bold: true, color: Secondary), Card(v, 14));
    }

    /// Kiểu nút chung (giống AppButtonStyle bản macOS).
    public enum Kind { secondary, primary, tinted, danger, ghost }

    /// Nút chuẩn của app: cao 36 (44 nếu `large`), bo góc 10, chữ SemiBold. Nút chỉ có biểu tượng thì vuông 36×36.
    public static Button Btn(object content, Action onClick, bool primary = false, string? tip = null, Kind? kind = null, bool large = false, double minWidth = 0)
    {
        var k = kind ?? (primary ? Kind.primary : Kind.secondary);
        var b = new Button
        {
            Content = content is string s ? s : content,
            Style = (Style)Application.Current.FindResource(k switch
            {
                Kind.primary => "AppButtonPrimary", Kind.tinted => "AppButtonTinted", Kind.danger => "AppButtonDanger",
                Kind.ghost => "AppButtonGhost", _ => "AppButtonSecondary",
            }),
            Height = large ? 44 : 36,
            FontSize = large ? 15 : 13,
        };
        if (minWidth > 0) b.MinWidth = minWidth;
        b.Click += (_, _) => onClick();
        if (tip != null) b.ToolTip = tip;
        return b;
    }

    /// Nút chỉ có biểu tượng: vuông 36×36, cùng kiểu với nút chữ.
    public static Button IconBtn(string glyph, Action onClick, string? tip = null, Kind kind = Kind.secondary) =>
        Btn(Icon(glyph, 15), onClick, tip: tip, kind: kind).Also(b => { b.Width = 36; b.Padding = new Thickness(0); });

    /// Nút biểu tượng nhỏ trong một dòng danh sách (copy, xoá…): không viền, không chiếm chiều cao của dòng.
    public static Button InlineIconBtn(string glyph, Action onClick, string? tip = null) =>
        Btn(Icon(glyph, 13), onClick, tip: tip, kind: Kind.ghost).Also(b => { b.Height = 26; b.Width = 26; b.Padding = new Thickness(0); });

    /// Toggle biểu tượng 36×36 (bật = nền gradient).
    public static ToggleButton IconToggle(string glyph, string? tip = null) =>
        new() { Content = Icon(glyph, 15), Style = (Style)Application.Current.FindResource("AppIconToggle"), ToolTip = tip };

    public static Button LinkBtn(string text, Action onClick) =>
        new Func<Button>(() => { var b = new Button { Content = Text(text, color: AccentStart), Style = (Style)Application.Current.FindResource("LinkButton") }; b.Click += (_, _) => onClick(); return b; })();

    public static object IconLabel(string glyph, string text) => H(7, Icon(glyph, 14), Text(text, wrap: false).Also(t => t.FontWeight = FontWeights.SemiBold));

    /// Công tắc gắn với cài đặt.
    public static CheckBox Toggle(string label, Func<bool> get, Action<bool> set, string? tip = null)
    {
        var c = new CheckBox { Content = Text(label), IsChecked = get() };
        c.Checked += (_, _) => { if (get() != true) set(true); };
        c.Unchecked += (_, _) => { if (get() != false) set(false); };
        if (tip != null) c.ToolTip = tip;
        return c;
    }

    /// Thanh trượt gắn với cài đặt, kèm nhãn giá trị.
    public static UIElement Slider(string label, double min, double max, double step, Func<double> get, Action<double> set, Func<double, string> fmt)
    {
        var val = Text(fmt(get()), wrap: false);
        val.MinWidth = 56; val.TextAlignment = TextAlignment.Right;
        var s = new Slider { Minimum = min, Maximum = max, Value = get(), TickFrequency = step, IsSnapToTickEnabled = step > 0, MinWidth = 160, VerticalAlignment = VerticalAlignment.Center };
        s.ValueChanged += (_, e) => { set(e.NewValue); val.Text = fmt(e.NewValue); };
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = Text(label); l.Margin = new Thickness(0, 0, 10, 0); l.MaxWidth = 300;
        Grid.SetColumn(l, 0); Grid.SetColumn(s, 1); Grid.SetColumn(val, 2);
        g.Children.Add(l); g.Children.Add(s); g.Children.Add(val);
        return g;
    }

    /// Hộp chọn gắn với cài đặt.
    public static UIElement Picker<T>(string label, IEnumerable<(T value, string text)> items, Func<T> get, Action<T> set, double width = 260)
    {
        var cb = new ComboBox { MinWidth = width };
        var list = items.ToList();
        foreach (var (v, t) in list) cb.Items.Add(new ComboBoxItem { Content = t, Tag = v });
        var cur = get();
        cb.SelectedIndex = list.FindIndex(x => EqualityComparer<T>.Default.Equals(x.value, cur));
        cb.SelectionChanged += (_, _) => { if (cb.SelectedItem is ComboBoxItem it && it.Tag is T v) set(v); };
        if (string.IsNullOrEmpty(label)) return cb;
        return Row(Text(label), cb);
    }

    public static UIElement Stepper(Func<string> label, int min, int max, int step, Func<int> get, Action<int> set)
    {
        var t = Text(label());
        var minus = Btn("−", () => { set(Math.Max(min, get() - step)); t.Text = label(); });
        var plus = Btn("+", () => { set(Math.Min(max, get() + step)); t.Text = label(); });
        minus.Width = plus.Width = 36; minus.Padding = plus.Padding = new Thickness(0);
        return Row(t, minus, plus);
    }

    /// Khối cài đặt nổi bật (giống SettingsBlock bản macOS): biểu tượng nền gradient, tiêu đề lớn, phụ đề nhỏ,
    /// phía phải tiêu đề là trạng thái / nút, bên dưới là nội dung.
    public static Border Block(string title, string glyph, string? subtitle, UIElement?[] trailing, params UIElement?[] content)
    {
        var tile = new Border
        {
            Width = 34, Height = 34, CornerRadius = new CornerRadius(9), Background = AccentGradient,
            Child = Icon(glyph, 16, Brushes.White).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
        };
        var titles = V(1, Text(title, 15, weight: FontWeights.Bold, wrap: false), subtitle == null ? null : Caption(subtitle));
        var head = Row(H(12, tile, titles), trailing.OfType<UIElement>().ToArray());
        var body = V(10, content);
        return new Border
        {
            Child = V(14, head, body), Padding = new Thickness(16), CornerRadius = new CornerRadius(14), Margin = new Thickness(0, 0, 0, 16),
            Background = Brushes.White, BorderBrush = Hex("#1F000000"), BorderThickness = new Thickness(1),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Opacity = 0.08, Direction = 270 },
        };
    }

    /// Hàng "nhãn — điều khiển" trong khối cài đặt; nhãn rộng cố định để các hàng thẳng cột.
    public static UIElement BlockRow(string label, params UIElement?[] controls)
    {
        var l = Text(label, color: Secondary, wrap: false);
        l.Width = 100;
        return H(10, new UIElement?[] { l }.Concat(controls).ToArray());
    }

    public enum Tone { ok, warn, idle }

    /// Nhãn trạng thái nhỏ: xanh = sẵn sàng, cam = còn thiếu, xám = không bắt buộc / chưa dùng.
    public static Border Chip(string text, Tone tone)
    {
        var color = tone switch { Tone.ok => Hex("#FF2E9E4F"), Tone.warn => Orange, _ => Secondary };
        var c = ((SolidColorBrush)color).Color;
        var glyph = tone switch { Tone.ok => "\uE73E", Tone.warn => "\uE7BA", _ => "\uE738" };
        return new Border
        {
            CornerRadius = new CornerRadius(12), Height = 24, Padding = new Thickness(9, 0, 9, 0), VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Color.FromArgb(30, c.R, c.G, c.B)),
            Child = H(5, Icon(glyph, 11, color), Text(text, 11.5, true, color, wrap: false)),
        };
    }

    public static Border Divider() => new() { Height = 1, Background = Res("CardStroke"), Margin = new Thickness(0, 4, 0, 4) };

    public static System.Windows.Shapes.Ellipse Dot(Brush color, double size = 8) => new() { Width = size, Height = size, Fill = color, VerticalAlignment = VerticalAlignment.Center };

    public static ScrollViewer Scroll(UIElement content) => new() { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

    /// Trạng thái rỗng: biểu tượng + tiêu đề + mô tả + các bước.
    public static UIElement EmptyState(string glyph, string title, string message, params string[] steps)
    {
        var v = V(10, Icon(glyph, 40, Tertiary), Text(title, 18, bold: true), Text(message, 13, color: Secondary));
        foreach (var (s, i) in steps.Select((s, i) => (s, i)))
            v.Children.Add(H(8, new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = AccentGradient, Child = Text($"{i + 1}", 11, true, Brushes.White).Also(x => x.HorizontalAlignment = HorizontalAlignment.Center) }, Text(s, color: Secondary)));
        foreach (FrameworkElement c in v.Children) c.HorizontalAlignment = HorizontalAlignment.Center;
        foreach (var t in v.Children.OfType<TextBlock>()) t.TextAlignment = TextAlignment.Center;
        v.MaxWidth = 520;
        v.HorizontalAlignment = HorizontalAlignment.Center;
        return v;
    }

    public static T Also<T>(this T x, Action<T> f) { f(x); return x; }

    /// Ô tìm: chỉ gọi `apply` sau khi ngừng gõ `ms` mili giây (gõ liên tục thì không tìm). Enter, hoặc chữ bị đặt lại
    /// từ code (ô không có focus, ví dụ nút xoá / đổi game) thì gọi ngay.
    public static void OnSearch(TextBox box, Action apply, int ms = 700)
    {
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
        timer.Tick += (_, _) => { timer.Stop(); apply(); };
        box.TextChanged += (_, _) =>
        {
            timer.Stop();
            if (box.IsKeyboardFocused && box.Text.Length > 0) timer.Start(); else apply();
        };
        box.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) { timer.Stop(); apply(); } };
    }

    public static void CopyText(string s) { try { Clipboard.SetText(s); } catch { } }

    /// Hộp nhập tên (thay NSAlert có ô nhập).
    public static string? Ask(string title, string message, string def, Window? owner = null)
    {
        var w = new Window
        {
            Title = title, Width = 420, SizeToContent = SizeToContent.Height, WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            ResizeMode = ResizeMode.NoResize, Owner = owner, ShowInTaskbar = owner == null, Background = Res("WindowBg"),
        };
        var tb = new TextBox { Text = def };
        string? result = null;
        var ok = Btn("OK", () => { result = tb.Text.Trim(); w.DialogResult = true; }, primary: true);
        ok.IsDefault = true;
        var cancel = Btn("Huỷ", () => w.DialogResult = false);
        cancel.IsCancel = true;
        var buttons = H(8, cancel, ok); buttons.HorizontalAlignment = HorizontalAlignment.Right;
        w.Content = new Border { Padding = new Thickness(18), Child = V(10, Text(title, 15, true), Text(message, color: Secondary), tb, buttons) };
        w.Loaded += (_, _) => { tb.Focus(); tb.SelectAll(); };
        return w.ShowDialog() == true ? (string.IsNullOrEmpty(result) ? def : result) : null;
    }

    public static bool Confirm(string message, string title = "Xác nhận") =>
        MessageBox.Show(message, title, MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK;
}
