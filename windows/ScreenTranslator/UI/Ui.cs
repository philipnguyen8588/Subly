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

    public static Button Btn(object content, Action onClick, bool primary = false, string? tip = null)
    {
        var b = new Button { Content = content is string s ? s : content };
        if (primary) b.Style = (Style)Application.Current.FindResource("GradientButton");
        b.Click += (_, _) => onClick();
        if (tip != null) b.ToolTip = tip;
        return b;
    }

    public static Button IconBtn(string glyph, Action onClick, string? tip = null) =>
        Btn(Icon(glyph, 14), onClick, tip: tip);

    public static Button LinkBtn(string text, Action onClick) =>
        new Func<Button>(() => { var b = new Button { Content = Text(text, color: AccentStart), Style = (Style)Application.Current.FindResource("LinkButton") }; b.Click += (_, _) => onClick(); return b; })();

    public static object IconLabel(string glyph, string text) => H(6, Icon(glyph, 13), Text(text, wrap: false));

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
        minus.Padding = plus.Padding = new Thickness(9, 1, 9, 1);
        return Row(t, minus, plus);
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
