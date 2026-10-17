using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Một kết quả tìm trong cốt truyện: nhân vật, mục bách khoa, đoạn diễn biến, bản tóm tắt hoặc một đoạn của bài tóm lược.
public sealed record StorySearchHit(string id, string kindLabel, string title, string body, DateTime? date);

/// Tìm một cụm từ trong phụ đề, cốt truyện và dịch màn hình của game đang chọn (giống bản macOS).
/// Phụ đề và dịch màn hình đọc thẳng từ DB (cả dòng cũ ngoài bộ nhớ); cốt truyện lọc từ dữ liệu đã nạp.
public static class HistorySearch
{
    public sealed class Results
    {
        public string query = "";
        public List<TranslationEntry> subtitles = new();
        public List<StorySearchHit> story = new();
        public List<ScreenAnalysis> screens = new();
        public bool subtitlesCapped, screensCapped;
        public bool IsEmpty => subtitles.Count == 0 && story.Count == 0 && screens.Count == 0;
    }

    public const int dbLimit = 500, minLength = 2;

    /// Không phân biệt hoa thường (cả chữ có dấu), nhưng phân biệt dấu: "gia" không khớp "giá".
    public static bool Matches(string text, string q) => text.Contains(q, StringComparison.CurrentCultureIgnoreCase);

    public static Results Run(string raw)
    {
        var q = raw.Trim();
        var r = new Results { query = q };
        if (q.Length < minLength) return r;
        var store = HistoryStore.shared;
        var profile = store.scope;
        // LIKE của SQLite chỉ bỏ qua hoa thường với chữ ASCII → gửi thêm vài biến thể hoa thường rồi lọc lại.
        var terms = new[] { q, q.ToLowerInvariant(), q.ToUpperInvariant(), CultureInfo.CurrentCulture.TextInfo.ToTitleCase(q.ToLowerInvariant()) }.Distinct().ToList();

        var subs = store.SearchEntries(profile, terms, dbLimit);
        r.subtitlesCapped = subs.Count >= dbLimit;
        r.subtitles = subs.Where(e => Matches(e.source, q) || Matches(e.translated, q)).ToList();

        var shots = store.SearchAnalyses(profile, terms, dbLimit);
        r.screensCapped = shots.Count >= dbLimit;
        r.screens = shots.Where(a => Matches(a.summary, q) || a.lines.Any(l => Matches(l.source, q) || Matches(l.target, q))).ToList();

        r.story = StoryHits(q, store);
        return r;
    }

    static List<StorySearchHit> StoryHits(string q, HistoryStore store)
    {
        var outp = new List<StorySearchHit>();
        var story = store.story;
        foreach (var c in story?.characters ?? new())
        {
            var fields = new (string label, string text)[] { ("Tình trạng", c.status), ("Vai trò", c.role), ("Tính cách", c.personality),
                ("Lai lịch", c.background), ("Quan hệ", c.relations), ("Hồ sơ", c.journal) };
            if (!Matches(c.name, q) && !fields.Any(f => Matches(f.text, q))) continue;
            var body = string.Join("\n", fields.Where(f => f.text.Length > 0).Select(f => $"{f.label}: {f.text}"));
            outp.Add(new StorySearchHit($"c:{c.name}", "Nhân vật", c.name, body,
                c.seen > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)(c.seen * 1000)).LocalDateTime : null));
        }
        foreach (var l in story?.lore ?? new())
            if (Matches(l.name, q) || Matches(l.description, q))
                outp.Add(new StorySearchHit($"l:{l.name}", "Bách khoa", $"{l.name} · {l.kindLabel}", l.description, null));
        foreach (var p in store.storyParts)
            if (Matches(p.title, q) || Matches(p.summary, q))
                outp.Add(new StorySearchHit($"p:{p.id}", "Diễn biến", p.title, p.summary, p.timestamp));
        foreach (var s in store.summaries)
        {
            var lines = s.lines.Where(l => Matches(l.source, q) || Matches(l.target, q)).ToList();
            if (!Matches(s.title, q) && !Matches(s.summary, q) && lines.Count == 0) continue;
            var quoted = lines.Take(5).Select(l => "• " + (l.target.Length == 0 ? l.source : l.target));
            outp.Add(new StorySearchHit($"s:{s.id}", "Tóm tắt", s.title, string.Join("\n", new[] { s.summary }.Concat(quoted)), s.timestamp));
        }
        var paragraphs = (story?.narrative ?? "").Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
        for (int i = 0; i < paragraphs.Count; i++)
            if (Matches(paragraphs[i], q))
                outp.Add(new StorySearchHit($"n:{i}", "Tóm lược", $"Bài tóm lược · đoạn {i + 1}", paragraphs[i], null));
        // Mới trước, cũ sau: mục có thời điểm (nhân vật vừa xuất hiện, đoạn diễn biến, bản tóm tắt) theo thời điểm giảm dần;
        // mục không có (bách khoa, nhân vật của dữ liệu cũ, đoạn của bài tóm lược) đứng sau, cái thêm sau / viết sau trước.
        return outp.Select((h, i) => (h, i))
            .OrderBy(x => x.h.date == null).ThenByDescending(x => x.h.date ?? DateTime.MinValue).ThenByDescending(x => x.i)
            .Select(x => x.h).ToList();
    }

    /// Một đoạn khoảng `width` ký tự quanh chỗ khớp đầu tiên (thêm "…" khi bị cắt), gộp về một dòng.
    public static string Snippet(string text, string q, int width = 140)
    {
        var flat = text.Replace("\n", " · ");
        if (flat.Length <= width) return flat;
        int at = flat.IndexOf(q, StringComparison.CurrentCultureIgnoreCase);
        if (at < 0) return flat[..width] + "…";
        int start = Math.Max(0, at - Math.Max(0, (width - q.Length) / 3));
        int end = Math.Min(flat.Length, start + width);
        return (start > 0 ? "…" : "") + flat[start..end] + (end < flat.Length ? "…" : "");
    }

    public static string Date(DateTime d) => d.ToString(d.Date == DateTime.Today ? "HH:mm" : "dd/MM HH:mm");

    static readonly Brush mark = new SolidColorBrush(Color.FromArgb(115, 255, 214, 0));

    /// Tô nền mọi chỗ khớp `q` trong các Run (giữ màu / độ đậm của Run gốc).
    public static List<Inline> Mark(IEnumerable<Inline> inlines, string q)
    {
        var outp = new List<Inline>();
        foreach (var inl in inlines)
        {
            if (inl is not Run run || q.Length == 0) { outp.Add(inl); continue; }
            var text = run.Text;
            int pos = 0;
            while (pos < text.Length)
            {
                int at = text.IndexOf(q, pos, StringComparison.CurrentCultureIgnoreCase);
                if (at < 0) { outp.Add(Copy(run, text[pos..])); break; }
                if (at > pos) outp.Add(Copy(run, text[pos..at]));
                var hit = Copy(run, text.Substring(at, q.Length));
                hit.Background = mark;
                outp.Add(hit);
                pos = at + q.Length;
            }
        }
        return outp;
    }

    static Run Copy(Run r, string text)
    {
        var c = new Run(text);
        if (r.ReadLocalValue(TextElement.FontWeightProperty) != DependencyProperty.UnsetValue) c.FontWeight = r.FontWeight;
        if (r.ReadLocalValue(TextElement.ForegroundProperty) != DependencyProperty.UnsetValue) c.Foreground = r.Foreground;
        return c;
    }

    /// Nhãn như Ui.Text nhưng tô nền chỗ khớp `q`.
    public static TextBlock Label(string s, string q, double size = 13, bool bold = false, Brush? color = null, bool wrap = true)
    {
        var t = Ui.Text(s, size, bold, color, wrap);
        if (q.Length > 0) { t.Inlines.Clear(); t.Inlines.AddRange(Mark(new List<Inline> { new Run(s) }, q)); }
        return t;
    }

    /// Đoạn văn chỉ đọc: không tìm gì thì là TextBox (chọn / copy được), đang tìm thì là TextBlock có tô nền chỗ khớp.
    public static FrameworkElement Readable(string text, string q, double size)
    {
        if (q.Length > 0) return Text(text, q, size).Also(t => t.Margin = new Thickness(0, 0, 0, 0));
        return new TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = size, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Padding = new Thickness(0), Margin = new Thickness(-2, 0, 0, 0),
        };
    }

    public static TextBlock Text(string s, string q, double size, Brush? color = null, FontWeight? weight = null, bool styled = false)
    {
        var t = new TextBlock { FontSize = size, TextWrapping = TextWrapping.Wrap };
        IEnumerable<Inline> src = styled ? SpeakerColors.Styled(s, weight: weight) : new List<Inline> { new Run(s) { FontWeight = weight ?? FontWeights.Normal } };
        t.Inlines.AddRange(Mark(src, q));
        if (color != null) t.Foreground = color;
        return t;
    }
}

/// Tab "Tìm kiếm": một ô tìm cho cả phụ đề, cốt truyện và dịch màn hình của game đang chọn.
/// Mỗi khu vực mặc định chỉ hiện vài kết quả đầu; bấm để xem tất cả. Bấm một kết quả để mở chi tiết ngay tại chỗ.
public sealed class SearchTab : DockPanel
{
    const int preview = 3, maxShown = 200;
    enum Area { subtitles, story, screens }

    readonly TextBox box = new() { FontSize = 16, BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalContentAlignment = VerticalAlignment.Center };
    readonly TextBlock placeholder = Ui.Text("", 16, color: Ui.Tertiary, wrap: false);
    readonly ContentControl body = new();
    readonly HashSet<Area> open = new();
    HistorySearch.Results results = new();

    public SearchTab()
    {
        LastChildFill = true;
        Background = Brushes.White;
        var clear = Ui.InlineIconBtn("", () => { box.Text = ""; box.Focus(); }, "Xoá ô tìm");
        var field = new Grid();
        field.Children.Add(placeholder);
        field.Children.Add(box);
        placeholder.IsHitTestVisible = false; placeholder.VerticalAlignment = VerticalAlignment.Center; placeholder.Margin = new Thickness(2, 0, 0, 0);
        var row = new DockPanel { LastChildFill = true };
        var icon = Ui.Icon("", 16, Ui.Secondary); icon.Margin = new Thickness(0, 0, 8, 0);
        DockPanel.SetDock(icon, Dock.Left); DockPanel.SetDock(clear, Dock.Right);
        row.Children.Add(icon); row.Children.Add(clear); row.Children.Add(field);
        var frame = new Border
        {
            Child = row, Height = 44, Padding = new Thickness(12, 0, 8, 0), CornerRadius = new CornerRadius(10),
            Background = Ui.Hex("#0F000000"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1),
            Margin = new Thickness(16, 14, 16, 10),
        };
        box.GotKeyboardFocus += (_, _) => { frame.BorderBrush = Ui.AccentStart; frame.BorderThickness = new Thickness(1.5); };
        box.LostKeyboardFocus += (_, _) => { frame.BorderBrush = Ui.Res("CardStroke"); frame.BorderThickness = new Thickness(1); };
        box.TextChanged += (_, _) =>
        {
            placeholder.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            clear.Visibility = box.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        };
        Ui.OnSearch(box, Search);
        clear.Visibility = Visibility.Collapsed;
        var div = new Border { Height = 1, Background = Ui.Res("CardStroke") };
        SetDock(frame, Dock.Top); SetDock(div, Dock.Top);
        Children.Add(frame); Children.Add(div);
        Children.Add(Ui.Scroll(body));

        AppSettings.shared.Changed += k => { if (k is "activeProfileID") Dispatcher.BeginInvoke(() => { UpdatePlaceholder(); Search(); }); };
        IsVisibleChanged += (_, _) => { if (IsVisible) Dispatcher.BeginInvoke(() => { box.Focus(); UpdatePlaceholder(); if (results.query.Length > 0) Search(); }, DispatcherPriority.Input); };
        UpdatePlaceholder();
        Render();
    }

    void UpdatePlaceholder() => placeholder.Text = $"Tìm trong cốt truyện, phụ đề và ảnh đã dịch của “{AppSettings.shared.activeProfile.name}”";

    void Search()
    {
        var r = HistorySearch.Run(box.Text);
        if (r.query != results.query) open.Clear();
        results = r;
        Render();
    }

    void Render()
    {
        var v = Ui.V(12);
        v.Margin = new Thickness(16);
        if (results.query.Length < HistorySearch.minLength)
        {
            var msg = box.Text.Trim().Length == 0
                ? "Gõ tên nhân vật, địa danh, câu thoại… để tìm trong phụ đề, cốt truyện và ảnh đã dịch của game này."
                : $"Gõ ít nhất {HistorySearch.minLength} ký tự.";
            var hint = Ui.V(10, Ui.Icon("", 34, Ui.Tertiary).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
                Ui.Text(msg, color: Ui.Secondary).Also(t => { t.TextAlignment = TextAlignment.Center; t.HorizontalAlignment = HorizontalAlignment.Center; t.MaxWidth = 520; }));
            hint.Margin = new Thickness(0, 60, 0, 0);
            v.Children.Add(hint);
        }
        else
        {
            string N(int c, bool capped) => capped ? $"{c}+" : $"{c}";
            v.Children.Add(Ui.Text(results.IsEmpty ? $"Không tìm thấy “{results.query}” trong game này."
                : $"Tìm thấy {results.story.Count} mục cốt truyện · {N(results.subtitles.Count, results.subtitlesCapped)} phụ đề · {N(results.screens.Count, results.screensCapped)} màn hình",
                color: Ui.Secondary));
            v.Children.Add(Section(Area.story, "", "Cốt truyện", results.story, false, StoryRow));
            v.Children.Add(Section(Area.subtitles, "", "Phụ đề", results.subtitles, results.subtitlesCapped, SubtitleRow));
            v.Children.Add(Section(Area.screens, "", "Dịch màn hình", results.screens, results.screensCapped, ScreenRow));
        }
        body.Content = v;
    }

    /// Một khu vực kết quả: tiêu đề + số lượng; thu gọn thì hiện `preview` dòng đầu, mở thì hiện tối đa `maxShown` dòng.
    UIElement Section<T>(Area area, string glyph, string title, List<T> items, bool capped, Func<T, UIElement> row)
    {
        bool isOpen = open.Contains(area);
        var shown = items.Take(isOpen ? maxShown : preview).ToList();
        int more = items.Count - shown.Count;
        string count = capped ? $"{items.Count}+" : $"{items.Count}";
        var pill = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 6, 0), Background = Ui.Hex("#14000000"),
            Child = Ui.Text(count, 11, true), VerticalAlignment = VerticalAlignment.Center };
        var head = Ui.H(8,
            Ui.Icon(isOpen ? "" : "", 10, Ui.Secondary).Also(i => i.Width = 14),
            Ui.Icon(glyph, 15, Ui.AccentStart), Ui.Text(title, 14, true, wrap: false), pill);
        var toggleText = items.Count > preview ? Ui.Text(isOpen ? "Thu gọn" : "Xem tất cả", 11.5, true, Ui.AccentStart, wrap: false) : null;
        var header = new Border { Background = Brushes.Transparent, Child = toggleText == null ? head : Ui.Row(head, toggleText) };
        if (items.Count > preview) { header.Cursor = Cursors.Hand; header.MouseLeftButtonUp += (_, _) => Toggle(area); }
        var v = Ui.V(6, header);
        if (items.Count == 0) v.Children.Add(Ui.Text("Không có", color: Ui.Tertiary).Also(t => t.Margin = new Thickness(22, 0, 0, 0)));
        else
        {
            var list = Ui.V(4);
            foreach (var it in shown) list.Children.Add(row(it));
            v.Children.Add(list);
            if (more > 0 || (isOpen && capped))
            {
                var foot = isOpen
                    ? Ui.Caption($"Còn {(more > 0 ? more.ToString() : "nhiều")} kết quả nữa, gõ cụ thể hơn để thu hẹp.")
                    : Ui.Text($"Xem tất cả {count} kết quả", 11.5, true, Ui.AccentStart);
                foot.Margin = new Thickness(22, 0, 0, 0);
                if (!isOpen) { foot.Cursor = Cursors.Hand; foot.MouseLeftButtonUp += (_, _) => Toggle(area); }
                v.Children.Add(foot);
            }
        }
        var card = Ui.Card(v, 12);
        card.Margin = new Thickness(0);
        card.Background = Ui.Hex("#05000000");
        if (items.Count == 0) card.Opacity = 0.6;
        return card;
    }

    void Toggle(Area a) { if (!open.Remove(a)) open.Add(a); Render(); }

    /// Khung chung của một dòng kết quả: nền khi rê chuột, bấm để mở / đóng.
    static Border HitFrame(Func<bool, UIElement> content, Action<Border, Action> onClick, string tip, ContextMenu? menu = null)
    {
        var accent = ((SolidColorBrush)Ui.AccentStart).Color;
        var b = new Border { Padding = new Thickness(10, 7, 10, 7), CornerRadius = new CornerRadius(8), Background = Brushes.Transparent,
            Cursor = Cursors.Hand, ToolTip = tip, ContextMenu = menu };
        bool isOpen = false;
        void Draw() { b.Child = content(isOpen); b.Background = isOpen ? new SolidColorBrush(Color.FromArgb(20, accent.R, accent.G, accent.B)) : Brushes.Transparent; }
        b.MouseEnter += (_, _) => { if (!isOpen) b.Background = Ui.Hex("#0C000000"); };
        b.MouseLeave += (_, _) => { if (!isOpen) b.Background = Brushes.Transparent; };
        b.MouseLeftButtonUp += (_, _) => onClick(b, () => { isOpen = !isOpen; Draw(); });
        Draw();
        return b;
    }

    static ContextMenu CopyMenu(string source, string translated)
    {
        var m = new ContextMenu();
        void Item(string text, string value) { var mi = new MenuItem { Header = text }; mi.Click += (_, _) => Ui.CopyText(value); m.Items.Add(mi); }
        Item("Copy bản gốc", source); Item("Copy bản dịch", translated); Item("Copy cả hai", $"{source}\n{translated}");
        return m;
    }

    UIElement SubtitleLine(TranslationEntry e, bool strong)
    {
        var q = results.query;
        bool skipped = e.backend == BackendKind.skipped.ToString();
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var time = Ui.Text(HistorySearch.Date(e.timestamp), 10.5, color: Ui.Tertiary, wrap: false);
        var tr = skipped ? Ui.Text("—", 14, color: Ui.Tertiary)
            : HistorySearch.Text(e.translated, q, 14, weight: strong ? FontWeights.Medium : FontWeights.Normal, styled: true);
        var src = HistorySearch.Text(e.source, q, 13, Ui.Secondary, styled: true);
        tr.Margin = new Thickness(0, 0, 16, 0);
        Grid.SetColumn(tr, 1); Grid.SetColumn(src, 2);
        g.Children.Add(time); g.Children.Add(tr); g.Children.Add(src);
        if (!strong) g.Opacity = 0.6;
        return g;
    }

    UIElement SubtitleRow(TranslationEntry entry)
    {
        List<TranslationEntry>? context = null;
        return HitFrame(isOpen =>
        {
            if (!isOpen || context == null) return SubtitleLine(entry, true);
            var v = Ui.V(6);
            foreach (var e in context) v.Children.Add(SubtitleLine(e, e.id == entry.id));
            return v;
        }, (_, flip) =>
        {
            if (context == null)
            {
                var around = HistoryStore.shared.EntriesAround(entry.id, entry.profile, 3);
                context = around.Count == 0 ? new() { entry } : around;
            }
            flip();
        }, "Bấm để xem các câu trước và sau", CopyMenu(entry.source, entry.translated));
    }

    UIElement StoryRow(StorySearchHit hit)
    {
        var q = results.query;
        var menu = new ContextMenu();
        var copy = new MenuItem { Header = "Copy" };
        copy.Click += (_, _) => Ui.CopyText($"{hit.title}\n{hit.body}");
        menu.Items.Add(copy);
        return HitFrame(isOpen =>
        {
            var right = new List<UIElement>();
            if (hit.date is DateTime d) right.Add(Ui.Text(HistorySearch.Date(d), 10.5, color: Ui.Tertiary, wrap: false));
            var title = HistorySearch.Text(hit.title, q, 14, weight: FontWeights.SemiBold);
            title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis;
            var head = Ui.Row(Ui.H(6, Ui.Text(hit.kindLabel, 11.5, true, Ui.AccentStart, wrap: false), title), right.ToArray());
            var v = Ui.V(4, head);
            if (hit.body.Length > 0) v.Children.Add(HistorySearch.Text(isOpen ? hit.body : HistorySearch.Snippet(hit.body, q), q, 13, Ui.Secondary));
            return v;
        }, (_, flip) => flip(), "Bấm để đọc toàn bộ / thu gọn", menu);
    }

    UIElement ScreenRow(ScreenAnalysis a)
    {
        var q = results.query;
        var matched = a.lines.Where(l => HistorySearch.Matches(l.source, q) || HistorySearch.Matches(l.target, q)).ToList();
        var source = string.Join("\n", a.lines.Select(l => l.source));
        var translated = string.Join("\n", new[] { a.summary, "" }.Concat(a.lines.Select(l => l.target)));
        return HitFrame(isOpen =>
        {
            var head = Ui.H(6, Ui.Icon(a.hasImage ? "" : "", 13, Ui.AccentStart),
                Ui.Text(HistorySearch.Date(a.timestamp), 11.5, color: Ui.Secondary, wrap: false));
            if (a.summary.Length > 0)
            {
                var sum = HistorySearch.Text(HistorySearch.Snippet(a.summary, q, 110), q, 13);
                sum.TextWrapping = TextWrapping.NoWrap; sum.TextTrimming = TextTrimming.CharacterEllipsis;
                head.Children.Add(sum);
            }
            var v = Ui.V(5, Ui.Row(head, Ui.Text(a.hasImage ? "Mở ảnh" : $"{a.lines.Count} dòng", 10.5, color: Ui.Tertiary, wrap: false)));
            foreach (var l in isOpen ? a.lines : matched.Take(2).ToList())
            {
                var g = new Grid { Margin = new Thickness(22, 0, 0, 0) };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var t = HistorySearch.Text(l.target, q, 13); t.Margin = new Thickness(0, 0, 16, 0);
                var s = HistorySearch.Text(l.source, q, 12, Ui.Secondary);
                Grid.SetColumn(s, 1);
                g.Children.Add(t); g.Children.Add(s);
                v.Children.Add(g);
            }
            return v;
        }, (_, flip) => { if (a.hasImage) ShotViewer.Show(a.id); else flip(); },
        a.hasImage ? "Bấm để mở ảnh đã dịch" : "Bấm để xem mọi dòng chữ", CopyMenu(source, translated));
    }
}
