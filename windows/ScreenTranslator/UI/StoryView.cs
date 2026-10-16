using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ScreenTranslator;

/// Tab "Cốt truyện": cốt truyện của game đang chọn do app tự viết từ phụ đề: bài viết liền mạch,
/// dòng thời gian từng đoạn diễn biến, danh sách nhân vật và bách khoa (địa danh, thế lực, khái niệm lấy từ màn hình
/// nhật ký đã dịch). Thanh ngang ở trên cùng nhảy nhanh tới từng mục. Tab Nhật ký giữ một thể hiện duy nhất (không dựng lại
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
    /// Thanh nhảy nhanh ghim ở đầu trang, và chỗ bắt đầu của từng mục để cuộn tới.
    readonly Border jumpBar = new() { Padding = new Thickness(14, 8, 14, 8), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(0, 0, 0, 1) };
    readonly Dictionary<string, FrameworkElement> anchors = new();
    /// Vùng nội dung dưới thanh mục: khung cuộn các mục cốt truyện, hoặc danh sách bản tóm tắt (mục "Tóm tắt").
    readonly ContentControl body = new();
    /// Dựng danh sách bản tóm tắt thủ công (LogTab cung cấp).
    public Func<UIElement>? summariesContent;
    public bool ShowingSummaries => shown == "summaries";
    /// Mục "Hỏi đáp": hỏi về cốt truyện (giữ một thể hiện để ô nhập và hội thoại không mất khi vẽ lại).
    public bool ShowingAsk => shown == "ask";
    readonly StoryChatPanel chatPanel = new();
    /// Đổi mục ở thanh trên cùng (LogTab ẩn ô tìm / nút xoá khi đang ở mục Hỏi đáp).
    public event Action? SectionChanged;
    public void ShowSummaries() { shown = "summaries"; Refresh(); }
    /// Mục đang xem, chọn ở thanh trên cùng: chỉ dựng mục đó (dựng cả bốn mục một lúc làm trang dài và cuộn giật).
    string shown
    {
        get => settings.Get("storyShownSection", "parts");
        set => settings.Set("storyShownSection", value, "storyShownSection");
    }
    /// Loại mục bách khoa đang lọc ("" = tất cả).
    string loreKind = "";
    /// Thứ tự danh sách nhân vật: true = ai vừa xuất hiện gần đây đứng trước, false = theo thứ tự gặp trong game.
    bool recentFirst
    {
        get => settings.Get("storyCharactersRecentFirst", true);
        set => settings.Set("storyCharactersRecentFirst", value, "storyCharactersRecentFirst");
    }

    public StoryView()
    {
        Background = Brushes.White;
        var dock = new DockPanel();
        DockPanel.SetDock(jumpBar, Dock.Top);
        dock.Children.Add(jumpBar);
        dock.Children.Add(body);
        body.Content = scroll;
        Child = dock;
        store.StoryChanged += () => Dispatcher.BeginInvoke(Refresh);
        store.Changed += () => Dispatcher.BeginInvoke(() => { if (ShowingSummaries) Refresh(); });
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

    public void Refresh()
    {
        if (!IsVisible) return;
        var story = store.story;
        var narrative = story?.narrative ?? "";
        var q = search.ToLowerInvariant();
        var parts = store.storyParts.Where(p => q.Length == 0 || p.title.ToLowerInvariant().Contains(q) || p.summary.ToLowerInvariant().Contains(q)).ToList();
        // Danh sách lưu theo thứ tự gặp lần đầu. "Vừa xuất hiện": xếp theo lần xuất hiện gần nhất; nhân vật của dữ liệu cũ
        // (chưa ghi nhận thời điểm) thì ai được thêm sau đứng trước.
        IEnumerable<StoryCharacter> ordered = story?.characters ?? new();
        if (recentFirst) ordered = ordered.Select((c, i) => (c, i)).OrderByDescending(x => x.c.seen).ThenByDescending(x => x.i).Select(x => x.c);
        var chars = ordered.Where(c => q.Length == 0 ||
            new[] { c.name, c.status, c.role, c.personality, c.background, c.relations, c.journal }.Any(f => f.ToLowerInvariant().Contains(q))).ToList();
        var loreMatches = (story?.lore ?? new()).Where(l => q.Length == 0 || l.name.ToLowerInvariant().Contains(q) || l.description.ToLowerInvariant().Contains(q)).ToList();
        var lore = loreKind.Length == 0 ? loreMatches : loreMatches.Where(l => l.kind == loreKind).ToList();
        bool hasContent = narrative.Length > 0 || store.storyParts.Count > 0 || (story?.characters.Count ?? 0) > 0 || (story?.lore.Count ?? 0) > 0;
        anchors.Clear();
        bool showNarrative = narrative.Length > 0 && (q.Length == 0 || narrative.ToLowerInvariant().Contains(q));

        var v = Ui.V(16, StatusCard(story));
        if (!hasContent) v.Children.Add(EmptyState());
        else
        {
            var view = shown;
            if (view == "narrative" && showNarrative)
                v.Children.Add(Section("narrative", "Cốt truyện đến hiện tại", "\uE736", Ui.InlineIconBtn("\uE8C8", () => Ui.CopyText(narrative), "Copy"), () => new Border
                {
                    Padding = new Thickness(12), CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Color.FromArgb(16, 97, 111, 250)),
                    Child = ReadOnly(narrative, 14.5),
                }));
            if (view == "parts" && parts.Count > 0)
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
            if (view == "characters" && chars.Count > 0)
            {
                var order = Ui.LinkBtn(recentFirst ? "Vừa xuất hiện ▾" : "Theo mạch truyện ▾", () => { recentFirst = !recentFirst; Refresh(); });
                order.ToolTip = "Vừa xuất hiện: ai mới góp mặt trong diễn biến gần đây đứng đầu. Theo mạch truyện: xếp theo thứ tự gặp lần đầu trong game. Bấm để đổi.";
                v.Children.Add(Section("characters", $"Nhân vật  {chars.Count}", "\uE716", order, () =>
                {
                    var grid = new WrapPanel();
                    foreach (var c in chars) grid.Children.Add(CharacterCard(c));
                    return grid;
                }));
            }
            if (view == "lore" && loreMatches.Count > 0)
            {
                var filter = Ui.H(6);
                foreach (var (id, label) in new[] { ("", "Tất cả") }.Concat(StoryLore.kinds))
                {
                    int n = id.Length == 0 ? loreMatches.Count : loreMatches.Count(l => l.kind == id);
                    if (n == 0) continue;
                    var kindId = id;
                    var b = Ui.LinkBtn($"{label} {n}", () => { loreKind = kindId; Refresh(); });
                    if (loreKind == id) b.FontWeight = FontWeights.Bold;
                    filter.Children.Add(b);
                }
                v.Children.Add(Section("lore", $"Bách khoa  {loreMatches.Count}", "\uE82D", filter, () =>
                {
                    var grid = new WrapPanel();
                    foreach (var l in lore) grid.Children.Add(LoreCard(l));
                    return grid;
                }));
            }
            if (v.Children.Count == 1)
                v.Children.Add(view == "lore" && q.Length == 0 ? LoreEmptyState() : Ui.Text(view switch
                {
                    "narrative" => q.Length == 0 ? "Chưa có bài tóm lược." : $"Bài tóm lược không có chữ nào khớp “{search}”.",
                    "characters" => q.Length == 0 ? "Chưa có nhân vật nào." : $"Không có nhân vật nào khớp “{search}”.",
                    "lore" => $"Không có mục bách khoa nào khớp “{search}”.",
                    _ => q.Length == 0 ? "Chưa có đoạn diễn biến nào." : $"Không có đoạn diễn biến nào khớp “{search}”.",
                }, color: Ui.Tertiary).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 30, 0, 0); }));
        }
        v.Margin = new Thickness(14);
        scroll.Content = v;
        body.Content = ShowingAsk ? chatPanel : ShowingSummaries && summariesContent != null ? summariesContent() : scroll;
        BuildJumpBar(hasContent || store.summaries.Count > 0 || ShowingAsk, showNarrative, parts.Count, chars.Count, loreMatches.Count);
    }

    /// Bách khoa còn trống: giải thích cách có mục, và cho đọc lại các màn hình đã dịch trước đây (chưa được đưa vào).
    UIElement LoreEmptyState()
    {
        var v = Ui.V(10, Ui.Icon("\uE82D", 28, Ui.Tertiary),
            Ui.Text("Bách khoa ghi lại địa danh, thế lực, đội quân và khái niệm của thế giới game.\nMỗi khi bạn Dịch màn hình nhật ký hay bách khoa trong game, app sẽ tự thêm mục vào đây ở lần cập nhật cốt truyện kế tiếp.",
                color: Ui.Tertiary).Also(t => t.TextAlignment = TextAlignment.Center));
        if (store.analyses.Count > 0)
        {
            v.Children.Add(Ui.Btn($"Đọc lại {store.analyses.Count} màn hình đã dịch của game này", tracker.RescanScreens, primary: true)
                .Also(b => b.IsEnabled = !tracker.isRunning));
            v.Children.Add(Ui.Text("Các màn hình dịch trước đây chưa được tách ra bách khoa. App sẽ đọc lại chúng (khoảng 15 màn hình mỗi lượt) để thêm địa danh, thế lực và hồ sơ nhân vật; phần diễn biến không đổi.",
                11.5, color: Ui.Tertiary).Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 520; }));
        }
        foreach (FrameworkElement c in v.Children) c.HorizontalAlignment = HorizontalAlignment.Center;
        v.Margin = new Thickness(0, 30, 0, 30);
        return v;
    }

    /// Thanh ngang ghim ở đầu trang: bấm để xem riêng mục đó.
    void BuildJumpBar(bool hasContent, bool narrative, int parts, int chars, int lore)
    {
        jumpBar.Visibility = hasContent ? Visibility.Visible : Visibility.Collapsed;
        var bar = Ui.H(8);
        void Add(string key, string title, string glyph, int? count, bool show)
        {
            if (!show) return;
            bool on = shown == key;
            var chip = new Button
            {
                Style = (Style)Application.Current.FindResource("LinkButton"), ToolTip = $"Xem mục {title}",
                Content = new Border
                {
                    Padding = new Thickness(11, 4, 11, 4), CornerRadius = new CornerRadius(12),
                    Background = on ? Ui.AccentGradient : Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(on ? 0 : 1),
                    Child = Ui.H(5, Ui.Icon(glyph, 11, on ? Brushes.White : Ui.Secondary), Ui.Text(title, 12.5, on, on ? Brushes.White : null, wrap: false),
                        count is int n ? Ui.Text($"{n}", 11.5, color: on ? Brushes.White : Ui.Tertiary, wrap: false) : null),
                },
            };
            chip.Click += (_, _) =>
            {
                shown = key;
                collapsed.Remove(key);
                Refresh();
                scroll.ScrollToTop();
                SectionChanged?.Invoke();
            };
            bar.Children.Add(chip);
        }
        Add("narrative", "Tóm lược", "\uE736", null, true);
        Add("parts", "Diễn biến", "\uE8FD", parts, true);
        Add("characters", "Nhân vật", "\uE716", chars, true);
        Add("lore", "Bách khoa", "\uE82D", lore, true);
        Add("summaries", "Tóm tắt", "\uE8BD", store.summaries.Count, true);
        Add("ask", "Hỏi đáp", "\uE8F2", null, true);
        jumpBar.Child = bar;
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
        if (closed) { anchors[key] = head; return head; }
        UIElement top = accessory == null ? head : Ui.Row(head, accessory);
        var section = Ui.V(8, top, content());
        anchors[key] = section;
        return section;
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
        var tools = Ui.H(6, Ui.InlineIconBtn("", () => Ui.CopyText(plain), "Copy đoạn này"), Ui.InlineIconBtn("", Delete, "Xoá đoạn này"));
        tools.Opacity = 0;
        tools.VerticalAlignment = VerticalAlignment.Top;
        var chevron = Ui.Icon(expanded ? "" : "", 9, Ui.AccentStart);
        var body = ReadOnly(p.summary, 14).Also(b => { b.Margin = new Thickness(20, 0, 0, 0); b.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed; });
        var title = new Button
        {
            Style = (Style)Application.Current.FindResource("LinkButton"), HorizontalAlignment = HorizontalAlignment.Left,
            Content = Ui.H(10, chevron, Ui.V(3, Ui.Text(p.title, 16.5, true),
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

    /// Thẻ nhân vật gọn như trên trang web: chữ cái đầu, tên, vai trò và tình trạng hiện tại; bấm vào đầu thẻ để xem
    /// tính cách, lai lịch, quan hệ và hồ sơ từ nhật ký.
    UIElement CharacterCard(StoryCharacter c)
    {
        var details = new[] { ("Tính cách", c.personality), ("Lai lịch", c.background), ("Quan hệ", c.relations), ("Từ nhật ký", c.journal) }
            .Where(r => r.Item2.Length > 0).ToList();
        var all = new[] { ("Hiện tại", c.status), ("Vai trò", c.role) }.Where(r => r.Item2.Length > 0).Concat(details);
        var copyText = string.Join("\n", new[] { c.name }.Concat(all.Select(r => $"{r.Item1}: {r.Item2}")));
        void Delete()
        {
            if (Ui.Confirm($"Xoá nhân vật “{c.name}” khỏi cốt truyện?")) store.DeleteStoryCharacter(c.name);
        }
        var color = new SolidColorBrush(SpeakerColors.ColorFor(c.name));
        var initial = c.name.Trim().Length > 0 ? c.name.Trim()[..1].ToUpperInvariant() : "?";
        var avatar = new Border
        {
            Width = 34, Height = 34, CornerRadius = new CornerRadius(17), BorderBrush = color, BorderThickness = new Thickness(1.5),
            Background = new SolidColorBrush(Color.FromArgb(26, color.Color.R, color.Color.G, color.Color.B)),
            Child = Ui.Text(initial, 15, true, color, wrap: false).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.VerticalAlignment = VerticalAlignment.Center; }),
        };
        var nameBox = Ui.V(1, Ui.Text(c.name, 15, true, color, wrap: false));
        if (c.role.Length > 0) nameBox.Children.Add(Ui.Text(c.role, 12.5, color: Ui.Secondary).Also(t => { t.MaxHeight = 36; t.TextTrimming = TextTrimming.CharacterEllipsis; }));
        var chevron = Ui.Icon("\uE76C", 9, Ui.Tertiary);
        var del = Ui.InlineIconBtn("\uE74D", Delete, "Xoá nhân vật này");
        del.Opacity = 0;
        var head = new Button
        {
            Style = (Style)Application.Current.FindResource("LinkButton"), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, ToolTip = details.Count > 0 ? "Xem chi tiết" : null,
            Content = Ui.Row(Ui.H(11, avatar, nameBox), details.Count > 0 ? new UIElement[] { chevron } : Array.Empty<UIElement>()),
        };
        var v = Ui.V(10, Ui.Row(head, del));
        if (c.status.Length > 0)
            v.Children.Add(new Border
            {
                Padding = new Thickness(10, 7, 10, 7), CornerRadius = new CornerRadius(8), Background = new SolidColorBrush(Color.FromArgb(12, 0, 0, 0)),
                Child = Ui.V(2, Ui.Text("HIỆN TẠI", 9.5, true, Ui.Tertiary), ReadOnly(c.status, 13)),
            });
        else if (c.role.Length == 0 && details.Count == 0) v.Children.Add(Ui.Text("Chưa biết gì thêm", 11.5, color: Ui.Tertiary));
        var more = Ui.V(10);
        foreach (var (label, value) in details) more.Children.Add(Ui.V(2, Ui.Text(label.ToUpperInvariant(), 9.5, true, Ui.Tertiary), ReadOnly(value, 13)));
        more.Visibility = Visibility.Collapsed;
        v.Children.Add(more);
        head.Click += (_, _) =>
        {
            if (details.Count == 0) return;
            bool open = more.Visibility != Visibility.Visible;
            more.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
            chevron.Text = open ? "\uE70D" : "\uE76C";
            chevron.Foreground = open ? Ui.AccentStart : Ui.Tertiary;
        };
        var cm = new ContextMenu();
        cm.Items.Add(Mi("Copy", () => Ui.CopyText(copyText), "\uE8C8"));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Xoá nhân vật này", Delete, "\uE74D"));
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

    /// Mỗi loại mục bách khoa một màu: địa danh xanh lục, thế lực đỏ cam, khái niệm tím, khác xám.
    static Color KindColor(string kind) => kind switch
    {
        "place" => Color.FromRgb(0x1A, 0x9E, 0x78),
        "faction" => Color.FromRgb(0xDB, 0x4D, 0x38),
        "concept" => Color.FromRgb(0x85, 0x5C, 0xE0),
        _ => Color.FromRgb(0x8A, 0x8A, 0x8A),
    };

    /// Một mục bách khoa: tên, loại (địa danh / thế lực / khái niệm) và mô tả lấy từ màn hình nhật ký của game.
    UIElement LoreCard(StoryLore l)
    {
        void Delete()
        {
            if (Ui.Confirm($"Xoá mục “{l.name}” khỏi bách khoa?")) store.DeleteStoryLore(l.name);
        }
        var del = Ui.InlineIconBtn("\uE74D", Delete, "Xoá mục này");
        del.Opacity = 0;
        var kc = KindColor(l.kind);
        var kind = new Border
        {
            Padding = new Thickness(7, 1, 7, 2), CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Color.FromArgb(36, kc.R, kc.G, kc.B)), BorderBrush = new SolidColorBrush(Color.FromArgb(115, kc.R, kc.G, kc.B)),
            VerticalAlignment = VerticalAlignment.Center, Child = Ui.Text(l.kindLabel.ToUpperInvariant(), 9.5, true, new SolidColorBrush(kc), wrap: false),
        };
        var v = Ui.V(6, Ui.Row(Ui.H(7, Ui.Text(l.name, 16, true, wrap: false), kind), del), ReadOnly(l.description, 13));
        var cm = new ContextMenu();
        cm.Items.Add(Mi("Copy", () => Ui.CopyText($"{l.name}\n{l.description}"), "\uE8C8"));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Xoá mục này", Delete, "\uE74D"));
        var card = new Border
        {
            Child = v, Padding = new Thickness(12), CornerRadius = new CornerRadius(10), Width = 320, Margin = new Thickness(0, 0, 10, 10),
            VerticalAlignment = VerticalAlignment.Top,
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(3, 1, 1, 1), ContextMenu = cm,
        };
        card.BorderBrush = new SolidColorBrush(kc);
        card.MouseEnter += (_, _) => { del.Opacity = 1; card.Background = new SolidColorBrush(Color.FromArgb(13, 0, 0, 0)); };
        card.MouseLeave += (_, _) => { del.Opacity = 0; card.Background = Ui.Res("CardFill"); };
        return card;
    }
}
