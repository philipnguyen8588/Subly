using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace ScreenTranslator;

/// Mục "Hỏi đáp" của tab Cốt truyện: gõ câu hỏi về cốt truyện (vd. "Iron Kingdom có những ai?"), app trả lời
/// chỉ dựa trên cốt truyện, nhân vật, bách khoa và phụ đề đã ghi lại của game đang chọn.
public sealed class StoryChatPanel : DockPanel
{
    readonly StoryChat chat = StoryChat.shared;
    readonly StackPanel list = Ui.V(14);
    readonly ScrollViewer scroll;
    readonly TextBox input = new()
    {
        BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalContentAlignment = VerticalAlignment.Center,
        FontSize = 13.5, MaxLength = StoryQA.maxQuestion,
    };
    readonly Button send, clear;

    public StoryChatPanel()
    {
        var hint = Ui.Text("Hỏi về cốt truyện, vd. Iron Kingdom có những ai?", 13.5, color: Ui.Tertiary, wrap: false)
            .Also(t => { t.IsHitTestVisible = false; t.VerticalAlignment = VerticalAlignment.Center; t.Margin = new Thickness(2, 0, 0, 0); });
        var field = new Grid();
        field.Children.Add(hint);
        field.Children.Add(input);
        input.TextChanged += (_, _) => { hint.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; UpdateButtons(); };
        input.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Send(input.Text); e.Handled = true; } };
        var box = new Border
        {
            Height = 36, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 0, 12, 0), Background = Brushes.White,
            BorderBrush = Ui.Hex("#1F000000"), BorderThickness = new Thickness(1), Child = field,
        };
        send = Ui.IconBtn("", () => Send(input.Text), "Gửi câu hỏi (Enter)", Ui.Kind.primary);
        clear = Ui.IconBtn("", chat.Clear, "Xoá hội thoại");
        var bar = new DockPanel { Margin = new Thickness(14, 10, 14, 10) };
        var right = Ui.H(8, send, clear);
        right.Margin = new Thickness(8, 0, 0, 0);
        SetDock(right, Dock.Right);
        bar.Children.Add(right);
        bar.Children.Add(box);
        var bottom = new Border { BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(0, 1, 0, 0), Child = bar };
        SetDock(bottom, Dock.Bottom);
        Children.Add(bottom);
        list.Margin = new Thickness(14);
        scroll = Ui.Scroll(list);
        Children.Add(scroll);
        chat.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Rebuild);
        AppSettings.shared.Changed += k => { if (k is "activeProfileID" or "activeProfile") Dispatcher.BeginInvoke(Rebuild); };
        IsVisibleChanged += (_, _) => { if (IsVisible) { Rebuild(); Dispatcher.BeginInvoke(() => input.Focus()); } };
        Rebuild();
    }

    void UpdateButtons()
    {
        send.IsEnabled = !chat.isRunning && input.Text.Trim().Length > 0;
        clear.IsEnabled = !chat.isRunning;
        clear.Visibility = chat.turns.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void Send(string text)
    {
        if (chat.isRunning || text.Trim().Length == 0) return;
        chat.Ask(text);
        input.Text = "";
        input.Focus();
    }

    List<string> Suggestions()
    {
        var outp = new List<string> { "Tóm tắt cốt truyện đến hiện tại", "Nhân vật chính là ai?", "Ai đang đồng hành cùng nhân vật chính?" };
        var lore = HistoryStore.shared.story?.lore ?? new();
        if (lore.FirstOrDefault(l => l.kind == "faction") is StoryLore f) outp.Add($"{f.name} có những ai?");
        if (lore.FirstOrDefault(l => l.kind == "place") is StoryLore p) outp.Add($"{p.name} là nơi nào?");
        return outp;
    }

    void Rebuild()
    {
        if (!IsVisible) return;
        list.Children.Clear();
        var turns = chat.turns;
        if (turns.Count == 0) list.Children.Add(Intro());
        foreach (var t in turns) list.Children.Add(TurnView(t));
        UpdateButtons();
        scroll.ScrollToBottom();
    }

    UIElement Intro()
    {
        var v = Ui.V(10,
            Ui.H(6, Ui.Icon("", 14), Ui.Text($"Hỏi về cốt truyện “{AppSettings.shared.activeProfile.name}”", 14, true, wrap: false)),
            Ui.Text("App trả lời dựa trên cốt truyện, nhân vật, bách khoa và phụ đề đã ghi lại của game này: chỉ những gì bạn đã chơi tới, không tiết lộ trước. Mỗi câu hỏi dùng một lượt AI (AI của “Tóm tắt & cốt truyện”).",
                color: Ui.Secondary));
        if (HistoryStore.shared.story == null)
            v.Children.Add(Ui.Text("Game này chưa có cốt truyện: app chỉ tìm được trong phụ đề nên câu trả lời sẽ sơ sài.", 11.5, color: Ui.Orange));
        var chips = new WrapPanel();
        foreach (var s in Suggestions())
        {
            var text = s;
            var chip = new Button
            {
                Style = (Style)Application.Current.FindResource("LinkButton"), Margin = new Thickness(0, 0, 6, 6), IsEnabled = !chat.isRunning,
                Content = new Border
                {
                    Padding = new Thickness(10, 4, 10, 4), CornerRadius = new CornerRadius(12), Background = Ui.Res("CardFill"),
                    BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), Child = Ui.Text(text, 12.5, wrap: false),
                },
            };
            chip.Click += (_, _) => Send(text);
            chips.Children.Add(chip);
        }
        v.Children.Add(chips);
        return new Border
        {
            Padding = new Thickness(14), CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Color.FromArgb(16, 97, 111, 250)), Child = v,
        };
    }

    static TextBox Selectable(string text, double size, Brush? color = null) => new()
    {
        Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = size, BorderThickness = new Thickness(0),
        Background = Brushes.Transparent, Padding = new Thickness(0), Foreground = color ?? Brushes.Black,
    };

    UIElement TurnView(StoryChat.Turn t)
    {
        var q = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right, MaxWidth = 560, Margin = new Thickness(60, 0, 0, 0),
            Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(12), Background = Ui.AccentGradient,
            Child = Selectable(t.question, 13.5, Brushes.White),
        };
        UIElement content;
        if (t.answer is string a)
        {
            var meta = Ui.H(8);
            if (t.backend is BackendKind b) meta.Children.Add(Ui.Text($"{BackendLabels.Label(b)} · {t.ms / 1000.0:0.0}s", 11, color: Ui.Tertiary, wrap: false));
            meta.Children.Add(Ui.InlineIconBtn("", () => Ui.CopyText(a), "Copy"));
            content = Ui.V(6, Selectable(a, 14), meta);
        }
        else if (t.error is string err) content = Ui.H(6, Ui.Icon("", 13, Ui.Danger), Ui.Text(err, color: Ui.Danger));
        else content = Ui.Text("Đang tìm trong cốt truyện…", color: Ui.Secondary);
        var answer = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Left, MaxWidth = 760, Margin = new Thickness(0, 0, 40, 0),
            Padding = new Thickness(12), CornerRadius = new CornerRadius(12), Background = Ui.Res("CardFill"),
            BorderBrush = Ui.Res("CardStroke"), BorderThickness = new Thickness(1), Child = content,
        };
        return Ui.V(8, q, answer);
    }
}
