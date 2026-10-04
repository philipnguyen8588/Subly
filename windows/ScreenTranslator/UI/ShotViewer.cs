using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ScreenTranslator;

/// Ảnh "dịch màn hình" đang mở trong modal của cửa sổ chính (null = đóng).
public static class ShotViewer
{
    public static long? currentID { get; private set; }
    public static event Action? Changed;

    public static void Show(long id)
    {
        currentID = id;
        App.ShowMain();
        Changed?.Invoke();
    }

    public static void Close() { currentID = null; Changed?.Invoke(); }
}

/// Đọc ảnh chụp đã lưu (file JPEG) và giữ tạm trong bộ nhớ.
public static class ShotImages
{
    static readonly Dictionary<string, BitmapSource> cache = new();
    static readonly LinkedList<string> order = new();

    /// `maxPixel` = 0: ảnh đầy đủ; có giá trị: ảnh thu nhỏ cho danh sách.
    public static BitmapSource? Load(long id, int maxPixel = 0)
    {
        var key = $"{id}-{maxPixel}";
        lock (cache) if (cache.TryGetValue(key, out var hit)) return hit;
        var path = HistoryStore.ShotPath(id);
        if (!File.Exists(path)) return null;
        try
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.UriSource = new Uri(path);
            if (maxPixel > 0) bi.DecodePixelWidth = maxPixel;
            bi.EndInit();
            bi.Freeze();
            lock (cache)
            {
                cache[key] = bi; order.AddLast(key);
                while (order.Count > 40) { cache.Remove(order.First!.Value); order.RemoveFirst(); }
            }
            return bi;
        }
        catch { return null; }
    }

    public static byte[]? ThumbnailJpeg(long id, int maxPixel)
    {
        var img = Load(id, maxPixel);
        if (img == null) return null;
        var enc = new JpegBitmapEncoder { QualityLevel = 60 };
        enc.Frames.Add(BitmapFrame.Create(img));
        using var ms = new MemoryStream();
        enc.Save(ms);
        return ms.ToArray();
    }
}

/// Ảnh chụp đứng yên + bản dịch đè lên đúng vị trí từng khối chữ.
public sealed class TranslatedShotView : Grid
{
    readonly Image img = new() { Stretch = Stretch.Fill, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    readonly Canvas layer = new() { IsHitTestVisible = true };
    readonly BitmapSource image;
    readonly List<ShotItem> items;
    bool showSource;

    public TranslatedShotView(BitmapSource image, List<ShotItem> items)
    {
        this.image = image; this.items = items;
        img.Source = image;
        Children.Add(img);
        Children.Add(layer);
        SizeChanged += (_, _) => Relayout();
    }

    public bool ShowSource { get => showSource; set { showSource = value; Relayout(); } }

    void Relayout()
    {
        layer.Children.Clear();
        if (ActualWidth <= 0) return;
        double iw = image.PixelWidth, ih = image.PixelHeight;
        double scale = Math.Min(ActualWidth / iw, ActualHeight / ih);
        double fw = iw * scale, fh = ih * scale;
        double ox = (ActualWidth - fw) / 2, oy = (ActualHeight - fh) / 2;
        img.Width = fw; img.Height = fh; img.Margin = new Thickness(ox, oy, 0, 0);
        if (showSource) return;
        foreach (var it in items)
        {
            double w = it.w * fw, h = it.h * fh;
            // Tiếng Việt thường dài hơn tiếng Anh: cho hộp rộng thêm, chữ tự co cho vừa.
            double boxW = Math.Min(Math.Max(w * 1.15, w + 12), fw - it.x * fw);
            double size = Math.Max(9, h / Math.Max(1, it.lines) * 0.74);
            var tb = new TextBlock
            {
                Text = it.target, FontSize = size, FontWeight = FontWeights.Medium, Foreground = Brushes.White,
                TextWrapping = TextWrapping.Wrap,
            };
            var vb = new Viewbox { Child = tb, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left };
            tb.MaxWidth = Math.Max(10, boxW - 6);
            var box = new Border
            {
                Width = Math.Max(10, boxW), Height = h + 2, Background = new SolidColorBrush(Color.FromArgb(224, 0, 0, 0)),
                CornerRadius = new CornerRadius(3), Padding = new Thickness(3, 0, 3, 0), Child = vb, ToolTip = it.source,
            };
            Canvas.SetLeft(box, ox + it.x * fw - 3);
            Canvas.SetTop(box, oy + it.y * fh - 1);
            layer.Children.Add(box);
        }
    }
}

/// Modal phủ cửa sổ chính: ảnh đã dịch, lùi/tới giữa các ảnh đã chụp (←/→), Esc để đóng.
public sealed class ShotModal : Border
{
    bool showSource;

    public ShotModal()
    {
        Background = Brushes.Black;
        Focusable = true;
        ShotViewer.Changed += Rebuild;
        HistoryStore.shared.Changed += () => { if (ShotViewer.currentID != null) Rebuild(); };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) ShotViewer.Close();
            else if (e.Key == Key.Left) Step(-1);
            else if (e.Key == Key.Right) Step(1);
            else return;
            e.Handled = true;
        };
        Rebuild();
    }

    /// Các mục còn ảnh, cũ → mới.
    static List<ScreenAnalysis> Shots() => HistoryStore.shared.analyses.Where(a => a.hasImage).Reverse().ToList();

    void Step(int d)
    {
        var shots = Shots();
        int i = shots.FindIndex(a => a.id == ShotViewer.currentID) + d;
        if (i >= 0 && i < shots.Count) ShotViewer.Show(shots[i].id);
    }

    void Rebuild()
    {
        if (ShotViewer.currentID is not long id) { Visibility = Visibility.Collapsed; Child = null; return; }
        Visibility = Visibility.Visible;
        var shots = Shots();
        int index = shots.FindIndex(a => a.id == id);
        var image = ShotImages.Load(id);
        var dim = new SolidColorBrush(Color.FromArgb(160, 255, 255, 255));
        if (index < 0 || image == null)
        {
            var close = Ui.Btn("Đóng", ShotViewer.Close);
            var v = Ui.V(10, Ui.Text("Ảnh này không còn được lưu.", color: dim), close);
            v.HorizontalAlignment = HorizontalAlignment.Center; v.VerticalAlignment = VerticalAlignment.Center;
            Child = v;
            Dispatcher.BeginInvoke(() => Focus());
            return;
        }
        var shot = shots[index];
        var view = new TranslatedShotView(image, shot.items) { ShowSource = showSource };
        var srcToggle = new System.Windows.Controls.Primitives.ToggleButton { Content = Ui.IconLabel("", "Xem bản gốc"), IsChecked = showSource };
        srcToggle.Checked += (_, _) => { showSource = true; view.ShowSource = true; };
        srcToggle.Unchecked += (_, _) => { showSource = false; view.ShowSource = false; };
        var prev = Ui.IconBtn("", () => Step(-1), "Ảnh chụp trước (←)"); prev.IsEnabled = index > 0;
        var next = Ui.IconBtn("", () => Step(1), "Ảnh chụp sau (→)"); next.IsEnabled = index < shots.Count - 1;
        var close2 = Ui.Btn(Ui.IconLabel("", "Đóng"), ShotViewer.Close, tip: "Esc");
        var bar = Ui.Row(Ui.H(10, Ui.Text($"{index + 1}/{shots.Count}", color: dim), Ui.Text($"{shot.timestamp:HH:mm:ss} · {shot.items.Count} khối chữ", color: dim)),
                         srcToggle, prev, next, close2);
        bar.Margin = new Thickness(14, 8, 14, 8);
        var dock = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        dock.Children.Add(bar);
        if (shot.summary.Length > 0)
        {
            var sum = new TextBox
            {
                Text = shot.summary, IsReadOnly = true, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
                Foreground = new SolidColorBrush(Color.FromArgb(217, 255, 255, 255)), TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center, Margin = new Thickness(24, 10, 24, 10), MaxHeight = 80, FontSize = 13,
            };
            DockPanel.SetDock(sum, Dock.Bottom);
            dock.Children.Add(sum);
        }
        dock.Children.Add(view);
        Child = dock;
        Dispatcher.BeginInvoke(() => Focus());
    }
}
