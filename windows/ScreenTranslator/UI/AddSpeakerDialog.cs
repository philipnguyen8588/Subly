using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace ScreenTranslator;

/// Thêm tên nhân vật từ một câu trong nhật ký: bấm chọn các từ tạo thành tên (dùng cho tên dài / lạ app không tự nhận ra,
/// ví dụ "Charles, Botanist This tun here…" → "Charles, Botanist").
public sealed class AddSpeakerDialog : Window
{
    readonly string source;
    readonly string[] words;
    readonly AppSettings settings = AppSettings.shared;
    /// Vùng từ đang chọn (lo…hi), null = chưa chọn.
    (int lo, int hi)? range;
    readonly WrapPanel chips = new();
    readonly TextBox nameBox = new() { MinWidth = 300 };
    readonly TextBlock note = Ui.Caption("");
    readonly Button addBtn;
    bool syncing;

    public AddSpeakerDialog(string source)
    {
        this.source = source;
        // Các từ đầu câu (tên luôn nằm ở đầu câu phụ đề).
        words = source.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(14).ToArray();
        Title = "Thêm tên nhân vật";
        Width = 520; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ShowInTaskbar = false;
        Background = Ui.Res("WindowBg");
        nameBox.TextChanged += (_, _) => { if (!syncing) Refresh(); };
        addBtn = Ui.Btn("Thêm", Add, primary: true);
        addBtn.IsDefault = true;
        var cancel = Ui.Btn("Huỷ", () => DialogResult = false);
        cancel.IsCancel = true;
        var footer = Ui.Row(Ui.Text("Áp dụng cho các câu sau; câu cũ trong nhật ký giữ nguyên.", 11.5, color: Ui.Tertiary), cancel, addBtn);
        var nameRow = new DockPanel();
        var lbl = Ui.Text("Tên:", weight: FontWeights.Medium).Also(t => t.Margin = new Thickness(0, 0, 8, 0));
        DockPanel.SetDock(lbl, Dock.Left);
        nameRow.Children.Add(lbl); nameRow.Children.Add(nameBox);
        Content = new Border
        {
            Padding = new Thickness(20),
            Child = Ui.V(14,
                Ui.H(8, Ui.Icon("\uE8FA", 18, Ui.AccentStart), Ui.Text("Thêm tên nhân vật", 17, true)),
                Ui.Text("Bấm từ đầu và từ cuối của tên. Có thể sửa trực tiếp trong ô bên dưới.", color: Ui.Secondary),
                chips, nameRow, note, footer),
        };
        Guess();
        BuildChips();
        Refresh();
        Loaded += (_, _) => { nameBox.Focus(); nameBox.CaretIndex = nameBox.Text.Length; };
    }

    /// Mở hộp thoại trên cửa sổ chứa phần tử `owner`.
    public static void Open(string source, DependencyObject? owner)
    {
        var w = new AddSpeakerDialog(source) { Owner = owner != null ? Window.GetWindow(owner) : Application.Current.MainWindow };
        w.ShowDialog();
    }

    string NameText
    {
        set { syncing = true; nameBox.Text = value; nameBox.CaretIndex = value.Length; syncing = false; }
    }

    string CleanName => Clean(nameBox.Text);

    static string Clean(string s) => s.Trim().Trim(",.;:-–—!?\"".ToCharArray()).Trim();

    bool Exists => settings.speakers.Any(s => s.ToLowerInvariant() == CleanName.ToLowerInvariant());

    void BuildChips()
    {
        chips.Children.Clear();
        for (int i = 0; i < words.Length; i++)
        {
            bool on = range is (int lo, int hi) && i >= lo && i <= hi;
            var chip = new Border
            {
                Child = Ui.Text(words[i], 14, color: on ? Brushes.White : null, wrap: false, weight: on ? FontWeights.SemiBold : FontWeights.Normal),
                Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(0, 0, 6, 6), CornerRadius = new CornerRadius(6), Cursor = Cursors.Hand,
                Background = on ? Ui.AccentGradient : new SolidColorBrush(Color.FromArgb(18, 0, 0, 0)),
            };
            int idx = i;
            chip.MouseLeftButtonUp += (_, _) => Tap(idx);
            chips.Children.Add(chip);
        }
        if (source.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length > words.Length)
            chips.Children.Add(Ui.Text("…", color: Ui.Tertiary).Also(t => t.Margin = new Thickness(0, 4, 0, 6)));
    }

    /// Lần bấm đầu chọn một từ; các lần sau nới vùng chọn tới từ được bấm (bấm lại từ đã chọn ở mép → thu lại một từ).
    void Tap(int i)
    {
        if (range is (int lo, int hi))
        {
            int count = hi - lo + 1;
            if (count > 1 && i == hi) range = (lo, i - 1);
            else if (count > 1 && i == lo) range = (i + 1, hi);
            else if (lo == i && hi == i) range = null;
            else range = (Math.Min(lo, i), Math.Max(hi, i));
        }
        else range = (i, i);
        NameText = range is (int a, int b) ? Clean(string.Join(" ", words[a..(b + 1)])) : "";
        BuildChips();
        Refresh();
    }

    /// Đoán sẵn: chuỗi từ Viết Hoa ở đầu câu, bỏ từ cuối nếu nó là chữ đầu câu thoại ("Charles, Botanist This tun…").
    void Guess()
    {
        int n = 0;
        foreach (var w in words)
        {
            if (!(char.IsUpper(w[0]) || new[] { "of", "the", "de", "von", "van" }.Contains(w.ToLowerInvariant()))) break;
            n++;
            if (w.EndsWith(':')) break;
        }
        if (n >= 2 && !words[n - 1].EndsWith(':')) n--;
        if (n >= 1) { range = (0, n - 1); NameText = Clean(string.Join(" ", words[..n])); }
    }

    void Refresh()
    {
        bool exists = Exists;
        note.Text = exists ? " Tên này đã có trong danh sách nhân vật của game."
                  : !settings.showsSpeakerNames ? " Game này đang tắt “hiện tên người nói”; thêm tên sẽ bật lại." : "";
        note.Visibility = note.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        addBtn.IsEnabled = CleanName.Length > 0 && !exists;
    }

    void Add()
    {
        var n = CleanName;
        if (n.Length == 0 || Exists) return;
        if (!settings.showsSpeakerNames) settings.showsSpeakerNames = true;
        settings.LearnSpeaker(n);
        DialogResult = true;
    }
}
