using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace ScreenTranslator;

/// Tab Nhật ký: phụ đề đã dịch và lịch sử dịch màn hình, cùng một thanh công cụ.
public sealed class LogTab : DockPanel
{
    enum Section { subtitles, screens }
    Section section = Section.subtitles;
    string search = "";
    /// Đang xem các dòng cũ không gắn với game nào.
    bool legacy;
    List<TranslationEntry> legacyEntries = new();
    List<ScreenAnalysis> legacyAnalyses = new();
    readonly HistoryStore store = HistoryStore.shared;
    readonly RadioButton subBtn, scrBtn;
    readonly ToggleButton legacyBtn = new() { Content = "Dòng cũ" };
    readonly TextBox searchBox = new() { Width = 240 };
    readonly ContentControl content = new();
    readonly NowTranslatingPanel now = new();
    readonly ScrollViewer subScroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    readonly StackPanel subRows = new() { Margin = new Thickness(0, 6, 0, 6) };
    long lastNewest;

    List<TranslationEntry> Entries => legacy ? legacyEntries : store.entries;
    List<ScreenAnalysis> Analyses => legacy ? legacyAnalyses : store.analyses;
    string ScopeName => legacy ? "dòng cũ chưa gắn game" : $"game “{AppSettings.shared.activeProfile.name}”";

    public LogTab()
    {
        var tbStyle = (Style)Application.Current.FindResource(typeof(ToggleButton));
        subBtn = new RadioButton { GroupName = "logsec", IsChecked = true, Style = tbStyle };
        scrBtn = new RadioButton { GroupName = "logsec", Style = tbStyle };
        subBtn.Checked += (_, _) => { section = Section.subtitles; Rebuild(); };
        scrBtn.Checked += (_, _) => { section = Section.screens; Rebuild(); };
        legacyBtn.Checked += (_, _) => { legacy = true; legacyEntries = store.LegacyEntries(); legacyAnalyses = store.LegacyAnalyses(); Rebuild(); };
        legacyBtn.Unchecked += (_, _) => { legacy = false; legacyEntries = new(); legacyAnalyses = new(); Rebuild(); };
        searchBox.TextChanged += (_, _) => { search = searchBox.Text; Rebuild(); };
        var exportBtn = Ui.IconBtn("", () => { }, "Xuất nhật ký (TXT / SRT / JSON)");
        var menu = new ContextMenu();
        foreach (var f in Enum.GetValues<Exporter.Format>())
        {
            var mi = new MenuItem { Header = Exporter.Label(f) };
            mi.Click += (_, _) => Exporter.Export(f, Entries, Analyses);
            menu.Items.Add(mi);
        }
        exportBtn.Click += (_, _) => { menu.PlacementTarget = exportBtn; menu.IsOpen = true; };
        var clearBtn = Ui.IconBtn("", ConfirmClear, "Xoá nhật ký của game này");
        var searchRow = Ui.H(6, Ui.Icon("", 13, Ui.Tertiary), searchBox);
        var toolbar = SourceTab.Toolbar(Ui.Row(Ui.H(10, Ui.H(0, subBtn, scrBtn), legacyBtn, searchRow), exportBtn, clearBtn));
        SetDock(toolbar, Dock.Top);
        Children.Add(toolbar);
        Children.Add(content);
        subScroll.Content = subRows;
        store.Changed += () => Dispatcher.BeginInvoke(Rebuild);
        Pipeline.shared.analyzer.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(() => { if (section == Section.screens) Rebuild(); });
        AppSettings.shared.Changed += k => { if (k is "activeProfileID" or "activeProfile") Dispatcher.BeginInvoke(() => legacyBtn.IsChecked = false); };
        Rebuild();
    }

    void ConfirmClear()
    {
        var msg = legacy ? "Xoá toàn bộ dòng cũ chưa gắn game (cả phụ đề và dịch màn hình)?"
                         : section == Section.subtitles ? $"Xoá nhật ký phụ đề của {ScopeName}?" : $"Xoá lịch sử dịch màn hình và ảnh chụp của {ScopeName}?";
        if (!Ui.Confirm(msg)) return;
        if (legacy) { store.ClearLegacy(); legacyBtn.IsChecked = false; }
        else if (section == Section.subtitles) store.Clear();
        else store.ClearAnalyses();
    }

    void Rebuild()
    {
        subBtn.Content = $"Phụ đề  {Entries.Count}";
        scrBtn.Content = $"Dịch màn hình  {Analyses.Count}";
        legacyBtn.Visibility = store.legacyCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        legacyBtn.ToolTip = $"Nhật ký có từ trước khi tách theo game ({store.legacyCount} dòng, không gắn với game nào)";
        content.Content = section == Section.subtitles ? SubtitleLog() : ScreenLog();
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
        var rows = list.Take(600).Reverse().ToList();   // cũ ở trên, mới ở dưới
        var dock = new DockPanel { Background = Brushes.White };
        SetDock(now, Dock.Bottom);
        if (now.Parent is Panel p) p.Children.Remove(now);
        dock.Children.Add(now);
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
        header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition());
        var h1 = Ui.Text("BẢN DỊCH", 10.5, true, Ui.Tertiary); var h2 = Ui.Text("CÂU GỐC", 10.5, true, Ui.Tertiary);
        Grid.SetColumn(h2, 1); header.Children.Add(h1); header.Children.Add(h2);
        subRows.Children.Add(header);
        for (int i = 0; i < rows.Count; i++)
        {
            var e = rows[i];
            // Cách nhau > 45 giây coi như sang đoạn hội thoại khác → chèn mốc giờ.
            if (i == 0 || (e.timestamp - rows[i - 1].timestamp).TotalSeconds > 45) subRows.Children.Add(TimeMarker(e.timestamp, i == 0));
            subRows.Children.Add(SubtitleRow(e));
        }
        if (subScroll.Parent is Panel sp) sp.Children.Remove(subScroll);
        dock.Children.Add(subScroll);
        long newest = Entries.FirstOrDefault()?.id ?? 0;
        if (atBottom || newest != lastNewest || search.Length > 0) Dispatcher.BeginInvoke(() => subScroll.ScrollToEnd(), System.Windows.Threading.DispatcherPriority.Loaded);
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

    static UIElement SubtitleRow(TranslationEntry e)
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
        var row = new Border { Child = cell, Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(14, 0, 14, 0), CornerRadius = new CornerRadius(8), Background = Brushes.Transparent };
        row.MouseEnter += (_, _) => { row.Background = new SolidColorBrush(Color.FromArgb(18, 97, 111, 250)); toolBox.Visibility = Visibility.Visible; };
        row.MouseLeave += (_, _) => { row.Background = Brushes.Transparent; toolBox.Visibility = Visibility.Collapsed; };
        return row;
    }

    // MARK: Dịch màn hình

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
            Background = Ui.Res("CardFill"), BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), Cursor = Cursors.Hand, ToolTip = "Mở lại ảnh đã dịch",
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
        };
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
