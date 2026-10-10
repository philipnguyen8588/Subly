using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Một khung có thể chỉnh trên hình game: khung phụ đề chính hoặc một khu vực dịch thêm. `rect` chuẩn hoá 0...1 theo hình.
public sealed record EditableFrame(Guid id, RectD rect, bool primary, string label);

/// Hình của game (ảnh tĩnh hoặc video PS5 trực tiếp) + các khung dịch. Bật `Editing` rồi kéo chuột trên chỗ trống để vẽ khung mới;
/// bấm vào một khung để chọn, kéo khung để di chuyển, kéo một góc của khung đang chọn để phóng to / thu nhỏ.
/// `SetCaptions`: bản dịch mới nhất của từng khu vực dịch thêm, hiện ngay dưới khung đó.
public sealed class GameScreenView : Grid
{
    static readonly Color yellow = Color.FromRgb(255, 255, 0), cyan = Color.FromRgb(0, 220, 255);
    readonly Image img = new() { Stretch = Stretch.Uniform };
    readonly Canvas layer = new() { Background = Brushes.Transparent, ClipToBounds = true };
    readonly ContentControl placeholder = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Rectangle drawRect = new() { StrokeThickness = 2, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    readonly Rectangle[] handles = new Rectangle[4];
    readonly Border hint;
    readonly TextBlock hintText;
    WriteableBitmap? live;
    (int w, int h) contentSize = (16, 9);
    bool editing, isLive;

    // Các khung đang hiện và hình vẽ tương ứng.
    sealed class Visual
    {
        public readonly Rectangle box = new() { IsHitTestVisible = false };
        public readonly Border label = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(5, 1, 5, 1), IsHitTestVisible = false,
                                               Background = new SolidColorBrush(Color.FromArgb(153, 0, 0, 0)) };
        public readonly TextBlock labelText = Ui.Text("", 10.5, wrap: false, weight: FontWeights.SemiBold);
        public readonly Border caption = new() { CornerRadius = new CornerRadius(5), Padding = new Thickness(7, 4, 7, 4), IsHitTestVisible = false,
                                                 Background = new SolidColorBrush(Color.FromArgb(179, 0, 0, 0)), Visibility = Visibility.Collapsed };
        public readonly TextBlock captionText = Ui.Text("", 13, color: Brushes.White, weight: FontWeights.SemiBold);
        public Visual() { label.Child = labelText; caption.Child = captionText; }
    }
    List<EditableFrame> frames = new();
    readonly Dictionary<Guid, Visual> visuals = new();
    Dictionary<Guid, string> captions = new();
    Guid? selection;

    // Kéo chuột: vẽ khung mới (khi bật vẽ), di chuyển một khung, hoặc đổi cỡ khung đang chọn theo góc.
    enum DragKind { Draw, Move, Resize }
    (DragKind kind, Guid id, Point anchor)? drag;
    Point dragStart;
    Rect? liveRect;            // khung đang kéo, theo toạ độ của view
    bool hovering;
    const double Handle = 14;  // vùng bắt góc (px)

    /// Vẽ xong một khung mới (chuẩn hoá 0...1).
    public Action<RectD>? onDrawNew;
    /// Dời / đổi cỡ một khung đã có.
    public Action<Guid, RectD>? onUpdate;
    public Action? onEditingEnded;
    public Action<Guid?>? onSelectionChanged;
    Guid? sink;
    Frame? pendingFrame;
    readonly DispatcherTimer frameTimer;

    public GameScreenView()
    {
        Background = Brushes.Black;
        hintText = Ui.Text("Kéo chuột quanh chỗ phụ đề xuất hiện", 11.5, true, Brushes.Yellow);
        hint = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(153, 0, 0, 0)), CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 4, 8, 4),
            Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Child = hintText, Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        };
        Children.Add(img);
        Children.Add(placeholder);
        layer.Children.Add(drawRect);
        for (int k = 0; k < 4; k++) layer.Children.Add(handles[k] = new Rectangle { Width = 8, Height = 8, IsHitTestVisible = false, Visibility = Visibility.Collapsed });
        Children.Add(layer);
        Children.Add(hint);
        SizeChanged += (_, _) => Layout();
        layer.MouseLeftButtonDown += (_, e) =>
        {
            if (!isLive) return;
            var p = e.GetPosition(layer);
            drag = StartDrag(p);
            if (drag == null) return;
            dragStart = p;
            layer.CaptureMouse();
            e.Handled = true;
        };
        layer.MouseMove += (_, e) =>
        {
            var p = e.GetPosition(layer);
            if (drag is not { } d) { UpdateHover(p); return; }
            if (liveRect == null && (p - dragStart).Length < 3) return;
            var image = ImageRect();
            switch (d.kind)
            {
                case DragKind.Draw:
                    var r = new Rect(dragStart, p); r.Intersect(image);
                    liveRect = r.IsEmpty ? null : r;
                    break;
                case DragKind.Move:
                    if (FrameRect(d.id) is not Rect f) return;
                    double x = Math.Min(Math.Max(f.X + p.X - dragStart.X, image.Left), image.Right - f.Width);
                    double y = Math.Min(Math.Max(f.Y + p.Y - dragStart.Y, image.Top), image.Bottom - f.Height);
                    liveRect = new Rect(x, y, f.Width, f.Height);
                    break;
                case DragKind.Resize:
                    liveRect = new Rect(d.anchor, new Point(Math.Min(Math.Max(p.X, image.Left), image.Right), Math.Min(Math.Max(p.Y, image.Top), image.Bottom)));
                    break;
            }
            Layout();
        };
        layer.MouseLeftButtonUp += (_, e) =>
        {
            if (drag is not { } d) return;
            var r = liveRect;
            drag = null; liveRect = null;
            layer.ReleaseMouseCapture();
            Layout();
            UpdateHover(e.GetPosition(layer));
            if (!isLive || r is not Rect rr) return;
            var (fit, origin) = Fit();
            var n = new RectD((rr.X - origin.X) / fit.Width, (rr.Y - origin.Y) / fit.Height, rr.Width / fit.Width, rr.Height / fit.Height).Intersect(new RectD(0, 0, 1, 1));
            if (n.Width <= 0.03 || n.Height <= 0.02) return;
            if (d.kind == DragKind.Draw)
            {
                onDrawNew?.Invoke(n);
                Editing = false;
                onEditingEnded?.Invoke();
            }
            else onUpdate?.Invoke(d.id, n);
        };
        layer.MouseLeave += (_, _) => { if (drag == null && hovering) { hovering = false; Layout(); } };
        layer.LostMouseCapture += (_, _) => { if (drag != null) { drag = null; liveRect = null; Layout(); } };
        frameTimer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
        frameTimer.Tick += (_, _) => ShowPending();
        Unloaded += (_, _) => StopLive();
    }

    public object? Placeholder { set => placeholder.Content = value; }

    /// Chữ hướng dẫn hiện khi đang bật vẽ khung mới.
    public string Hint { set => hintText.Text = value; }

    public bool Editing
    {
        get => editing;
        set
        {
            editing = value;
            layer.Cursor = editing ? Cursors.Cross : null;
            Layout();
        }
    }

    public Guid? Selection => selection;

    public void SetStill(BitmapSource? image, (int w, int h) size)
    {
        StopLive();
        img.Source = image;
        if (size.w > 0) contentSize = size;
        isLive = image != null;
        placeholder.Visibility = isLive ? Visibility.Collapsed : Visibility.Visible;
        Layout();
    }

    /// Video trực tiếp từ PS5.
    public void SetLive(bool streaming)
    {
        isLive = streaming;
        placeholder.Visibility = streaming ? Visibility.Collapsed : Visibility.Visible;
        if (sink == null)
        {
            sink = PS5Stream.shared.AddDisplaySink(f => { lock (this) pendingFrame = f; });
            frameTimer.Start();
        }
        // Hết hình (ngắt / đang kết nối lại): bỏ nguồn ảnh. Khi có khung mới, ShowPending gán lại nguồn
        // (kể cả khi bitmap cũ cùng kích cỡ còn dùng được) — trước đây quên gán lại nên màn hình đen dù vẫn dịch được.
        if (!streaming) img.Source = null;
        Layout();
    }

    void StopLive()
    {
        if (sink is Guid id) { PS5Stream.shared.RemoveDisplaySink(id); sink = null; }
        frameTimer.Stop();
        live = null;
    }

    void ShowPending()
    {
        Frame? f;
        lock (this) { f = pendingFrame; pendingFrame = null; }
        if (f == null || !isLive || !IsVisible) return;
        if (live == null || live.PixelWidth != f.Width || live.PixelHeight != f.Height)
        {
            live = new WriteableBitmap(f.Width, f.Height, 96, 96, PixelFormats.Bgr32, null);
            contentSize = (f.Width, f.Height);
            img.Source = live;
            Layout();
        }
        else if (!ReferenceEquals(img.Source, live)) img.Source = live;
        live.WritePixels(new Int32Rect(0, 0, f.Width, f.Height), f.Data, f.Stride, 0);
    }

    /// Danh sách khung cần vẽ. Khung đang chọn không còn trong danh sách thì bỏ chọn; chỉ có một khung thì tự chọn khung đó.
    public void SetFrames(IReadOnlyList<EditableFrame> list)
    {
        frames = list.ToList();
        foreach (var id in visuals.Keys.Where(k => frames.All(f => f.id != k)).ToList())
        {
            var v = visuals[id];
            layer.Children.Remove(v.box); layer.Children.Remove(v.label); layer.Children.Remove(v.caption);
            visuals.Remove(id);
        }
        foreach (var f in frames)
        {
            if (visuals.ContainsKey(f.id)) continue;
            var v = new Visual();
            // Thứ tự vẽ: khung dưới cùng, nhãn, rồi bản dịch; ô góc và khung đang vẽ (đã thêm từ đầu) nằm trên hết.
            int at = Math.Max(0, layer.Children.IndexOf(drawRect));
            layer.Children.Insert(at, v.caption); layer.Children.Insert(at, v.label); layer.Children.Insert(at, v.box);
            visuals[f.id] = v;
        }
        var sel = selection;
        if (sel is Guid s && frames.All(f => f.id != s)) sel = null;
        if (sel == null && frames.Count == 1) sel = frames[0].id;
        if (sel != selection) { selection = sel; onSelectionChanged?.Invoke(selection); }
        Layout();
    }

    /// Bản dịch hiện tại của từng khu vực dịch thêm (theo id khung).
    public void SetCaptions(IReadOnlyDictionary<Guid, string> caps)
    {
        captions = caps.ToDictionary(k => k.Key, k => k.Value);
        Layout();
    }

    (Size fit, Point origin) Fit()
    {
        double vw = contentSize.w > 0 ? contentSize.w : 16, vh = contentSize.h > 0 ? contentSize.h : 9;
        double scale = Math.Min(ActualWidth / vw, ActualHeight / vh);
        var fit = new Size(vw * scale, vh * scale);
        return (fit, new Point((ActualWidth - fit.Width) / 2, (ActualHeight - fit.Height) / 2));
    }

    static SolidColorBrush Frozen(Color c, byte alpha = 255) { var b = new SolidColorBrush(Color.FromArgb(alpha, c.R, c.G, c.B)); b.Freeze(); return b; }

    Rect ImageRect() { var (fit, o) = Fit(); return new Rect(o, fit); }

    Rect Px(RectD r)
    {
        var (fit, o) = Fit();
        return new Rect(o.X + r.X * fit.Width, o.Y + r.Y * fit.Height, Math.Max(1, r.Width * fit.Width), Math.Max(1, r.Height * fit.Height));
    }

    /// Khung theo toạ độ của view (null nếu không có / chưa có hình).
    Rect? FrameRect(Guid id)
    {
        if (!isLive || ActualWidth <= 0) return null;
        var f = frames.FirstOrDefault(x => x.id == id);
        return f == null ? null : Px(f.rect);
    }

    static Point[] Corners(Rect f) => [f.TopLeft, f.TopRight, f.BottomLeft, f.BottomRight];

    static int CornerAt(Point p, Rect f) => Array.FindIndex(Corners(f), c => Math.Abs(c.X - p.X) <= Handle && Math.Abs(c.Y - p.Y) <= Handle);

    /// Bắt đầu kéo ở đâu: góc khung đang chọn → đổi cỡ (giữ góc đối diện); trong một khung → chọn & di chuyển;
    /// chỗ trống → vẽ mới (nếu đang bật vẽ).
    (DragKind, Guid, Point)? StartDrag(Point p)
    {
        if (selection is Guid sel && FrameRect(sel) is Rect sf)
        {
            int k = CornerAt(p, sf);
            if (k >= 0) return (DragKind.Resize, sel, Corners(sf)[3 - k]);
        }
        // Khung vẽ sau nằm trên → xét từ cuối.
        foreach (var f in frames.AsEnumerable().Reverse())
        {
            if (FrameRect(f.id) is Rect r && r.Contains(p))
            {
                if (selection != f.id) { selection = f.id; onSelectionChanged?.Invoke(selection); }
                return (DragKind.Move, f.id, default);
            }
        }
        return editing ? (DragKind.Draw, Guid.Empty, default) : null;
    }

    /// Rê chuột: làm sáng khung khi ở gần, đổi con trỏ theo việc sẽ làm khi kéo.
    void UpdateHover(Point p)
    {
        int k = selection is Guid sel && FrameRect(sel) is Rect sf ? CornerAt(p, sf) : -1;
        bool inside = frames.Any(f => FrameRect(f.id) is Rect r && r.Contains(p));
        bool near = frames.Any(f => FrameRect(f.id) is Rect r && new Rect(r.X - Handle, r.Y - Handle, r.Width + 2 * Handle, r.Height + 2 * Handle).Contains(p));
        layer.Cursor = k is 0 or 3 ? Cursors.SizeNWSE : k is 1 or 2 ? Cursors.SizeNESW : inside ? Cursors.SizeAll : editing ? Cursors.Cross : null;
        if (near != hovering) { hovering = near; Layout(); }
    }

    void Layout()
    {
        var draggingID = drag is { } d && d.kind != DragKind.Draw ? d.id : (Guid?)null;
        Rect? selectedRect = null;
        Color selectedColor = yellow;
        foreach (var ef in frames)
        {
            var v = visuals[ef.id];
            var r = draggingID == ef.id ? liveRect : FrameRect(ef.id);
            if (r is not Rect f)
            {
                v.box.Visibility = v.label.Visibility = v.caption.Visibility = Visibility.Collapsed;
                continue;
            }
            bool selected = selection == ef.id, dragging = draggingID == ef.id, active = selected || editing || hovering;
            var color = ef.primary ? yellow : cyan;
            Canvas.SetLeft(v.box, f.X); Canvas.SetTop(v.box, f.Y);
            v.box.Width = Math.Max(1, f.Width); v.box.Height = Math.Max(1, f.Height);
            v.box.StrokeThickness = active ? 2 : 1;
            v.box.Stroke = Frozen(color, active ? (byte)255 : (byte)128);
            v.box.StrokeDashArray = selected ? null : new DoubleCollection { 6, 4 };
            v.box.Fill = selected || dragging ? Frozen(color, 26) : null;
            v.box.Visibility = Visibility.Visible;
            // Nhãn khung, ngay phía trên.
            v.labelText.Text = ef.label; v.labelText.Foreground = Frozen(color);
            Canvas.SetLeft(v.label, f.X + 2); Canvas.SetTop(v.label, Math.Max(0, f.Y - 20));
            v.label.Visibility = Visibility.Visible;
            // Bản dịch của khu vực dịch thêm, ngay dưới khung.
            if (!ef.primary && captions.TryGetValue(ef.id, out var cap) && cap.Length > 0)
            {
                v.captionText.Text = cap;
                v.caption.MaxWidth = Math.Max(90, f.Width);
                Canvas.SetLeft(v.caption, f.X); Canvas.SetTop(v.caption, f.Bottom + 3);
                v.caption.Visibility = Visibility.Visible;
            }
            else v.caption.Visibility = Visibility.Collapsed;
            if (selected) { selectedRect = f; selectedColor = color; }
        }
        // Bốn ô vuông ở góc khung đang chọn: kéo để đổi cỡ.
        if (selectedRect is Rect sr)
        {
            var cs = Corners(sr);
            for (int k = 0; k < 4; k++)
            {
                Canvas.SetLeft(handles[k], cs[k].X - 4); Canvas.SetTop(handles[k], cs[k].Y - 4);
                handles[k].Fill = Frozen(selectedColor, 242);
                handles[k].Visibility = Visibility.Visible;
            }
        }
        else foreach (var h in handles) h.Visibility = Visibility.Collapsed;
        // Khung mới đang vẽ.
        if (drag is { kind: DragKind.Draw } && liveRect is Rect nr)
        {
            var c = frames.Any(f => f.primary) ? cyan : yellow;
            Canvas.SetLeft(drawRect, nr.X); Canvas.SetTop(drawRect, nr.Y);
            drawRect.Width = Math.Max(1, nr.Width); drawRect.Height = Math.Max(1, nr.Height);
            drawRect.Stroke = Frozen(c); drawRect.Fill = Frozen(c, 31);
            drawRect.Visibility = Visibility.Visible;
        }
        else drawRect.Visibility = Visibility.Collapsed;
        hint.Visibility = editing && isLive ? Visibility.Visible : Visibility.Collapsed;
    }
}
