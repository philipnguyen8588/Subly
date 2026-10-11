using System;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ScreenTranslator;

/// Xem lại cấu hình Remote Play đã lưu (sau khi đăng ký / nhập từ chiaki-ng). Khoá bí mật ẩn mặc định; có nút chép tất cả.
public sealed class PS5ConfigWindow : Window
{
    readonly PS5Host host;
    readonly AppSettings S = AppSettings.shared;
    readonly TextBlock registText, rpText;
    bool showSecrets;

    string RegistKeyText => Encoding.UTF8.GetString(host.registKey.TakeWhile(b => b != 0).ToArray());
    string RpKeyHex => string.Concat(host.rpKey.Select(b => b.ToString("x2")));
    string AccountText => Convert.ToBase64String(host.accountID);
    string Quality => $"{(S.ps5Resolution == 4 ? "1080p" : "720p")} · {S.ps5FPS} fps";
    static string Mask(string s) => new('•', Math.Max(8, Math.Min(s.Length, 24)));

    string Summary =>
        $"Máy: {host.nickname} ({(host.ps5 ? "PS5" : "PS4")})\n" +
        $"IP: {(host.host.Length == 0 ? "tự dò theo MAC" : host.host)}\n" +
        $"MAC: {host.macString}\n" +
        $"Account ID: {AccountText}\n" +
        $"Regist key: {RegistKeyText}\n" +
        $"RP key: {RpKeyHex}\n" +
        $"Hình: {Quality}";

    public PS5ConfigWindow(PS5Host host, Window? owner)
    {
        this.host = host;
        Title = "Cấu hình kết nối Remote Play";
        Width = 520; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        Owner = owner; WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false; Background = Ui.Res("WindowBg");

        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        TextBlock Row(string k, string v)
        {
            int r = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition());
            var key = Ui.Caption(k).Also(t => { t.Margin = new Thickness(0, 3, 14, 3); });
            var val = Ui.Text(v, 12.5, wrap: false).Also(t => { t.FontFamily = new FontFamily("Consolas"); t.TextTrimming = TextTrimming.CharacterEllipsis; t.Margin = new Thickness(0, 3, 0, 3); });
            Grid.SetRow(key, r); Grid.SetColumn(key, 0); Grid.SetRow(val, r); Grid.SetColumn(val, 1);
            grid.Children.Add(key); grid.Children.Add(val);
            return val;
        }
        Row("Máy", $"{host.nickname} · {(host.ps5 ? "PS5" : "PS4")}");
        Row("IP", host.host.Length == 0 ? "tự dò theo MAC khi kết nối" : host.host);
        Row("MAC", host.macString);
        Row("Account ID", AccountText);
        registText = Row("Regist key", Mask(RegistKeyText));
        rpText = Row("RP key", Mask(RpKeyHex));
        Row("Hình", Quality);

        var reveal = new CheckBox { Content = Ui.Text("Hiện khoá"), IsChecked = false };
        reveal.Checked += (_, _) => { showSecrets = true; Refresh(); };
        reveal.Unchecked += (_, _) => { showSecrets = false; Refresh(); };
        Button? copy = null;
        copy = Ui.Btn("Chép tất cả", () => { Ui.CopyText(Summary); copy!.Content = "Đã chép"; });
        var close = Ui.Btn("Đóng", Close, primary: true);
        close.IsCancel = true;
        var bar = Ui.Row(reveal, copy, close);

        Content = new Border
        {
            Padding = new Thickness(18),
            Child = Ui.V(10,
                Ui.Text("Cấu hình kết nối Remote Play", 15, true),
                Ui.Card(grid, 12),
                bar,
                Ui.Caption("Khoá đăng ký và RP key là bí mật của máy này, chỉ chia sẻ khi thật cần. Đổi máy: menu ⚙ → Quên máy này.")),
        };
    }

    void Refresh()
    {
        registText.Text = showSecrets ? RegistKeyText : Mask(RegistKeyText);
        rpText.Text = showSecrets ? RpKeyHex : Mask(RpKeyHex);
    }
}
