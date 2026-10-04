using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Hình của game (ảnh tĩnh hoặc video PS5 trực tiếp) + khung phụ đề; bật `editing` rồi kéo chuột để vẽ lại khung phụ đề.
public sealed class GameScreenView : Grid
{
    readonly Image img = new() { Stretch = Stretch.Uniform };
    readonly Canvas layer = new() { Background = Brushes.Transparent, ClipToBounds = true };
    readonly ContentControl placeholder = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Rectangle subRect = new() { StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 6, 4 }, Stroke = new SolidColorBrush(Color.FromArgb(115, 255, 255, 0)), IsHitTestVisible = false };
    readonly Rectangle dragRect = new() { Stroke = Brushes.Yellow, StrokeThickness = 2, Fill = new SolidColorBrush(Color.FromArgb(38, 255, 255, 0)), IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    readonly Border hint;
    WriteableBitmap? live;
    (int w, int h) contentSize = (16, 9);
    RectD? subtitle;
    bool editing, isLive;
    Point? dragStart;
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
        Children.Add(img);
        Children.Add(placeholder);
        layer.Children.Add(subRect);
        layer.Children.Add(dragRect);
        Children.Add(layer);
        Children.Add(hint);
        SizeChanged += (_, _) => Layout();
        layer.MouseLeftButtonDown += (_, e) =>
        {
            if (!editing || !isLive) return;
            dragStart = e.GetPosition(layer);
            layer.CaptureMouse();
        };
        layer.MouseMove += (_, e) =>
        {
            if (dragStart is not Point a) return;
            var r = new Rect(a, e.GetPosition(layer));
            Canvas.SetLeft(dragRect, r.X); Canvas.SetTop(dragRect, r.Y);
            dragRect.Width = r.Width; dragRect.Height = r.Height;
            dragRect.Visibility = Visibility.Visible;
            subRect.Visibility = Visibility.Collapsed;
        };
        layer.MouseLeftButtonUp += (_, e) =>
        {
            if (dragStart is not Point a) return;
            layer.ReleaseMouseCapture();
            var b = e.GetPosition(layer);
            dragStart = null;
            dragRect.Visibility = Visibility.Collapsed;
            var (fit, origin) = Fit();
            var n = new RectD((Math.Min(a.X, b.X) - origin.X) / fit.Width, (Math.Min(a.Y, b.Y) - origin.Y) / fit.Height,
                              Math.Abs(a.X - b.X) / fit.Width, Math.Abs(a.Y - b.Y) / fit.Height).Intersect(new RectD(0, 0, 1, 1));
            Layout();
            if (n.Width <= 0.05 || n.Height <= 0.03) return;
            onDraw?.Invoke(n);
            Editing = false;
            onEditingEnded?.Invoke();
        };
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
            hint.Visibility = editing && isLive ? Visibility.Visible : Visibility.Collapsed;
            layer.Cursor = editing ? Cursors.Cross : null;
            subRect.StrokeThickness = editing ? 2 : 1;
            subRect.Stroke = editing ? Brushes.Yellow : new SolidColorBrush(Color.FromArgb(115, 255, 255, 0));
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

    void Layout()
    {
        if (subtitle is RectD r && isLive && dragStart == null && ActualWidth > 0)
        {
            var (fit, o) = Fit();
            Canvas.SetLeft(subRect, o.X + r.X * fit.Width); Canvas.SetTop(subRect, o.Y + r.Y * fit.Height);
            subRect.Width = Math.Max(1, r.Width * fit.Width); subRect.Height = Math.Max(1, r.Height * fit.Height);
            subRect.Visibility = Visibility.Visible;
        }
        else subRect.Visibility = Visibility.Collapsed;
        hint.Visibility = editing && isLive ? Visibility.Visible : Visibility.Collapsed;
    }
}
