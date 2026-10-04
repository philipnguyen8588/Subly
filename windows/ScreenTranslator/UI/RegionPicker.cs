using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;

namespace ScreenTranslator;

/// Phủ mọi màn hình bằng cửa sổ mờ, người dùng kéo để vẽ vùng. Trả về rect theo pixel vật lý toàn cục.
public sealed class RegionPicker
{
    public static readonly RegionPicker shared = new();
    readonly List<Window> windows = new();
    Action<RectD?> completion = _ => { };
    bool finished;

    public void Begin(Action<RectD?> completion)
    {
        if (windows.Count > 0) return;
        this.completion = completion;
        finished = false;
        foreach (var (_, bounds, _, _) in Win32.Monitors())
        {
            var w = MakeWindow(bounds);
            windows.Add(w);
            w.Show();
        }
        windows[0].Activate();
    }

    Window MakeWindow(RectD monPx)
    {
        var canvas = new Canvas { Background = new SolidColorBrush(Color.FromArgb(89, 0, 0, 0)), Cursor = Cursors.Cross };
        var rect = new Rectangle { Stroke = Brushes.Yellow, StrokeThickness = 2, Fill = new SolidColorBrush(Color.FromArgb(38, 255, 255, 0)), Visibility = Visibility.Collapsed };
        var size = new TextBlock { Foreground = Brushes.Yellow, FontWeight = FontWeights.SemiBold, Background = new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)), Padding = new Thickness(6, 2, 6, 2), Visibility = Visibility.Collapsed };
        var hint = new TextBlock
        {
            Text = "Kéo chuột để chọn vùng · Esc để huỷ", Foreground = Brushes.White, FontSize = 16, FontWeight = FontWeights.SemiBold,
            Background = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)), Padding = new Thickness(14, 8, 14, 8),
        };
        canvas.Children.Add(rect); canvas.Children.Add(size); canvas.Children.Add(hint);
        Canvas.SetLeft(hint, 30); Canvas.SetTop(hint, 30);
        var w = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true,
            ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, Content = canvas, Title = "Chọn vùng",
            Left = monPx.X, Top = monPx.Y, Width = 400, Height = 300,
        };
        w.SourceInitialized += (_, _) => Win32.PlacePx(new WindowInteropHelper(w).Handle, monPx);
        Point? startDip = null; Win32.POINT startPx = default;
        canvas.MouseLeftButtonDown += (_, e) =>
        {
            startDip = e.GetPosition(canvas);
            Win32.GetCursorPos(out startPx);
            canvas.CaptureMouse();
            hint.Visibility = Visibility.Collapsed;
        };
        canvas.MouseMove += (_, e) =>
        {
            if (startDip is not Point a) return;
            var b = e.GetPosition(canvas);
            Win32.GetCursorPos(out var nowPx);
            var r = new Rect(a, b);
            Canvas.SetLeft(rect, r.X); Canvas.SetTop(rect, r.Y);
            rect.Width = r.Width; rect.Height = r.Height;
            rect.Visibility = Visibility.Visible;
            size.Text = $"{Math.Abs(nowPx.X - startPx.X)} × {Math.Abs(nowPx.Y - startPx.Y)}";
            size.Visibility = Visibility.Visible;
            Canvas.SetLeft(size, r.X); Canvas.SetTop(size, Math.Max(0, r.Y - 26));
        };
        canvas.MouseLeftButtonUp += (_, _) =>
        {
            if (startDip == null) return;
            canvas.ReleaseMouseCapture();
            Win32.GetCursorPos(out var endPx);
            startDip = null;
            double x = Math.Min(startPx.X, endPx.X), y = Math.Min(startPx.Y, endPx.Y);
            double wd = Math.Abs(endPx.X - startPx.X), ht = Math.Abs(endPx.Y - startPx.Y);
            if (wd < 20 || ht < 10) { rect.Visibility = Visibility.Collapsed; size.Visibility = Visibility.Collapsed; return; }
            Finish(new RectD(x, y, wd, ht));
        };
        w.KeyDown += (_, e) => { if (e.Key == Key.Escape) Finish(null); };
        return w;
    }

    void Finish(RectD? result)
    {
        if (finished) return;
        finished = true;
        foreach (var w in windows) w.Close();
        windows.Clear();
        // Đợi các cửa sổ phủ biến mất hẳn trước khi tìm cửa sổ bên dưới / chụp màn hình.
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        t.Tick += (_, _) => { t.Stop(); completion(result); };
        t.Start();
    }
}
