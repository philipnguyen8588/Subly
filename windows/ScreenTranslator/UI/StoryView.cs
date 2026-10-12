using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ScreenTranslator;

/// Mục "Cốt truyện" của tab Nhật ký: cốt truyện của game đang chọn do app tự viết từ phụ đề: bài viết liền mạch,
/// dòng thời gian từng đoạn diễn biến và danh sách nhân vật. Tab Nhật ký giữ một thể hiện duy nhất (không dựng lại
/// mỗi khi có câu phụ đề mới), view tự vẽ lại khi cốt truyện hoặc trạng thái cập nhật đổi.
public sealed class StoryView : Border
{
    readonly HistoryStore store = HistoryStore.shared;
    readonly StoryTracker tracker = StoryTracker.shared;
    readonly AppSettings settings = AppSettings.shared;
    string search = "";
    /// Đoạn diễn biến người dùng đã bấm mở / đóng (mặc định: ba đoạn mới nhất mở).
    readonly HashSet<long> toggled = new();
    /// Mục đang thu gọn (bấm vào tiêu đề mục để mở / đóng).
    readonly HashSet<string> collapsed = new();
    /// Giữ một khung cuộn và chỉ thay nội dung, để vị trí đang đọc không nhảy về đầu mỗi lần trạng thái đổi.
    readonly ScrollViewer scroll = Ui.Scroll(new StackPanel());

    public StoryView()
    {
        Background = Brushes.White;
        Child = scroll;
        store.StoryChanged += () => Dispatcher.BeginInvoke(Refresh);
        tracker.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        settings.Changed += k => { if (k is "storyEnabled" or "storyIntervalMin") Dispatcher.BeginInvoke(Refresh); };
        IsVisibleChanged += (_, _) => { if (IsVisible) { tracker.RefreshPending(); Refresh(); } };
        Refresh();
    }

    public void SetSearch(string q)
    {
        if (q == search) return;
        search = q;
        Refresh();
    }

    static MenuItem Mi(string header, Action onClick, string? glyph = null)
    {
        var mi = new MenuItem { Header = header };
        if (glyph != null) mi.Icon = Ui.Icon(glyph, 12);
        mi.Click += (_, _) => onClick();
        return mi;
    }

    static string Stamp(DateTime t) => $"{t:HH:mm} {t:dd/MM}";

    void Refresh()
    {
        if (!IsVisible) return;
        var story = store.story;
        var narrative = story?.narrative ?? "";
        var q = search.ToLowerInvariant();
        var parts = store.storyParts.Where(p => q.Length == 0 || p.title.ToLowerInvariant().Contains(q) || p.summary.ToLowerInvariant().Contains(q)).ToList();
        var chars = (story?.characters ?? new()).Where(c => q.Length == 0 ||
            new[] { c.name, c.status, c.role, c.personality, c.background, c.relations }.Any(f => f.ToLowerInvariant().Contains(q))).ToList();
        bool hasContent = narrative.Length > 0 || store.storyParts.Count > 0 || (story?.characters.Count ?? 0) > 0;
        bool showNarrative = narrative.Length > 0 && (q.Length == 0 || narrative.ToLowerInvariant().Contains(q));

        var v = Ui.V(16, StatusCard(story));
        if (!hasContent) v.Children.Add(EmptyState());
        else
        {
            if (showNarrative)
                v.Children.Add(Section("narrative", "Cốt truyện đến hiện tại", "\uE736", Ui.IconBtn("\uE8C8", () => Ui.CopyText(narrative), "Copy"), () => new Border
                {
                    Padding = new Thickness(12), CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Color.FromArgb(16, 97, 111, 250)),
                    Child = ReadOnly(narrative, 14.5),
                }));
            if (parts.Count > 0)
            {
                bool PartOpen(int i) => (i < 3) != toggled.Contains(parts[i].id);
                bool allOpen = Enumerable.Range(0, parts.Count).All(PartOpen);
                var allBtn = Ui.LinkBtn(allOpen ? "Thu gọn tất cả" : "Mở tất cả", () =>
                {
                    // `toggled` ghi những đoạn đã đổi so với mặc định (ba đoạn mới nhất mở).
                    var all = store.storyParts;
                    toggled.Clear();
                    for (int i = 0; i < all.Count; i++) if ((i < 3) == allOpen) toggled.Add(all[i].id);
                    Refresh();
                });
                v.Children.Add(Section("parts", $"Diễn biến  {parts.Count}", "\uE8FD", allBtn, () =>
                {
                    var list = Ui.V(10);
                    for (int i = 0; i < parts.Count; i++) list.Children.Add(PartCard(parts[i], PartOpen(i) || q.Length > 0));
                    return list;
                }));
            }
            if (chars.Count > 0)
                v.Children.Add(Section("characters", $"Nhân vật  {chars.Count}", "\uE716", null, () =>
                {
                    var grid = new WrapPanel();
                    foreach (var c in chars) grid.Children.Add(CharacterCard(c));
                    return grid;
                }));
            if (q.Length > 0 && !showNarrative && chars.Count == 0 && parts.Count == 0)
                v.Children.Add(Ui.Text($"Không có gì trong cốt truyện khớp “{search}”.", color: Ui.Tertiary).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 30, 0, 0); }));
        }
        v.Margin = new Thickness(14);
        scroll.Content = v;
    }

    static TextBox ReadOnly(string text, double size) => new()
    {
        Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = size, BorderThickness = new Thickness(0),
        Background = Brushes.Transparent, Padding = new Thickness(0), Margin = new Thickness(-2, 0, 0, 0),
    };

    /// Một mục có tiêu đề bấm được để thu gọn / mở cả mục; `accessory` là nút riêng của mục, nằm bên phải tiêu đề.
    UIElement Section(string key, string title, string glyph, UIElement? accessory, Func<UIElement> content)
    {
        bool closed = collapsed.Contains(key);
        var head = new Button
        {
            Style = (Style)Application.Current.FindResource("LinkButton"), HorizontalAlignment = HorizontalAlignment.Left,
            ToolTip = closed ? "Mở mục này" : "Thu gọn mục này",
            Content = Ui.H(6, Ui.Icon(closed ? "\uE76C" : "\uE70D", 9, Ui.Secondary), Ui.Icon(glyph, 13, Ui.Secondary), Ui.Text(title, 13, true, Ui.Secondary, wrap: false)),
        };
        head.Click += (_, _) => { if (!collapsed.Remove(key)) collapsed.Add(key); Refresh(); };
        if (closed) return head;
        UIElement top = accessory == null ? head : Ui.Row(head, accessory);
        return Ui.V(8, top, content());
    }

    UIElement StatusCard(GameStory? story)
    {
        string text;
        if (tracker.isRunning) text = $"Đang cập nhật cốt truyện từ {tracker.runningLines} câu mới…";
        else
        {
            var bits = new List<string>();
            if (story != null && story.updated.Year > 1971)
            {
                bits.Add($"Cập nhật lúc {Stamp(story.updated)}");
                if (store.storyParts.FirstOrDefault() is StoryPart last) bits.Add($"đã tóm tắt đến câu lúc {Stamp(last.to)}");
                if (story.backend.Length > 0) bits.Add(BackendLabels.Label(story.backend));
            }
            else bits.Add("Game này chưa được tóm tắt lần nào");
            if (tracker.pendingLines > 0) bits.Add($"{tracker.pendingLines} câu mới chưa đưa vào");
            text = string.Join(" · ", bits);
        }
        UIElement lead = tracker.isRunning ? new ProgressBar { IsIndeterminate = true, Width = 36, Height = 4 } : Ui.Icon("", 14, Ui.AccentStart);
        var buttons = new List<UIElement>();
        if (!settings.storyEnabled)
            buttons.Add(Ui.Btn("Bật tự động", () => settings.storyEnabled = true,
                tip: $"Tự cập nhật cốt truyện khoảng {settings.storyIntervalMin} phút một lần khi đang dịch, và sau khi dừng"));
        if (story != null)
            buttons.Add(Ui.Btn("Cập nhật ngay", tracker.UpdateNow, tip: "Đưa các câu mới vào cốt truyện ngay bây giờ")
                .Also(b => b.IsEnabled = !tracker.isRunning && tracker.pendingLines + tracker.pendingScreens > 0));
        var body = Ui.V(6, Ui.Row(Ui.H(10, lead, Ui.Text(text, color: Ui.Secondary)), buttons.ToArray()));
        if (tracker.lastError is string err)
            body.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(err, 11.5, color: Ui.Danger), Ui.LinkBtn("Ẩn", tracker.DismissError)));
        else if (tracker.notice is string note) body.Children.Add(Ui.Text(note, 11.5, color: Ui.Orange));
        return new Border
        {
            Child = body, Padding = new Thickness(12), CornerRadius = new CornerRadius(10),
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1),
        };
    }

    UIElement EmptyState()
    {
        var v = Ui.V(10, Ui.Icon("", 30, Ui.Tertiary),
            Ui.Text(settings.storyEnabled
                ? $"App sẽ tự viết cốt truyện của game này từ các câu phụ đề dịch được kể từ bây giờ:\nkhoảng {settings.storyIntervalMin} phút một lần khi đang dịch, và một lần sau khi dừng."
                : "Bật nút cốt truyện trên thanh đầu cửa sổ (hoặc “Bật tự động” ở trên) để app tự viết cốt truyện,\ndanh sách nhân vật và diễn biến của game này từ phụ đề.",
                color: Ui.Tertiary).Also(t => t.TextAlignment = TextAlignment.Center));
        if (tracker.backlogLines > 0)
        {
            v.Children.Add(Ui.Btn($"Tóm tắt từ đầu nhật ký đến giờ ({tracker.backlogLines} câu)", tracker.SummarizeFromStart, primary: true)
                .Also(b => b.IsEnabled = !tracker.isRunning));
            v.Children.Add(Ui.Text($"Nhật ký của game này đã có {tracker.backlogLines} câu. Mỗi lượt đưa tối đa 150 câu vào cốt truyện, chạy nối tiếp cho tới hết.",
                11.5, color: Ui.Tertiary).Also(t => t.TextAlignment = TextAlignment.Center));
        }
        foreach (FrameworkElement c in v.Children) c.HorizontalAlignment = HorizontalAlignment.Center;
        v.Margin = new Thickness(0, 40, 0, 40);
        return v;
    }

    UIElement PartCard(StoryPart p, bool expanded)
    {
        string day = $"{p.from:dd/MM/yyyy}", f = $"{p.from:HH:mm}", t = $"{p.to:HH:mm}";
        var timeRange = f == t ? $"{day} {f}" : $"{day} {f} – {t}";
        var plain = $"{p.title}\n\n{p.summary}";
        void Delete()
        {
            if (!Ui.Confirm($"Xoá đoạn “{p.title}” khỏi dòng diễn biến?")) return;
            toggled.Remove(p.id);
            store.DeleteStoryPart(p.id);
        }
        var tools = Ui.H(6, Ui.IconBtn("", () => Ui.CopyText(plain), "Copy đoạn này"), Ui.IconBtn("", Delete, "Xoá đoạn này"));
        tools.Opacity = 0;
        tools.VerticalAlignment = VerticalAlignment.Top;
        var chevron = Ui.Icon(expanded ? "" : "", 9, Ui.AccentStart);
        var body = ReadOnly(p.summary, 14).Also(b => { b.Margin = new Thickness(20, 0, 0, 0); b.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed; });
        var title = new Button
        {
            Style = (Style)Application.Current.FindResource("LinkButton"), HorizontalAlignment = HorizontalAlignment.Left,
            Content = Ui.H(10, chevron, Ui.V(3, Ui.Text(p.title, 14.5, true),
                Ui.Text($"{p.lineCount} câu · {timeRange} · {BackendLabels.Label(p.backend)}", 10.5, color: Ui.Tertiary))),
        };
        title.Click += (_, _) =>
        {
            if (!toggled.Remove(p.id)) toggled.Add(p.id);
            bool open = body.Visibility != Visibility.Visible;
            body.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
            chevron.Text = open ? "" : "";
        };
        var cm = new ContextMenu();
        cm.Items.Add(Mi("Copy đoạn này", () => Ui.CopyText(plain), ""));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Xoá đoạn này", Delete, ""));
        var card = new Border
        {
            Child = Ui.V(8, Ui.Row(title, tools), body), Padding = new Thickness(12), CornerRadius = new CornerRadius(10),
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), ContextMenu = cm,
        };
        card.MouseEnter += (_, _) => { tools.Opacity = 1; card.Background = new SolidColorBrush(Color.FromArgb(13, 0, 0, 0)); };
        card.MouseLeave += (_, _) => { tools.Opacity = 0; card.Background = Ui.Res("CardFill"); };
        return card;
    }

    UIElement CharacterCard(StoryCharacter c)
    {
        var rows = new[] { ("Hiện tại", c.status), ("Vai trò", c.role), ("Tính cách", c.personality), ("Lai lịch", c.background), ("Quan hệ", c.relations) }
            .Where(r => r.Item2.Length > 0).ToList();
        var copyText = string.Join("\n", new[] { c.name }.Concat(rows.Select(r => $"{r.Item1}: {r.Item2}")));
        void Delete()
        {
            if (Ui.Confirm($"Xoá nhân vật “{c.name}” khỏi cốt truyện?")) store.DeleteStoryCharacter(c.name);
        }
        var del = Ui.IconBtn("", Delete, "Xoá nhân vật này");
        del.Opacity = 0;
        var v = Ui.V(6, Ui.Row(Ui.Text(c.name, 14.5, true, new SolidColorBrush(SpeakerColors.ColorFor(c.name))), del));
        if (rows.Count == 0) v.Children.Add(Ui.Text("Chưa biết gì thêm", 11.5, color: Ui.Tertiary));
        foreach (var (label, value) in rows)
            v.Children.Add(Ui.V(1, Ui.Text(label, 10.5, true, Ui.Tertiary), ReadOnly(value, 13)));
        var cm = new ContextMenu();
        cm.Items.Add(Mi("Copy", () => Ui.CopyText(copyText), ""));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Xoá nhân vật này", Delete, ""));
        var card = new Border
        {
            Child = v, Padding = new Thickness(12), CornerRadius = new CornerRadius(10), Width = 320, Margin = new Thickness(0, 0, 10, 10),
            VerticalAlignment = VerticalAlignment.Top,
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), ContextMenu = cm,
        };
        card.MouseEnter += (_, _) => { del.Opacity = 1; card.Background = new SolidColorBrush(Color.FromArgb(13, 0, 0, 0)); };
        card.MouseLeave += (_, _) => { del.Opacity = 0; card.Background = Ui.Res("CardFill"); };
        return card;
    }
}
