using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace ScreenTranslator;

/// Hỏi email lần đầu mở app (bản phát hành). Email gửi kèm lên server để chủ app biết máy của ai khi duyệt.
/// Tương đương EmailPromptView.swift của bản macOS. Modal: chưa nhập xong thì chưa qua bước kiểm tra máy.
public sealed class EmailPromptWindow : Window
{
    readonly TextBox emailBox = new() { MinWidth = 280 };
    readonly Button continueBtn;

    EmailPromptWindow()
    {
        Title = "ScreenTranslator";
        Width = 460; Height = 470; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen; ShowInTaskbar = true;
        Background = Ui.Res("WindowBg");
        emailBox.Text = AppSettings.shared.userEmail;

        continueBtn = Ui.Btn("Tiếp tục", Save, primary: true);
        continueBtn.IsDefault = true;
        emailBox.TextChanged += (_, _) => continueBtn.IsEnabled = Valid;
        emailBox.KeyDown += (_, e) => { if (e.Key == Key.Enter && Valid) Save(); };

        Content = new Border
        {
            Padding = new Thickness(40),
            Child = Ui.V(16,
                Ui.Icon("", 40, Ui.AccentStart).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
                Ui.Text("Nhập email của bạn", 17, true).Also(t => t.TextAlignment = TextAlignment.Center),
                Ui.Text("Nhập email để đăng ký dùng thử app.", color: Ui.Secondary)
                    .Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 360; }),
                emailBox.Also(b => b.HorizontalAlignment = HorizontalAlignment.Center),
                continueBtn.Also(b => b.HorizontalAlignment = HorizontalAlignment.Center),
                Ui.SupportBox().Also(b => b.HorizontalAlignment = HorizontalAlignment.Center),
                Ui.Text(AppInfo.VersionLabel, 11.5, color: Ui.Tertiary).Also(t => t.TextAlignment = TextAlignment.Center)),
        };
        continueBtn.IsEnabled = Valid;
        Loaded += (_, _) => { emailBox.Focus(); emailBox.CaretIndex = emailBox.Text.Length; };
    }

    bool Valid
    {
        get
        {
            var e = emailBox.Text.Trim();
            var at = e.IndexOf('@');
            if (at <= 0) return false;
            var domain = e.Substring(at + 1);
            return domain.Contains('.') && !domain.EndsWith(".") && !e.Contains(' ');
        }
    }

    void Save()
    {
        AppSettings.shared.userEmail = emailBox.Text.Trim();
        Close();
    }

    /// Hiện modal hỏi email; trả về khi người dùng nhập xong.
    public static void Prompt()
    {
        var w = new EmailPromptWindow();
        if (Application.Current?.MainWindow is Window main && main.IsVisible) w.Owner = main;
        w.ShowDialog();
    }
}
