using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Hình của game (ảnh tĩnh hoặc video PS5 trực tiếp) + khung phụ đề; bật `editing` rồi kéo chuột để vẽ lại khung phụ đề,
/// kéo khung đang có để di chuyển, hoặc kéo một góc của khung để phóng to / thu nhỏ.
public sealed class GameScreenView : Grid
{
    static readonly Brush dimYellow = Frozen(Color.FromArgb(115, 255, 255, 0)), fillYellow = Frozen(Color.FromArgb(31, 255, 255, 0)),
                          handleDim = Frozen(Color.FromArgb(128, 255, 255, 0)), handleOn = Frozen(Color.FromArgb(242, 255, 255, 0));
    readonly Image img = new() { Stretch = Stretch.Uniform };
    readonly Canvas layer = new() { Background = Brushes.Transparent, ClipToBounds = true };
    readonly ContentControl placeholder = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Rectangle subRect = new() { StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 6, 4 }, Stroke = dimYellow, IsHitTestVisible = false };
    readonly Rectangle[] handles = new Rectangle[4];
    readonly Border hint, caption;
    WriteableBitmap? live;
    (int w, int h) contentSize = (16, 9);
    RectD? subtitle;
    bool editing, isLive;
    // Kéo chuột: vẽ khung mới (khi bật "Vẽ khung phụ đề"), di chuyển khung, hoặc đổi cỡ theo góc.
    enum DragMode { Draw, Move, Resize }
    DragMode? mode;
    Point dragStart, anchor;
    Rect? liveRect;            // khung đang kéo, theo toạ độ của view
    bool hovering;
    const double Handle = 14;  // vùng bắt góc (px)
    public Action<RectD>? onDraw;
    public Action? onEditingEnded;
    Guid? sink;
    Frame? pendingFrame;
    readonly DispatcherTimer frameTimer;

    public GameScreenView()
    {
        Background = Brushes.Black;
        hint = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(153, 0, 0, 0)), CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 4, 8, 4),
            Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Child = Ui.Text("Kéo chuột quanh chỗ phụ đề xuất hiện", 11.5, true, Brushes.Yellow), Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        };
        caption = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(153, 0, 0, 0)), CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 2, 6, 2),
            Child = Ui.Text("Kéo để di chuyển · kéo góc để đổi cỡ", 10.5, color: Brushes.Yellow, wrap: false, weight: FontWeights.Medium),
            Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        };
        Children.Add(img);
        Children.Add(placeholder);
        layer.Children.Add(subRect);
        for (int k = 0; k < 4; k++) layer.Children.Add(handles[k] = new Rectangle { Width = 8, Height = 8, Fill = handleDim, IsHitTestVisible = false, Visibility = Visibility.Collapsed });
        layer.Children.Add(caption);
        Children.Add(layer);
        Children.Add(hint);
        SizeChanged += (_, _) => Layout();
        layer.MouseLeftButtonDown += (_, e) =>
        {
            if (!isLive) return;
            var p = e.GetPosition(layer);
            mode = StartMode(p);
            if (mode == null) return;
            dragStart = p;
            layer.CaptureMouse();
            e.Handled = true;
        };
        layer.MouseMove += (_, e) =>
        {
            var p = e.GetPosition(layer);
            if (mode is not DragMode m) { UpdateHover(p); return; }
            if (liveRect == null && (p - dragStart).Length < 3) return;
            var image = ImageRect();
            switch (m)
            {
                case DragMode.Draw:
                    var d = new Rect(dragStart, p); d.Intersect(image);
                    liveRect = d.IsEmpty ? null : d;
                    break;
                case DragMode.Move:
                    if (FrameRect() is not Rect f) return;
                    double x = Math.Min(Math.Max(f.X + p.X - dragStart.X, image.Left), image.Right - f.Width);
                    double y = Math.Min(Math.Max(f.Y + p.Y - dragStart.Y, image.Top), image.Bottom - f.Height);
                    liveRect = new Rect(x, y, f.Width, f.Height);
                    break;
                case DragMode.Resize:
                    liveRect = new Rect(anchor, new Point(Math.Min(Math.Max(p.X, image.Left), image.Right), Math.Min(Math.Max(p.Y, image.Top), image.Bottom)));
                    break;
            }
            Layout();
        };
        layer.MouseLeftButtonUp += (_, e) =>
        {
            if (mode is not DragMode m) return;
            var r = liveRect;
            mode = null; liveRect = null;
            layer.ReleaseMouseCapture();
            Layout();
            UpdateHover(e.GetPosition(layer));
            if (!isLive || r is not Rect rr) return;
            var (fit, origin) = Fit();
            var n = new RectD((rr.X - origin.X) / fit.Width, (rr.Y - origin.Y) / fit.Height, rr.Width / fit.Width, rr.Height / fit.Height).Intersect(new RectD(0, 0, 1, 1));
            if (n.Width <= 0.05 || n.Height <= 0.03) return;
            onDraw?.Invoke(n);
            if (m != DragMode.Draw) return;
            Editing = false;
            onEditingEnded?.Invoke();
        };
        layer.MouseLeave += (_, _) => { if (mode == null && hovering) { hovering = false; Layout(); } };
        layer.LostMouseCapture += (_, _) => { if (mode != null) { mode = null; liveRect = null; Layout(); } };
        frameTimer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
        frameTimer.Tick += (_, _) => ShowPending();
        Unloaded += (_, _) => StopLive();
    }

    public object? Placeholder { set => placeholder.Content = value; }

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
            img.Source = live;
            contentSize = (f.Width, f.Height);
            Layout();
        }
        live.WritePixels(new Int32Rect(0, 0, f.Width, f.Height), f.Data, f.Stride, 0);
    }

    public void SetSubtitle(RectD? r) { subtitle = r; Layout(); }

    (Size fit, Point origin) Fit()
    {
        double vw = contentSize.w > 0 ? contentSize.w : 16, vh = contentSize.h > 0 ? contentSize.h : 9;
        double scale = Math.Min(ActualWidth / vw, ActualHeight / vh);
        var fit = new Size(vw * scale, vh * scale);
        return (fit, new Point((ActualWidth - fit.Width) / 2, (ActualHeight - fit.Height) / 2));
    }

    static SolidColorBrush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    Rect ImageRect() { var (fit, o) = Fit(); return new Rect(o, fit); }

    /// Khung phụ đề hiện tại, theo toạ độ của view.
    Rect? FrameRect()
    {
        if (subtitle is not RectD r || !isLive || ActualWidth <= 0) return null;
        var (fit, o) = Fit();
        return new Rect(o.X + r.X * fit.Width, o.Y + r.Y * fit.Height, Math.Max(1, r.Width * fit.Width), Math.Max(1, r.Height * fit.Height));
    }

    static Point[] Corners(Rect f) => [f.TopLeft, f.TopRight, f.BottomLeft, f.BottomRight];

    static int CornerAt(Point p, Rect f) => Array.FindIndex(Corners(f), c => Math.Abs(c.X - p.X) <= Handle && Math.Abs(c.Y - p.Y) <= Handle);

    /// Bắt đầu kéo ở đâu: góc khung → đổi cỡ (giữ góc đối diện), trong khung → di chuyển, ngoài khung → vẽ mới (nếu đang bật vẽ).
    DragMode? StartMode(Point p)
    {
        if (FrameRect() is Rect f)
        {
            int k = CornerAt(p, f);
            if (k >= 0) { anchor = Corners(f)[3 - k]; return DragMode.Resize; }
            if (f.Contains(p)) return DragMode.Move;
        }
        return editing ? DragMode.Draw : null;
    }

    /// Rê chuột: làm sáng khung khi ở gần, đổi con trỏ theo việc sẽ làm khi kéo.
    void UpdateHover(Point p)
    {
        var f = FrameRect();
        int k = f is Rect a ? CornerAt(p, a) : -1;
        bool inside = f is Rect b && b.Contains(p);
        bool near = f is Rect c && new Rect(c.X - Handle, c.Y - Handle, c.Width + 2 * Handle, c.Height + 2 * Handle).Contains(p);
        layer.Cursor = k is 0 or 3 ? Cursors.SizeNWSE : k is 1 or 2 ? Cursors.SizeNESW : inside ? Cursors.SizeAll : editing ? Cursors.Cross : null;
        if (near != hovering) { hovering = near; Layout(); }
    }

    void Layout()
    {
        if ((liveRect ?? FrameRect()) is Rect f)
        {
            bool dragging = liveRect != null, active = editing || dragging || hovering;
            Canvas.SetLeft(subRect, f.X); Canvas.SetTop(subRect, f.Y);
            subRect.Width = Math.Max(1, f.Width); subRect.Height = Math.Max(1, f.Height);
            subRect.StrokeThickness = active ? 2 : 1;
            subRect.Stroke = active ? Brushes.Yellow : dimYellow;
            subRect.StrokeDashArray = dragging ? null : new DoubleCollection { 6, 4 };
            subRect.Fill = dragging ? fillYellow : null;
            subRect.Visibility = Visibility.Visible;
            // Bốn ô vuông ở góc: kéo để đổi cỡ.
            var cs = Corners(f);
            for (int k = 0; k < 4; k++)
            {
                Canvas.SetLeft(handles[k], cs[k].X - 4); Canvas.SetTop(handles[k], cs[k].Y - 4);
                handles[k].Fill = active ? handleOn : handleDim;
                handles[k].Visibility = Visibility.Visible;
            }
            if (!dragging && !editing && hovering)
            {
                Canvas.SetLeft(caption, f.X + 4); Canvas.SetTop(caption, Math.Max(Fit().origin.Y, f.Y - 22));
                caption.Visibility = Visibility.Visible;
            }
            else caption.Visibility = Visibility.Collapsed;
        }
        else
        {
            subRect.Visibility = Visibility.Collapsed;
            foreach (var h in handles) h.Visibility = Visibility.Collapsed;
            caption.Visibility = Visibility.Collapsed;
        }
        hint.Visibility = editing && isLive ? Visibility.Visible : Visibility.Collapsed;
    }
}
