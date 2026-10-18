using System;
using System.Linq;
using System.Net;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace ScreenTranslator;

/// Cửa sổ "Cài app lên TV Samsung" (nút trên header cửa sổ chính / màn Bắt đầu): hướng dẫn bật Developer Mode,
/// nhập IP TV, bấm Cài; TvInstaller lo kết nối, chứng chỉ (đăng nhập Samsung nếu TV mới), ký và cài.
public sealed class TvInstallWindow : Window
{
    static TvInstallWindow? instance;
    readonly TextBox ipBox = new() { Width = 180, FontSize = 14, Padding = new Thickness(6, 4, 6, 4) };
    readonly TextBox logBox = new()
    {
        IsReadOnly = true, FontFamily = new FontFamily("Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Height = 170, Padding = new Thickness(6),
    };
    readonly ProgressBar progress = new() { IsIndeterminate = true, Height = 4, Visibility = Visibility.Collapsed };
    readonly TextBlock result = Ui.Text("", 13);
    readonly Button installBtn, cancelBtn;
    CancellationTokenSource? cts;

    public static void Present()
    {
        if (instance == null)
        {
            instance = new TvInstallWindow();
            if (Application.Current.MainWindow is Window m && m.IsVisible && m != instance) instance.Owner = m;
            instance.Closed += (_, _) => instance = null;
            instance.Show();
        }
        if (instance.WindowState == WindowState.Minimized) instance.WindowState = WindowState.Normal;
        instance.Activate();
    }

    TvInstallWindow()
    {
        Title = "Cài app lên TV Samsung";
        Width = 600; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Ui.Res("WindowBg");
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/Resources/AppIcon.ico"));

        var pcIps = WebServer.LanAddresses();
        var pcIp = pcIps.FirstOrDefault() ?? "(không thấy IP mạng nội bộ)";
        var pcIpBox = new TextBox { Text = pcIp, IsReadOnly = true, FontFamily = new FontFamily("Consolas"), FontSize = 14, Width = 180, Padding = new Thickness(6, 4, 6, 4) };
        var copy = Ui.Btn("Chép", () => Ui.CopyText(pcIp));

        ipBox.Text = AppSettings.shared.tvInstallIp;
        ipBox.KeyDown += (_, e) => { if (e.Key == Key.Enter && installBtn!.IsEnabled) Start(); };
        installBtn = Ui.Btn(Ui.IconLabel("", "Cài lên TV"), Start, primary: true, minWidth: 140);
        installBtn.IsDefault = true;
        cancelBtn = Ui.Btn("Huỷ", () => cts?.Cancel());
        cancelBtn.Visibility = Visibility.Collapsed;

        var steps = Ui.V(6,
            Ui.Text("1. Trên TV: mở Apps, bấm 1 2 3 4 5 trên remote, bật Developer mode.", 13),
            Ui.Text("2. Ô Host PC IP trên TV: nhập IP máy tính này", 13),
            Ui.H(8, pcIpBox, copy).Also(h => h.Margin = new Thickness(18, 0, 0, 0)),
            Ui.Text("3. Tắt TV rồi mở lại. Xem IP của TV: Cài đặt → Chung → Mạng → Trạng thái mạng.", 13),
            Ui.Caption(pcIps.Count > 1 ? "Máy có nhiều IP: " + string.Join(", ", pcIps) + " — chọn IP cùng mạng với TV." : "TV và máy tính phải cùng mạng."));
        var missing = TvInstaller.MissingFiles();

        Content = new Border
        {
            Padding = new Thickness(24, 20, 24, 20),
            Child = Ui.V(14,
                Ui.H(10, Ui.Icon("", 26, Ui.AccentStart), Ui.V(2, Ui.Text("Cài app Subtitle TV lên TV Samsung", 16, true),
                    Ui.Caption("TV mới lần đầu: trình duyệt mở trang đăng nhập Samsung Account để xin chứng chỉ cho TV đó."))),
                Ui.Card(steps),
                Ui.Row(Ui.H(8, Ui.Text("IP của TV", 13).Also(t => t.VerticalAlignment = VerticalAlignment.Center), ipBox), cancelBtn, installBtn),
                missing != null ? Ui.Text(missing, 13, color: Ui.Danger) : null,
                progress, logBox, result),
        };
        installBtn.IsEnabled = missing == null;
        Loaded += (_, _) => ipBox.Focus();
        Closing += (_, _) => cts?.Cancel();
    }

    void Log(string line) => Dispatcher.BeginInvoke(() => { logBox.AppendText(line + "\n"); logBox.ScrollToEnd(); });

    async void Start()
    {
        var ip = ipBox.Text.Trim();
        if (!IPAddress.TryParse(ip, out var addr) || addr.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
        {
            result.Text = "Nhập IP của TV dạng 192.168.1.20."; result.Foreground = Ui.Danger; return;
        }
        AppSettings.shared.tvInstallIp = ip;
        logBox.Clear(); result.Text = "";
        installBtn.IsEnabled = false; ipBox.IsEnabled = false;
        cancelBtn.Visibility = progress.Visibility = Visibility.Visible;
        cts = new CancellationTokenSource();
        var ct = cts.Token;
        try
        {
            // Chạy nền; hỏi gỡ app cũ thì quay về UI thread.
            await System.Threading.Tasks.Task.Run(() => TvInstaller.Install(ip, Log,
                () => Dispatcher.Invoke(() => MessageBox.Show(this,
                    "TV đã có Subtitle TV cài bằng chứng chỉ khác nên không cài đè được.\n\n" +
                    "Gỡ app cũ rồi cài lại? Cài đặt đã lưu trong app trên TV (máy tính đã chọn, cỡ chữ…) sẽ mất.",
                    "Cài app lên TV", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes), ct), ct);
            result.Text = "✅ Đã cài và mở app trên TV. Trên TV: Back → Máy tính → \"Dò máy trong mạng\" để kết nối máy này.";
            result.ClearValue(TextBlock.ForegroundProperty);
        }
        catch (OperationCanceledException) { result.Text = "Đã huỷ."; result.Foreground = Ui.Secondary; }
        catch (Exception e)
        {
            Log("Lỗi: " + e.Message);
            ScreenTranslator.Log.Warn("TV: cài app lỗi: " + e.Message);
            result.Text = "Không cài được: " + e.Message.Split('\n')[0]; result.Foreground = Ui.Danger;
        }
        finally
        {
            cts?.Dispose(); cts = null;
            installBtn.IsEnabled = true; ipBox.IsEnabled = true;
            cancelBtn.Visibility = progress.Visibility = Visibility.Collapsed;
        }
    }
}
