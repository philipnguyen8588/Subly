using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace ScreenTranslator;

/// Cửa sổ hiện khi app chưa sẵn sàng chạy. Cố ý chung chung, không nêu lý do (chờ duyệt / thu hồi / mất mạng…).
/// Tương đương StartupErrorView.swift của bản macOS.
public sealed class StartupErrorWindow : Window
{
    static StartupErrorWindow? instance;

    readonly TextBlock status = Ui.Caption("");
    readonly Button retryBtn;

    StartupErrorWindow()
    {
        Title = "ScreenTranslator";
        Width = 460; Height = 320; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen; ShowInTaskbar = true;
        Background = Ui.Res("WindowBg");

        retryBtn = Ui.Btn("Thử lại", Retry, primary: true);
        var closeBtn = Ui.Btn("Đóng", Close);

        Content = new Border
        {
            Padding = new Thickness(40),
            Child = Ui.V(16,
                Ui.Icon("", 42, Ui.Secondary).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
                Ui.Text("ScreenTranslator không khởi động được", 17, true).Also(t => t.TextAlignment = TextAlignment.Center),
                Ui.Text("Không thể tiếp tục lúc này. Vui lòng kiểm tra kết nối mạng rồi thử lại sau.",
                    color: Ui.Secondary).Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 360; }),
                Ui.Text("Mã: 0x2A1", 11.5, color: Ui.Tertiary).Also(t => t.TextAlignment = TextAlignment.Center),
                status.Also(t => t.TextAlignment = TextAlignment.Center),
                Ui.H(10, closeBtn, retryBtn).Also(h => h.HorizontalAlignment = HorizontalAlignment.Center)),
        };
        Closed += (_, _) => { if (instance == this) instance = null; };
    }

    /// Hiện màn hình lỗi chung. Gọi lại nhiều lần thì chỉ đưa cửa sổ lên trước.
    public static void Present()
    {
        instance ??= new StartupErrorWindow();
        if (!instance.IsVisible) ((Window)instance).Show();
        if (instance.WindowState == WindowState.Minimized) instance.WindowState = WindowState.Normal;
        instance.Activate();
    }

    public static void Dismiss() => instance?.Close();

    async void Retry()
    {
        retryBtn.IsEnabled = false; retryBtn.Content = "Đang thử…"; status.Text = "";
        await SessionCheck.shared.Refresh();
        retryBtn.IsEnabled = true; retryBtn.Content = "Thử lại";
        if (SessionCheck.shared.Valid()) Close();
    }
}
