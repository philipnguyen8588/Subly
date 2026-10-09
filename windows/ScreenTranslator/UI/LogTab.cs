using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Tab Nhật ký: phụ đề đã dịch, lịch sử dịch màn hình và các bản tóm tắt, cùng một thanh công cụ.
public sealed class LogTab : DockPanel
{
    enum Section { subtitles, screens, summaries }
    Section section = Section.subtitles;
    string search = "";
    /// Đang xem các dòng cũ không gắn với game nào.
    bool legacy;
    List<TranslationEntry> legacyEntries = new();
    List<ScreenAnalysis> legacyAnalyses = new();
    readonly HistoryStore store = HistoryStore.shared;
    readonly StorySummarizer summarizer = StorySummarizer.shared;
    readonly RadioButton subBtn, scrBtn, sumBtn;
    readonly Button exportBtn, clearBtn;
    readonly ToggleButton legacyBtn = new() { Content = "Dòng cũ" };
    readonly TextBox searchBox = new() { Width = 240 };
    readonly ContentControl content = new();
    readonly NowTranslatingPanel now = new();
    readonly ScrollViewer subScroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    readonly StackPanel subRows = new() { Margin = new Thickness(0, 6, 0, 6), Background = Brushes.Transparent };
    long lastNewest;
    /// Đổi game / xoá nhật ký → bỏ chọn.
    string lastListKey = "";
    readonly HashSet<long> expandedSummaries = new();

    // Các dòng đang chọn (để tóm tắt / copy). Chọn kiểu Finder: bấm = chọn một dòng, Shift-bấm = chọn từ dòng đã chọn đến dòng này,
    // Ctrl-bấm = thêm/bớt một dòng, kéo chuột = chọn liền một dải.
    readonly HashSet<long> selected = new();
    long? anchor;
    DragState? drag;
    /// Các dòng phụ đề đang hiện, cũ ở trên, mới ở dưới.
    List<TranslationEntry> rows = new();
    readonly Dictionary<long, RowView> rowViews = new();
    readonly Border selBar = new()
    {
        Padding = new Thickness(16, 8, 16, 8), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(0, 1, 0, 0), Background = Ui.Res("WindowBg"),
    };
    readonly DispatcherTimer edgeTimer = new() { Interval = TimeSpan.FromMilliseconds(60) };
    int edgeDir;
    bool keyHooked;

    sealed class DragState
    {
        public long start, current;
        public HashSet<long> baseSet = new();
        public bool adding = true, moved;
        /// Bấm lại đúng dòng duy nhất đang chọn (không kéo) → bỏ chọn.
        public bool tappedSoleSelection;
    }

    sealed class RowView
    {
        public Grid root = null!;
        public Border row = null!, bar = null!;
        public bool hover;
    }

    List<TranslationEntry> Entries => legacy ? legacyEntries : store.entries;
    List<ScreenAnalysis> Analyses => legacy ? legacyAnalyses : store.analyses;
    string ScopeName => legacy ? "dòng cũ chưa gắn game" : $"game “{AppSettings.shared.activeProfile.name}”";
    List<TranslationEntry> SelectedRows => rows.Where(r => selected.Contains(r.id)).ToList();

    string ClearTitle => section == Section.summaries ? "Xoá mọi bản tóm tắt của game này"
        : legacy ? "Xoá toàn bộ dòng cũ chưa gắn game"
        : section == Section.subtitles ? "Xoá nhật ký phụ đề của game này" : "Xoá lịch sử dịch màn hình của game này";
    string ClearQuestion => section == Section.summaries ? $"Xoá mọi bản tóm tắt của game “{AppSettings.shared.activeProfile.name}”?"
        : legacy ? "Xoá toàn bộ dòng cũ chưa gắn game (cả phụ đề và dịch màn hình)?"
        : section == Section.subtitles ? $"Xoá nhật ký phụ đề của {ScopeName}?" : $"Xoá lịch sử dịch màn hình và ảnh chụp của {ScopeName}?";

    public LogTab()
    {
        var tbStyle = (Style)Application.Current.FindResource(typeof(ToggleButton));
        subBtn = new RadioButton { GroupName = "logsec", IsChecked = true, Style = tbStyle };
        scrBtn = new RadioButton { GroupName = "logsec", Style = tbStyle };
        sumBtn = new RadioButton { GroupName = "logsec", Style = tbStyle };
        subBtn.Checked += (_, _) => { section = Section.subtitles; Rebuild(); };
        scrBtn.Checked += (_, _) => { section = Section.screens; Rebuild(); };
        sumBtn.Checked += (_, _) => { section = Section.summaries; Rebuild(); };
        legacyBtn.Checked += (_, _) => { legacy = true; legacyEntries = store.LegacyEntries(); legacyAnalyses = store.LegacyAnalyses(); Rebuild(); };
        legacyBtn.Unchecked += (_, _) => { legacy = false; legacyEntries = new(); legacyAnalyses = new(); Rebuild(); };
        searchBox.TextChanged += (_, _) => { search = searchBox.Text; ClearSelection(); Rebuild(); };
        exportBtn = Ui.IconBtn("", () => { }, "Xuất nhật ký (TXT / SRT / JSON)");
        var menu = new ContextMenu();
        foreach (var f in Enum.GetValues<Exporter.Format>())
        {
            var mi = new MenuItem { Header = Exporter.Label(f) };
            mi.Click += (_, _) => Exporter.Export(f, Entries, Analyses);
            menu.Items.Add(mi);
        }
        exportBtn.Click += (_, _) => { menu.PlacementTarget = exportBtn; menu.IsOpen = true; };
        clearBtn = Ui.IconBtn("", ConfirmClear, ClearTitle);
        var searchRow = Ui.H(6, Ui.Icon("", 13, Ui.Tertiary), searchBox);
        var toolbar = SourceTab.Toolbar(Ui.Row(Ui.H(10, Ui.H(0, subBtn, scrBtn, sumBtn), legacyBtn, searchRow), exportBtn, clearBtn));
        SetDock(toolbar, Dock.Top);
        Children.Add(toolbar);
        Children.Add(content);
        subScroll.Content = subRows;
        SetDock(selBar, Dock.Bottom);
        // Kéo chọn: chuột bị giữ bởi danh sách (không phải từng dòng) nên dựng lại danh sách giữa chừng vẫn kéo tiếp được.
        subRows.MouseMove += (_, e) => DragMoved(e);
        subRows.MouseLeftButtonUp += (_, _) => { EndDrag(); subRows.ReleaseMouseCapture(); };
        subRows.LostMouseCapture += (_, _) => EndDrag();
        edgeTimer.Tick += (_, _) => EdgeTick();
        store.Changed += () => Dispatcher.BeginInvoke(Rebuild);
        Pipeline.shared.analyzer.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(() => { if (section == Section.screens) Rebuild(); });
        summarizer.PropertyChanged += (_, e) => Dispatcher.BeginInvoke(() => SummarizerChanged(e.PropertyName));
        AppSettings.shared.Changed += k => { if (k is "activeProfileID" or "activeProfile") Dispatcher.BeginInvoke(() => legacyBtn.IsChecked = false); };
        // Esc = bỏ chọn.
        Loaded += (_, _) =>
        {
            if (keyHooked || Window.GetWindow(this) is not Window w) return;
            keyHooked = true;
            w.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != Key.Escape || !IsVisible || section != Section.subtitles || selected.Count == 0) return;
                ClearSelection(); e.Handled = true;
            };
        };
        Rebuild();
    }

    void SummarizerChanged(string? prop)
    {
        RefreshSelBar();
        // Tóm tắt xong khi đang xem mục Phụ đề → chuyển sang mục Tóm tắt để đọc ngay.
        if (prop == nameof(StorySummarizer.lastSavedID) && summarizer.lastSavedID != null && section == Section.subtitles) { sumBtn.IsChecked = true; return; }
        if (section == Section.summaries) Rebuild();
    }

    void ConfirmClear()
    {
        if (!Ui.Confirm(ClearQuestion)) return;
        if (section == Section.summaries) { store.ClearSummaries(); expandedSummaries.Clear(); }
        else if (legacy) { store.ClearLegacy(); legacyBtn.IsChecked = false; }
        else if (section == Section.subtitles) store.Clear();
        else store.ClearAnalyses();
    }

    void Rebuild()
    {
        subBtn.Content = $"Phụ đề  {Entries.Count}";
        scrBtn.Content = $"Dịch màn hình  {Analyses.Count}";
        sumBtn.Content = $"Tóm tắt  {store.summaries.Count}";
        legacyBtn.Visibility = store.legacyCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        legacyBtn.ToolTip = $"Nhật ký có từ trước khi tách theo game ({store.legacyCount} dòng, không gắn với game nào)";
        exportBtn.Visibility = section == Section.summaries ? Visibility.Collapsed : Visibility.Visible;
        clearBtn.ToolTip = ClearTitle;
        content.Content = section switch
        {
            Section.subtitles => SubtitleLog(),
            Section.screens => ScreenLog(),
            _ => SummaryLog(),
        };
    }

    // MARK: Phụ đề

    UIElement SubtitleLog()
    {
        var list = Entries.AsEnumerable();
        if (search.Length > 0)
        {
            var q = search.ToLowerInvariant();
            list = list.Where(e => e.source.ToLowerInvariant().Contains(q) || e.translated.ToLowerInvariant().Contains(q));
        }
        rows = list.Take(600).Reverse().ToList();   // cũ ở trên, mới ở dưới
        var listKey = $"{legacy}:{Entries.LastOrDefault()?.id ?? 0}";
        if (listKey != lastListKey) { selected.Clear(); anchor = null; }     // đổi game / xoá nhật ký
        lastListKey = listKey;
        rowViews.Clear();
        var dock = new DockPanel { Background = Brushes.White };
        SetDock(now, Dock.Bottom);
        dock.Children.Add(Ui.Detach(now));
        dock.Children.Add(Ui.Detach(selBar));   // nằm ngay trên khung "đang dịch"
        RefreshSelBar();
        if (rows.Count == 0)
        {
            dock.Children.Add(Ui.V(8, Ui.Icon("", 30, Ui.Tertiary),
                Ui.Text(Entries.Count == 0 ? "Các câu phụ đề đã dịch của game này sẽ hiện ở đây, mới nhất ở dưới cùng." : "Không có dòng nào khớp.", color: Ui.Tertiary))
                .Also(v => { v.HorizontalAlignment = HorizontalAlignment.Center; v.VerticalAlignment = VerticalAlignment.Center; foreach (FrameworkElement c in v.Children) c.HorizontalAlignment = HorizontalAlignment.Center; }));
            return dock;
        }
        bool atBottom = subScroll.VerticalOffset >= subScroll.ScrollableHeight - 4;
        subRows.Children.Clear();
        var header = new Grid { Margin = new Thickness(28, 6, 28, 6) };
        header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) }); header.ColumnDefinitions.Add(new ColumnDefinition());
        var h1 = Ui.Text("BẢN DỊCH", 10.5, true, Ui.Tertiary);
        var h2 = new DockPanel();
        var h2l = Ui.Text("CÂU GỐC", 10.5, true, Ui.Tertiary).Also(t => t.Margin = new Thickness(0, 0, 8, 0));
        SetDock(h2l, Dock.Left);
        h2.Children.Add(h2l);
        h2.Children.Add(Ui.Text("Kéo chuột hoặc Shift-bấm để chọn nhiều câu rồi Tóm tắt", 10.5, color: Ui.Tertiary, wrap: false).Also(t => t.TextAlignment = TextAlignment.Right));
        Grid.SetColumn(h2, 2); header.Children.Add(h1); header.Children.Add(h2);
        subRows.Children.Add(header);
        for (int i = 0; i < rows.Count; i++)
        {
            var e = rows[i];
            // Cách nhau > 45 giây coi như sang đoạn hội thoại khác → chèn mốc giờ.
            if (i == 0 || (e.timestamp - rows[i - 1].timestamp).TotalSeconds > 45) subRows.Children.Add(TimeMarker(e.timestamp, i == 0));
            subRows.Children.Add(SubtitleRow(e));
        }
        dock.Children.Add(Ui.Detach(subScroll));
        long newest = Entries.FirstOrDefault()?.id ?? 0;
        if (atBottom || newest != lastNewest || search.Length > 0) Dispatcher.BeginInvoke(() => subScroll.ScrollToEnd(), DispatcherPriority.Loaded);
        lastNewest = newest;
        return dock;
    }

    static UIElement TimeMarker(DateTime t, bool first)
    {
        var g = new Grid { Margin = new Thickness(28, first ? 2 : 14, 28, 6) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var l1 = new Border { Height = 1, Background = Ui.Res("CardStroke") };
        var l2 = new Border { Height = 1, Background = Ui.Res("CardStroke") };
        var pill = new Border { CornerRadius = new CornerRadius(9), Background = Ui.Res("CardFill"), Padding = new Thickness(9, 2, 9, 2), Margin = new Thickness(10, 0, 10, 0), Child = Ui.Text($"{t:HH:mm}", 11, color: Ui.Secondary) };
        Grid.SetColumn(pill, 1); Grid.SetColumn(l2, 2);
        g.Children.Add(l1); g.Children.Add(pill); g.Children.Add(l2);
        return g;
    }

    UIElement SubtitleRow(TranslationEntry e)
    {
        // Câu quá đơn giản không được dịch: chỉ hiện câu gốc, mờ, ở cột câu gốc.
        bool skipped = e.backend == BackendKind.skipped.ToString();
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var tr = skipped ? Ui.Text("—", 15, color: Ui.Tertiary) : Ui.Styled(e.translated, 15);
        var src = Ui.Styled(e.source, 14, color: Ui.Secondary);
        Grid.SetColumn(src, 2);
        g.Children.Add(tr); g.Children.Add(src);
        var tools = Ui.H(4, Ui.Text($"{e.timestamp:HH:mm:ss} · {BackendLabels.Label(e.backend)} · {e.latencyMs} ms", 10.5, color: Ui.Secondary),
            Ui.IconBtn("", () => Ui.CopyText(e.translated), "Copy bản dịch").Also(b => b.Padding = new Thickness(4, 1, 4, 1)),
            Ui.IconBtn("", () => Ui.CopyText(e.source), "Copy câu gốc").Also(b => b.Padding = new Thickness(4, 1, 4, 1)));
        var toolBox = new Border
        {
            Child = tools, Background = Brushes.White, CornerRadius = new CornerRadius(10), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1),
            Padding = new Thickness(8, 2, 8, 2), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -12, 8, 0), Visibility = Visibility.Collapsed,
        };
        var cell = new Grid();
        cell.Children.Add(g);
        cell.Children.Add(toolBox);
        var row = new Border { Child = cell, Padding = new Thickness(14, 7, 14, 7), CornerRadius = new CornerRadius(8), Background = Brushes.Transparent };
        // Vạch nhấn bên trái dòng đang chọn.
        var bar = new Border
        {
            Width = 3, CornerRadius = new CornerRadius(1.5), Background = Ui.AccentStart, HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 5, 0, 5), Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        };
        var root = new Grid { Margin = new Thickness(14, 0, 14, 0) };
        root.Children.Add(row); root.Children.Add(bar);
        var rv = new RowView { root = root, row = row, bar = bar };
        row.MouseEnter += (_, _) => { rv.hover = true; toolBox.Visibility = Visibility.Visible; Paint(e.id, rv); };
        row.MouseLeave += (_, _) => { rv.hover = false; toolBox.Visibility = Visibility.Collapsed; Paint(e.id, rv); };
        // Nút copy tự xử lý cú bấm nên không lọt tới đây.
        root.MouseLeftButtonDown += (_, ev) => { BeginDrag(e.id); subRows.CaptureMouse(); ev.Handled = true; };
        var cm = new ContextMenu();
        root.ContextMenu = cm;
        root.ContextMenuOpening += (_, _) => FillRowMenu(cm, e);
        rowViews[e.id] = rv;
        Paint(e.id, rv);
        return root;
    }

    void Paint(long id, RowView rv)
    {
        bool on = selected.Contains(id);
        rv.row.Background = on ? new SolidColorBrush(Color.FromArgb(46, 97, 111, 250))
                          : rv.hover ? new SolidColorBrush(Color.FromArgb(18, 97, 111, 250)) : Brushes.Transparent;
        rv.bar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
    }

    void SelectionChanged()
    {
        foreach (var (id, rv) in rowViews) Paint(id, rv);
        RefreshSelBar();
    }

    void FillRowMenu(ContextMenu cm, TranslationEntry e)
    {
        cm.Items.Clear();
        int count = selected.Contains(e.id) ? SelectedRows.Count : 0;
        if (count > 1)
        {
            cm.Items.Add(Mi($"Tóm tắt {count} câu đã chọn", Summarize, "", !summarizer.isRunning));
            cm.Items.Add(Mi($"Copy bản dịch {count} câu", () => CopySelection(true)));
            cm.Items.Add(Mi($"Copy bản gốc {count} câu", () => CopySelection(false), ""));
            cm.Items.Add(new Separator());
        }
        bool skipped = e.backend == BackendKind.skipped.ToString();
        var tr = skipped ? e.source : e.translated;
        cm.Items.Add(Mi("Copy bản gốc", () => Ui.CopyText(e.source), ""));
        cm.Items.Add(Mi("Copy bản dịch", () => Ui.CopyText(tr)));
        cm.Items.Add(Mi("Copy cả hai", () => Ui.CopyText($"{e.source}\n{tr}")));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Thêm tên nhân vật…", () => Dispatcher.BeginInvoke(() => AddSpeakerDialog.Open(e.source, this)), ""));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Chọn cả đoạn hội thoại này", () => SelectConversation(e.id)));
        cm.Items.Add(Mi("Chọn từ câu này đến mới nhất", () => SelectToNewest(e.id)));
    }

    static MenuItem Mi(string header, Action onClick, string? glyph = null, bool enabled = true)
    {
        var mi = new MenuItem { Header = header, IsEnabled = enabled };
        if (glyph != null) mi.Icon = Ui.Icon(glyph, 13);
        mi.Click += (_, _) => onClick();
        return mi;
    }

    /// Menu chuột phải: copy bản gốc / bản dịch / cả hai.
    public static ContextMenu CopyMenu(Func<string> source, Func<string> translated)
    {
        var cm = new ContextMenu();
        cm.Items.Add(Mi("Copy bản gốc", () => Ui.CopyText(source()), ""));
        cm.Items.Add(Mi("Copy bản dịch", () => Ui.CopyText(translated())));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Copy cả hai", () => Ui.CopyText($"{source()}\n{translated()}")));
        return cm;
    }

    // MARK: thanh chọn

    void RefreshSelBar()
    {
        var sel = SelectedRows;
        bool show = section == Section.subtitles && (sel.Count > 0 || summarizer.isRunning || summarizer.lastError != null);
        selBar.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) { selBar.Child = null; return; }
        var left = Ui.H(10);
        var right = new List<UIElement>();
        if (summarizer.isRunning)
        {
            left.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 36, Height = 4, VerticalAlignment = VerticalAlignment.Center });
            left.Children.Add(new Border { Width = 10 });
            left.Children.Add(Ui.Text($"Đang tóm tắt {summarizer.runningCount} câu…", wrap: false));
        }
        else if (summarizer.lastError is string err && sel.Count == 0)
        {
            left.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(err, 11.5, color: Ui.Danger).Also(t => t.MaxHeight = 32)));
            right.Add(Ui.LinkBtn("Đóng", summarizer.DismissError));
        }
        if (sel.Count > 0)
        {
            if (summarizer.isRunning) left.Children.Add(new Border { Width = 1, Height = 16, Background = Ui.Res("CardStroke"), Margin = new Thickness(10, 0, 10, 0) });
            string f = $"{sel[0].timestamp:HH:mm}", l = $"{sel[^1].timestamp:HH:mm}";
            left.Children.Add(Ui.H(8, Ui.Icon("", 14, Ui.AccentStart), Ui.Text($"Đã chọn {sel.Count} câu", bold: true, wrap: false),
                Ui.Text(f == l ? f : $"{f} – {l}", 11.5, color: Ui.Secondary, wrap: false)));
            var copyBtn = Ui.Btn(Ui.IconLabel("", "Copy"), () => { });
            var copyMenu = new ContextMenu();
            copyMenu.Items.Add(Mi("Copy bản dịch", () => CopySelection(true)));
            copyMenu.Items.Add(Mi("Copy bản gốc", () => CopySelection(false)));
            copyBtn.Click += (_, _) => { copyMenu.PlacementTarget = copyBtn; copyMenu.IsOpen = true; };
            right.Add(copyBtn);
            right.Add(Ui.Btn("Bỏ chọn", ClearSelection, tip: "Bỏ chọn (Esc)"));
            right.Add(Ui.Btn(Ui.IconLabel("", "Tóm tắt"), Summarize, primary: true, tip: "Tóm tắt nội dung các câu đã chọn; bản tóm tắt được lưu ở mục Tóm tắt")
                .Also(b => b.IsEnabled = !summarizer.isRunning));
        }
        selBar.Child = Ui.Row(left, right.ToArray());
    }

    void Summarize()
    {
        var sel = SelectedRows;
        if (sel.Count == 0) return;
        summarizer.Summarize(sel);
        ClearSelection();
    }

    void CopySelection(bool translated)
    {
        var skipped = BackendKind.skipped.ToString();
        Ui.CopyText(string.Join("\n", SelectedRows.Select(e => translated && e.backend != skipped ? e.translated : e.source)));
    }

    void ClearSelection()
    {
        selected.Clear(); anchor = null;
        SelectionChanged();
    }

    void SelectConversation(long id)
    {
        int lo = rows.FindIndex(r => r.id == id);
        if (lo < 0) return;
        int hi = lo;
        while (lo > 0 && (rows[lo].timestamp - rows[lo - 1].timestamp).TotalSeconds <= 45) lo--;
        while (hi < rows.Count - 1 && (rows[hi + 1].timestamp - rows[hi].timestamp).TotalSeconds <= 45) hi++;
        selected.Clear();
        foreach (var r in rows.Skip(lo).Take(hi - lo + 1)) selected.Add(r.id);
        anchor = id;
        SelectionChanged();
    }

    void SelectToNewest(long id)
    {
        int i = rows.FindIndex(r => r.id == id);
        if (i < 0) return;
        selected.Clear();
        foreach (var r in rows.Skip(i)) selected.Add(r.id);
        anchor = id;
        SelectionChanged();
    }

    // MARK: kéo chọn

    void BeginDrag(long id)
    {
        // Nhịp đầu của cú bấm: quyết định kiểu chọn theo phím đang giữ.
        var mods = Keyboard.Modifiers;
        bool shift = mods.HasFlag(ModifierKeys.Shift), ctrl = mods.HasFlag(ModifierKeys.Control);
        if (shift && anchor is long a && rows.Any(r => r.id == a))
            drag = new DragState { start = a, current = id, baseSet = ctrl ? new(selected) : new() };
        else if (ctrl)
        {
            drag = new DragState { start = id, current = id, baseSet = new(selected), adding = !selected.Contains(id) };
            anchor = id;
        }
        else
        {
            drag = new DragState { start = id, current = id, tappedSoleSelection = selected.Count == 1 && selected.Contains(id) };
            anchor = id;
        }
        Apply();
    }

    void DragMoved(MouseEventArgs e)
    {
        if (drag is not DragState d || e.LeftButton != MouseButtonState.Pressed) return;
        if (RowAt(e.GetPosition(subRows).Y) is long target && target != d.current)
        {
            d.current = target; d.moved = true;
            Apply();
        }
        // Kéo chạm mép trên/dưới vùng nhìn thấy → tự cuộn và chọn tiếp từng dòng, đến khi chuột rời mép hoặc thả ra.
        double y = e.GetPosition(subScroll).Y;
        edgeDir = y < 30 ? -1 : y > subScroll.ActualHeight - 30 ? 1 : 0;
        if (edgeDir == 0) edgeTimer.Stop();
        else if (!edgeTimer.IsEnabled) edgeTimer.Start();
    }

    void EndDrag()
    {
        if (drag is not DragState d) return;
        drag = null;
        edgeTimer.Stop();
        if (d.tappedSoleSelection && !d.moved) ClearSelection();
    }

    void EdgeTick()
    {
        if (drag is not DragState d || edgeDir == 0) { edgeTimer.Stop(); return; }
        int j = rows.FindIndex(r => r.id == d.current);
        if (j < 0 || j + edgeDir < 0 || j + edgeDir >= rows.Count) { edgeTimer.Stop(); return; }
        d.current = rows[j + edgeDir].id; d.moved = true;
        Apply();
        if (rowViews.TryGetValue(d.current, out var rv)) rv.root.BringIntoView();
    }

    void Apply()
    {
        if (drag is not DragState d) return;
        int i = rows.FindIndex(r => r.id == d.start), j = rows.FindIndex(r => r.id == d.current);
        if (i < 0 || j < 0) return;
        var range = rows.Skip(Math.Min(i, j)).Take(Math.Abs(i - j) + 1).Select(r => r.id);
        selected.Clear();
        selected.UnionWith(d.baseSet);
        if (d.adding) selected.UnionWith(range); else selected.ExceptWith(range);
        SelectionChanged();
    }

    /// Dòng nằm dưới chuột; chuột ở khe giữa hai dòng (mốc giờ) thì lấy dòng gần nhất.
    long? RowAt(double y)
    {
        long? best = null; double bestDist = double.MaxValue;
        foreach (var r in rows)
        {
            if (!rowViews.TryGetValue(r.id, out var rv) || !rv.root.IsLoaded) continue;
            double top = rv.root.TranslatePoint(new Point(0, 0), subRows).Y, bottom = top + rv.root.ActualHeight;
            if (y >= top && y < bottom) return r.id;
            double dist = Math.Min(Math.Abs(top - y), Math.Abs(bottom - y));
            if (dist < bestDist) { bestDist = dist; best = r.id; }
        }
        return best;
    }

    // MARK: Dịch màn hình

    /// Toàn bộ chữ gốc của một lần dịch màn hình, mỗi khối một dòng.
    static string SourceText(ScreenAnalysis a) => string.Join("\n", a.lines.Select(l => l.source));
    /// Tóm tắt + bản dịch từng khối.
    static string TranslatedText(ScreenAnalysis a) => string.Join("\n", new[] { a.summary, "" }.Concat(a.lines.Select(l => l.target)));

    UIElement ScreenLog()
    {
        var all = Analyses;
        var rows = all.AsEnumerable();
        if (search.Length > 0)
        {
            var q = search.ToLowerInvariant();
            rows = rows.Where(a => a.summary.ToLowerInvariant().Contains(q) || a.lines.Any(l => l.source.ToLowerInvariant().Contains(q) || l.target.ToLowerInvariant().Contains(q)));
        }
        var list = rows.ToList();
        var shots = list.Where(a => a.hasImage).ToList();
        var textOnly = list.Where(a => !a.hasImage).ToList();
        var v = Ui.V(12);
        if (Pipeline.shared.analyzer.lastError is string err) v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(err, 11.5, color: Ui.Danger)));
        if (list.Count == 0)
        {
            v.Children.Add(Ui.Text(all.Count == 0 ? "Mỗi lần bấm “Dịch màn hình” trong game này sẽ được lưu lại ở đây kèm ảnh chụp." : "Không có mục nào khớp.", color: Ui.Tertiary)
                .Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 60, 0, 0); }));
            return new Border { Background = Brushes.White, Child = v, Padding = new Thickness(14) };
        }
        if (shots.Count > 0)
        {
            var wrap = new WrapPanel();
            foreach (var a in shots) wrap.Children.Add(ShotCard(a));
            v.Children.Add(wrap);
        }
        if (textOnly.Count > 0)
        {
            v.Children.Add(Ui.Text(shots.Count == 0 ? "CHỈ CÒN CHỮ" : $"CŨ HƠN · CHỈ CÒN CHỮ (mỗi game giữ {HistoryStore.maxShots} ảnh gần nhất)", 10.5, true, Ui.Tertiary));
            foreach (var a in textOnly) v.Children.Add(ScreenLogCard(a));
        }
        v.Margin = new Thickness(14);
        return new Border { Background = Brushes.White, Child = Ui.Scroll(v) };
    }

    /// Một lần chụp còn ảnh: bấm để mở lại ảnh đã dịch.
    static UIElement ShotCard(ScreenAnalysis a)
    {
        var img = new Image { Stretch = Stretch.Uniform, Height = 135 };
        var thumb = new Border { Background = Brushes.Black, CornerRadius = new CornerRadius(7), Height = 135, Child = img, ClipToBounds = true };
        Task.Run(() => ShotImages.Load(a.id, 480)).ContinueWith(t => img.Source = t.Result, TaskScheduler.FromCurrentSynchronizationContext());
        var v = Ui.V(6, thumb,
            Ui.Text(a.summary, 12.5).Also(t => { t.MaxHeight = 36; t.TextTrimming = TextTrimming.WordEllipsis; }),
            Ui.Text($"{a.timestamp:dd/MM/yyyy HH:mm} · {a.items.Count} khối chữ", 10.5, color: Ui.Tertiary));
        var card = new Border
        {
            Child = v, Width = 240, Padding = new Thickness(8), Margin = new Thickness(0, 0, 12, 12), CornerRadius = new CornerRadius(10),
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), Cursor = Cursors.Hand,
            ToolTip = "Mở lại ảnh đã dịch · chuột phải để copy", ContextMenu = CopyMenu(() => SourceText(a), () => TranslatedText(a)),
        };
        card.MouseEnter += (_, _) => card.BorderBrush = new SolidColorBrush(Color.FromArgb(128, 97, 111, 250));
        card.MouseLeave += (_, _) => card.BorderBrush = Ui.Res("CardStroke");
        card.MouseLeftButtonUp += (_, _) => ShotViewer.Show(a.id);
        return card;
    }

    static UIElement ScreenLogCard(ScreenAnalysis a)
    {
        bool expanded = false;
        var chevron = Ui.Icon("", 10, Ui.Secondary);
        var summary = Ui.Text(a.summary, 14.5).Also(t => { t.MaxHeight = 42; t.TextTrimming = TextTrimming.WordEllipsis; });
        var meta = Ui.Text($"{a.timestamp:HH:mm:ss} · {a.lines.Count} khối chữ · {BackendLabels.Label(a.backend)} · {a.latencyMs / 1000.0:0.0} s", 10.5, color: Ui.Tertiary);
        var copy = Ui.IconBtn("", () => Ui.CopyText($"{a.summary}\n\n" + string.Join("\n\n", a.lines.Select(l => $"{l.source}\n→ {l.target}"))), "Copy toàn bộ");
        var head = Ui.Row(Ui.H(8, chevron, Ui.V(3, summary, meta)), copy);
        var detail = Ui.V(0);
        detail.Visibility = Visibility.Collapsed;
        detail.Margin = new Thickness(20, 6, 0, 0);
        foreach (var l in a.lines)
        {
            var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
            g.ColumnDefinitions.Add(new ColumnDefinition()); g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) }); g.ColumnDefinitions.Add(new ColumnDefinition());
            var t1 = Ui.Text(l.target, 14); var t2 = Ui.Text(l.source, 13.5, color: Ui.Secondary);
            Grid.SetColumn(t2, 2); g.Children.Add(t1); g.Children.Add(t2);
            detail.Children.Add(g);
        }
        head.Cursor = Cursors.Hand;
        head.MouseLeftButtonUp += (_, _) =>
        {
            expanded = !expanded;
            detail.Visibility = expanded && a.lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            chevron.Text = expanded ? "" : "";
            summary.MaxHeight = expanded ? double.PositiveInfinity : 42;
        };
        return new Border
        {
            Child = Ui.V(6, head, detail), Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(10),
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1),
            ContextMenu = CopyMenu(() => SourceText(a), () => TranslatedText(a)),
        };
    }

    // MARK: Tóm tắt

    /// Mục "Tóm tắt": các bản tóm tắt cốt truyện người dùng đã tạo từ phụ đề, mới nhất trước.
    UIElement SummaryLog()
    {
        var all = store.summaries;
        var list = all.AsEnumerable();
        if (search.Length > 0)
        {
            var q = search.ToLowerInvariant();
            list = list.Where(s => s.title.ToLowerInvariant().Contains(q) || s.summary.ToLowerInvariant().Contains(q));
        }
        var rows = list.ToList();
        if (rows.Count == 0 && !summarizer.isRunning)
        {
            var empty = Ui.V(8, Ui.Icon("", 30, Ui.Tertiary),
                Ui.Text(all.Count == 0
                    ? "Ở mục Phụ đề, chọn nhiều câu (kéo chuột, hoặc bấm một câu rồi Shift-bấm câu khác) và bấm Tóm tắt.\nBản tóm tắt của game này sẽ được lưu ở đây."
                    : "Không có bản tóm tắt nào khớp.", color: Ui.Tertiary).Also(t => t.TextAlignment = TextAlignment.Center));
            empty.HorizontalAlignment = HorizontalAlignment.Center; empty.VerticalAlignment = VerticalAlignment.Center;
            foreach (FrameworkElement c in empty.Children) c.HorizontalAlignment = HorizontalAlignment.Center;
            return new Border { Background = Brushes.White, Child = empty };
        }
        var v = Ui.V(12);
        if (summarizer.isRunning)
            v.Children.Add(new Border
            {
                Padding = new Thickness(14), CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Color.FromArgb(18, 97, 111, 250)),
                Child = Ui.H(10, new ProgressBar { IsIndeterminate = true, Width = 36, Height = 4 }, Ui.Text($"Đang tóm tắt {summarizer.runningCount} câu…", color: Ui.Secondary)),
            });
        if (summarizer.lastError is string err) v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(err, 11.5, color: Ui.Danger)));
        foreach (var s in rows) v.Children.Add(SummaryCard(s));
        v.Margin = new Thickness(14);
        return new Border { Background = Brushes.White, Child = Ui.Scroll(v) };
    }

    UIElement SummaryCard(StorySummary s)
    {
        string day = $"{s.from:dd/MM/yyyy}", f = $"{s.from:HH:mm}", t = $"{s.to:HH:mm}";
        var timeRange = f == t ? $"{day} {f}" : $"{day} {f} – {t}";
        var plain = $"{s.title}\n\n{s.summary}";
        // Câu thoại kèm bản dịch, dùng khi copy.
        var dialog = string.Join("\n", s.lines.Select(l => l.target.Length == 0 ? l.source : $"{l.target}\n   {l.source}"));
        void Delete()
        {
            if (!Ui.Confirm($"Xoá bản tóm tắt “{s.title}”?")) return;
            expandedSummaries.Remove(s.id);
            store.DeleteSummary(s.id);
        }
        var tools = Ui.H(6, Ui.IconBtn("", () => Ui.CopyText(plain), "Copy bản tóm tắt"), Ui.IconBtn("", Delete, "Xoá bản tóm tắt này"));
        tools.Opacity = 0;
        tools.VerticalAlignment = VerticalAlignment.Top;
        var titleBox = new DockPanel();
        var icon = Ui.Icon("", 15, Ui.AccentStart).Also(i => { i.VerticalAlignment = VerticalAlignment.Top; i.Margin = new Thickness(0, 2, 10, 0); });
        SetDock(icon, Dock.Left);
        titleBox.Children.Add(icon);
        titleBox.Children.Add(Ui.V(3, Ui.Text(s.title, 15.5, true),
            Ui.Text($"{s.lines.Count} câu · {timeRange} · {BackendLabels.Label(s.backend)} · {s.latencyMs / 1000.0:0.0} s", 10.5, color: Ui.Tertiary)));
        var head = Ui.Row(titleBox, tools);
        var body = new TextBox
        {
            Text = s.summary, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = 14.5, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Padding = new Thickness(0), Margin = new Thickness(-2, 0, 0, 0),
        };
        bool expanded = expandedSummaries.Contains(s.id);
        var detail = Ui.V(0, Ui.Divider());
        foreach (var l in s.lines)
        {
            var g = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            g.ColumnDefinitions.Add(new ColumnDefinition()); g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) }); g.ColumnDefinitions.Add(new ColumnDefinition());
            var t1 = l.target.Length == 0 ? Ui.Text("—", 13.5, color: Ui.Tertiary) : Ui.Styled(l.target, 13.5);
            var t2 = Ui.Styled(l.source, 13, color: Ui.Secondary);
            Grid.SetColumn(t2, 2); g.Children.Add(t1); g.Children.Add(t2);
            detail.Children.Add(g);
        }
        detail.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        var chevron = Ui.Icon(expanded ? "" : "", 9, Ui.AccentStart);
        var toggleText = Ui.Text(expanded ? "Ẩn câu thoại" : $"Xem {s.lines.Count} câu thoại", 11.5, color: Ui.AccentStart, wrap: false, weight: FontWeights.Medium);
        var toggle = new Button { Content = Ui.H(5, chevron, toggleText), Style = (Style)Application.Current.FindResource("LinkButton"), HorizontalAlignment = HorizontalAlignment.Left };
        toggle.Click += (_, _) =>
        {
            expanded = !expanded;
            if (expanded) expandedSummaries.Add(s.id); else expandedSummaries.Remove(s.id);
            detail.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            chevron.Text = expanded ? "" : "";
            toggleText.Text = expanded ? "Ẩn câu thoại" : $"Xem {s.lines.Count} câu thoại";
        };
        var cm = new ContextMenu();
        cm.Items.Add(Mi("Copy bản tóm tắt", () => Ui.CopyText(plain), ""));
        cm.Items.Add(Mi("Copy kèm câu thoại", () => Ui.CopyText($"{plain}\n\n---\n{dialog}")));
        cm.Items.Add(new Separator());
        cm.Items.Add(Mi("Xoá", Delete, ""));
        var card = new Border
        {
            Child = Ui.V(8, head, body, toggle, detail), Padding = new Thickness(12), CornerRadius = new CornerRadius(10),
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), ContextMenu = cm,
        };
        card.MouseEnter += (_, _) => { tools.Opacity = 1; card.Background = new SolidColorBrush(Color.FromArgb(13, 0, 0, 0)); };
        card.MouseLeave += (_, _) => { tools.Opacity = 0; card.Background = Ui.Res("CardFill"); };
        return card;
    }
}

/// Khu vực cố định ở đáy tab Nhật ký: câu phụ đề đang được dịch lúc này.
public sealed class NowTranslatingPanel : Border
{
    public NowTranslatingPanel()
    {
        Padding = new Thickness(22, 10, 22, 14);
        MinHeight = 104;
        BorderBrush = new SolidColorBrush(Color.FromArgb(64, 97, 111, 250)); BorderThickness = new Thickness(0, 1, 0, 0);
        Background = new LinearGradientBrush(Color.FromArgb(26, 97, 111, 250), Color.FromArgb(13, 41, 194, 179), 0);
        ContextMenu = LogTab.CopyMenu(() => Pipeline.shared.lastSource, () => Pipeline.shared.lastTranslated);
        Pipeline.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        Pipeline.shared.router.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        Refresh();
    }

    void Refresh()
    {
        var p = Pipeline.shared; var router = p.router;
        var head = Ui.H(6, Ui.Dot(p.isRunning ? Brushes.LimeGreen : Ui.Tertiary, 7), Ui.Text(p.isRunning ? "ĐANG DỊCH" : "ĐÃ DỪNG", 10.5, true, Ui.Secondary));
        if (p.lastBackend is BackendKind b && p.lastTranslated.Length > 0)
            head.Children.Add(Ui.Text($"· {(b == BackendKind.gemini ? router.activeModel ?? "Gemini" : BackendLabels.Label(b))} · {p.lastMs} ms", 10.5, color: Ui.Tertiary).Also(t => t.Margin = new Thickness(6, 0, 0, 0)));
        UIElement top = p.lastTranslated.Length > 0 ? Ui.Row(head, Ui.IconBtn("", () => Ui.CopyText(p.lastTranslated), "Copy bản dịch")) : head;
        var v = Ui.V(6, top);
        if (router.lastError is string e) v.Children.Add(Ui.H(6, Ui.Icon("", 12, Ui.Danger), Ui.Text(e, 11.5, color: Ui.Danger)));
        if (p.lastTranslated.Length == 0)
            v.Children.Add(Ui.Text(p.isRunning ? "Đang chờ phụ đề xuất hiện…" : "Bấm Bắt đầu để dịch phụ đề.", 17, color: Ui.Tertiary).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 10, 0, 10); }));
        else
        {
            v.Children.Add(Ui.Styled(p.lastTranslated, 21, weight: FontWeights.SemiBold).Also(t => { t.TextAlignment = TextAlignment.Center; t.HorizontalAlignment = HorizontalAlignment.Center; t.MaxHeight = 150; }));
            v.Children.Add(Ui.Text(p.lastSource, 13.5, color: Ui.Secondary).Also(t => { t.TextAlignment = TextAlignment.Center; t.HorizontalAlignment = HorizontalAlignment.Center; t.MaxHeight = 60; }));
        }
        Child = v;
    }
}
