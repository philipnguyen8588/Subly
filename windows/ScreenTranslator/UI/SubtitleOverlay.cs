using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace ScreenTranslator;

public record OverlayStyle(double fontSize = 22, double opacity = 0.7, bool showSource = true, double maxWidth = 900,
                           OverlayPosition position = OverlayPosition.belowRegion, double hideAfter = 6);

/// Cửa sổ không nhận chuột, nổi trên mọi thứ (topmost), không lọt vào ảnh chụp màn hình (để OCR không đọc lại bản dịch).
public sealed class SubtitleOverlay
{
    readonly Window win;
    readonly Border box;
    readonly TextBlock translatedText;
    readonly TextBlock sourceText;
    readonly DispatcherTimer hideTimer = new();
    IntPtr hwnd;

    public SubtitleOverlay()
    {
        translatedText = new TextBlock
        {
            Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
            FontFamily = new FontFamily("Segoe UI"),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Colors.Black, BlurRadius = 4, ShadowDepth = 0, Opacity = 0.8 },
        };
        sourceText = new TextBlock
        {
            Foreground = new SolidColorBrush(Color.FromArgb(180, 255, 255, 255)), TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 4, 0, 0), FontFamily = new FontFamily("Segoe UI"),
        };
        var stack = new StackPanel();
        stack.Children.Add(translatedText);
        stack.Children.Add(sourceText);
        box = new Border
        {
            CornerRadius = new CornerRadius(12), Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(4),
            Child = stack, HorizontalAlignment = HorizontalAlignment.Center,
        };
        win = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent,
            Topmost = true, ShowInTaskbar = false, ShowActivated = false, Focusable = false, IsHitTestVisible = false,
            ResizeMode = ResizeMode.NoResize, SizeToContent = SizeToContent.Manual, Content = box,
            Width = 600, Height = 80, Left = -10000, Top = -10000, Title = "ScreenTranslator Overlay",
        };
        win.SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(win).Handle;
            Win32.MakeClickThrough(hwnd);
            Win32.ExcludeFromCapture(hwnd);
        };
        hideTimer.Tick += (_, _) => Hide();
    }

    public void Show(string translated, string source, Region? near, OverlayStyle style)
    {
        translatedText.Inlines.Clear();
        translatedText.Inlines.AddRange(SpeakerColors.Styled(translated, onDark: true, weight: FontWeights.SemiBold));
        translatedText.FontSize = style.fontSize;
        sourceText.Text = style.showSource ? source : "";
        sourceText.Visibility = style.showSource && source.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        sourceText.FontSize = Math.Max(11, style.fontSize * 0.55);
        box.Background = new SolidColorBrush(Color.FromArgb((byte)(Math.Clamp(style.opacity, 0, 1) * 255), 0, 0, 0));

        // Khung vùng (pixel vật lý) và màn hình chứa nó
        RectD regionPx;
        if (near != null && !near.embedded) regionPx = WindowFinder.CurrentRect(near);
        else
        {
            Win32.GetCursorPos(out var p);
            var (mon, _) = Win32.MonitorAt(p.X, p.Y);
            regionPx = mon;
        }
        var (screen, work) = Win32.MonitorAt(regionPx.MidX, regionPx.MidY);
        double scale = Win32.ScaleAt(regionPx.MidX, regionPx.MidY);

        // Đo kích thước nội dung (DIP) rồi đổi sang pixel của màn hình đích
        double maxW = Math.Min(style.maxWidth, (work.Width - 40) / scale);
        box.MaxWidth = maxW;
        box.Measure(new Size(maxW + 8, double.PositiveInfinity));
        var size = box.DesiredSize;
        double wDip = Math.Min(Math.Max(size.Width, 300), maxW + 8), hDip = size.Height;
        double w = wDip * scale, h = hDip * scale;

        double x, y;
        var pos = near == null || near.embedded ? OverlayPosition.screenBottom : style.position;
        switch (pos)
        {
            case OverlayPosition.belowRegion:
                x = regionPx.MidX - w / 2;
                y = regionPx.MaxY + 8 * scale;
                if (y + h > screen.MaxY - 10) y = regionPx.MinY - h - 8 * scale;
                break;
            case OverlayPosition.aboveRegion:
                x = regionPx.MidX - w / 2;
                y = regionPx.MinY - h - 8 * scale;
                if (y < screen.MinY + 10) y = regionPx.MaxY + 8 * scale;
                break;
            default:
                x = screen.MidX - w / 2;
                y = work.MaxY - h - 40 * scale;
                break;
        }
        x = Math.Max(screen.MinX + 20, Math.Min(x, screen.MaxX - w - 20));
        y = Math.Max(screen.MinY, Math.Min(y, screen.MaxY - h));

        win.Width = wDip; win.Height = hDip;
        if (!win.IsVisible) win.Show();
        if (hwnd != IntPtr.Zero) Win32.PlacePx(hwnd, new RectD(x, y, w, h));

        hideTimer.Stop();
        if (style.hideAfter > 0)
        {
            hideTimer.Interval = TimeSpan.FromSeconds(style.hideAfter);
            hideTimer.Start();
        }
    }

    /// Thông báo ngắn ở đáy màn hình (ví dụ "Đang phân tích…").
    public void Hud(string text, double seconds = 2) =>
        Show(text, "", null, new OverlayStyle(fontSize: 16, showSource: false, hideAfter: seconds, position: OverlayPosition.screenBottom));

    public void Hide()
    {
        hideTimer.Stop();
        if (win.IsVisible) win.Hide();
    }
}
