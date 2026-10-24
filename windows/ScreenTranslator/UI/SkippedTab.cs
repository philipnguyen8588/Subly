using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace ScreenTranslator;

/// Tab "Bị bỏ qua": chữ OCR đọc được nhưng không dịch, không đọc (menu, mẩu lạc, cảm thán, chữ mờ…) của game đang chơi,
/// mới nhất ở trên. Dùng để xem lại bộ lọc có bỏ nhầm câu thoại không.
public sealed class SkippedTab : DockPanel
{
    readonly SkipLog log = SkipLog.shared;
    readonly StackPanel seg = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBox searchBox = new() { MinWidth = 120, MaxWidth = 220, Width = 200, BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalContentAlignment = VerticalAlignment.Center };
    readonly Button clearBtn;
    readonly ListBox list = new();
    readonly ContentControl empty = new();
    string query = "";
    /// Có thay đổi khi tab đang ẩn → dựng lại khi hiện.
    bool dirty;

    static string Profile => HistoryStore.ProfileKey(AppSettings.shared.activeProfile.id);
    /// "" = tất cả loại; lưu lại giữa các lần mở app.
    static string KindRaw
    {
        get => AppSettings.shared.Get("skippedKind", "");
        set => AppSettings.shared.Set("skippedKind", value, "skippedKind");
    }

    public SkippedTab()
    {
        LastChildFill = true;
        Background = Brushes.White;
        Ui.OnSearch(searchBox, () => { if (query == searchBox.Text) return; query = searchBox.Text; Refresh(); }, 300);
        var searchRow = new Border
        {
            Height = 36, CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 0, 10, 0), Background = Brushes.White,
            BorderBrush = Ui.Hex("#1F000000"), BorderThickness = new Thickness(1),
            Child = Ui.H(6, Ui.Icon("", 13, Ui.Tertiary), searchBox),
            ToolTip = "Tìm chữ bị bỏ qua",
        };
        clearBtn = Ui.IconBtn("", ConfirmClear, "Xoá danh sách bị bỏ qua của game này");
        var right = Ui.H(8, searchRow, clearBtn);
        right.VerticalAlignment = VerticalAlignment.Center;
        var barRow = new DockPanel { LastChildFill = true };
        SetDock(right, Dock.Right);
        barRow.Children.Add(right);
        barRow.Children.Add(seg);
        var bar = new Border { Height = 52, Padding = new Thickness(14, 0, 14, 0), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(0, 0, 0, 1), Child = barRow };
        SetDock(bar, Dock.Top);
        Children.Add(bar);

        // Danh sách ảo hoá: chỉ dựng các dòng đang nhìn thấy (tối đa SkipLog.MaxEntries mục).
        list.BorderThickness = new Thickness(0);
        list.Background = Brushes.White;
        list.Padding = new Thickness(0);
        list.Focusable = false;
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        ScrollViewer.SetCanContentScroll(list, true);
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
        VirtualizingPanel.SetScrollUnit(list, ScrollUnit.Pixel);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        var itemStyle = new Style(typeof(ListBoxItem));
        itemStyle.Setters.Add(new Setter(Control.TemplateProperty, new ControlTemplate(typeof(ListBoxItem)) { VisualTree = presenter }));
        itemStyle.Setters.Add(new Setter(UIElement.FocusableProperty, false));
        itemStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        list.ItemContainerStyle = itemStyle;
        list.ItemTemplate = new DataTemplate(typeof(SkipEntry)) { VisualTree = new FrameworkElementFactory(typeof(SkippedRow)) };
        var body = new Grid();
        body.Children.Add(list);
        body.Children.Add(empty);
        Children.Add(body);

        log.Changed += () => Dispatcher.BeginInvoke(Refresh);
        AppSettings.shared.Changed += k => { if (k is "activeProfileID" or "activeProfile") Dispatcher.BeginInvoke(Refresh); };
        IsVisibleChanged += (_, _) => { if (IsVisible && dirty) Refresh(); };
        Refresh();
    }

    void ConfirmClear()
    {
        if (!Ui.Confirm($"Xoá danh sách bị bỏ qua của game “{AppSettings.shared.activeProfile.name}”?")) return;
        log.Clear(Profile);
    }

    void Refresh()
    {
        if (!IsVisible && IsLoaded) { dirty = true; return; }
        dirty = false;
        var profile = Profile;
        var mine = log.entries.Where(e => e.profile == profile).ToList();
        var kind = KindRaw;
        if (kind.Length > 0 && !Enum.TryParse<SkipKind>(kind, out _)) kind = "";
        BuildBar(mine, kind);
        clearBtn.IsEnabled = mine.Count > 0;
        var q = query.Trim();
        var shown = new List<SkipEntry>(mine.Count);
        for (int i = mine.Count - 1; i >= 0; i--)
        {
            var e = mine[i];
            if (kind.Length > 0 && e.kind.ToString() != kind) continue;
            if (q.Length > 0 && !e.text.Contains(q, StringComparison.CurrentCultureIgnoreCase) && !e.reason.Contains(q, StringComparison.CurrentCultureIgnoreCase)) continue;
            shown.Add(e);
        }
        list.ItemsSource = shown;
        if (shown.Count == 0)
        {
            var v = Ui.V(8,
                Ui.Icon("", 28, Ui.Tertiary),
                Ui.Text(mine.Count == 0 ? "Chưa có chữ nào bị bỏ qua" : "Không có mục nào khớp", 15, true, Ui.Secondary),
                Ui.Text("Chữ OCR đọc được nhưng không dịch (menu, mẩu chữ lạc, cảm thán, chữ mờ…) sẽ hiện ở đây.", 13, color: Ui.Tertiary)
                    .Also(t => t.TextAlignment = TextAlignment.Center));
            foreach (FrameworkElement c in v.Children) c.HorizontalAlignment = HorizontalAlignment.Center;
            v.HorizontalAlignment = HorizontalAlignment.Center; v.VerticalAlignment = VerticalAlignment.Center;
            v.MaxWidth = 520;
            empty.Content = v;
            empty.Visibility = Visibility.Visible;
            list.Visibility = Visibility.Collapsed;
        }
        else
        {
            empty.Content = null;
            empty.Visibility = Visibility.Collapsed;
            list.Visibility = Visibility.Visible;
        }
    }

    void BuildBar(List<SkipEntry> mine, string kind)
    {
        seg.Children.Clear();
        var items = new List<(string key, string title)> { ("", $"Tất cả  {mine.Count}") };
        foreach (var k in SkipKindInfo.All)
        {
            int n = mine.Count(e => e.kind == k);
            items.Add((k.ToString(), n == 0 ? k.Title() : $"{k.Title()}  {n}"));
        }
        foreach (var (key, title) in items)
        {
            var rb = new RadioButton { Content = title, GroupName = "skippedKind", IsChecked = key == kind,
                Style = (Style)Application.Current.FindResource(typeof(ToggleButton)) };
            if (key.Length > 0 && Enum.TryParse<SkipKind>(key, out var sk)) rb.ToolTip = sk.Help();
            var k = key;
            rb.Checked += (_, _) => { if (KindRaw == k) return; KindRaw = k; Dispatcher.BeginInvoke(Refresh); };
            seg.Children.Add(rb);
        }
    }
}

/// Một dòng của tab "Bị bỏ qua" (dựng lại khi danh sách ảo hoá dùng lại dòng cho mục khác).
public sealed class SkippedRow : Border
{
    public SkippedRow()
    {
        Margin = new Thickness(14, 0, 0, 0);
        Padding = new Thickness(0, 8, 14, 8);
        BorderBrush = Ui.Res("CardStroke");
        BorderThickness = new Thickness(0, 0, 0, 1);
        Background = Brushes.Transparent;
        DataContextChanged += (_, _) => Build();
    }

    static Brush KindColor(SkipKind k) => k switch
    {
        SkipKind.ui => Ui.AccentStart,
        SkipKind.stray => Ui.Orange,
        SkipKind.interjection => Ui.Hex("#FFE8457A"),
        SkipKind.simple => Ui.Res("AccentEnd"),
        SkipKind.junk => Ui.Secondary,
        _ => Ui.Hex("#FF9B59D0"),
    };

    void Build()
    {
        if (DataContext is not SkipEntry e) { Child = null; return; }
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(92) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(88) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var t = e.Time;
        var time = Ui.Text(t.ToString(t.Date == DateTime.Today ? "HH:mm:ss" : "dd/MM HH:mm:ss"), 11, color: Ui.Tertiary, wrap: false);
        time.VerticalAlignment = VerticalAlignment.Top; time.Margin = new Thickness(0, 2, 0, 0);
        System.Windows.Documents.Typography.SetNumeralAlignment(time, FontNumeralAlignment.Tabular);
        var color = KindColor(e.kind);
        var c = ((SolidColorBrush)color).Color;
        var pill = new Border
        {
            CornerRadius = new CornerRadius(9), Padding = new Thickness(6, 1, 6, 2), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Color.FromArgb(36, c.R, c.G, c.B)), MaxWidth = 78,
            Child = Ui.Text(e.kind.Title(), 11, true, color, wrap: false), ToolTip = e.kind.Help(),
        };
        var menu = new ContextMenu();
        var copy = new MenuItem { Header = "Sao chép chữ", Icon = Ui.Icon("", 13) };
        copy.Click += (_, _) => Ui.CopyText(e.text);
        menu.Items.Add(copy);
        var text = new TextBox
        {
            Text = e.text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = 13, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Padding = new Thickness(0), Margin = new Thickness(-2, 0, 0, 0), ContextMenu = menu,
        };
        var parts = new List<UIElement> { text };
        var caption = string.Join(" · ", new[] { e.region, e.reason }.Where(s => !string.IsNullOrEmpty(s)));
        if (caption.Length > 0) parts.Add(Ui.Text(caption, 11.5, color: Ui.Secondary));
        var right = Ui.V(3, parts.ToArray());
        Grid.SetColumn(pill, 1); Grid.SetColumn(right, 2);
        g.Children.Add(time); g.Children.Add(pill); g.Children.Add(right);
        ContextMenu = menu;
        Child = g;
    }
}

