using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ScreenTranslator;

/// Cửa sổ Cài đặt: 10 mục ở thanh bên (Dịch, AI, Capture & OCR, Voice, Overlay, Thuật ngữ chung, Game, Phím tắt, Điện thoại / Web, Sao lưu).
public sealed class SettingsWindow : Window
{
    readonly ListBox sidebar = new() { Width = 200, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(6) };
    readonly ContentControl page = new();
    static readonly (string key, string title, string glyph)[] tabs =
    {
        ("translate", "Dịch", ""), ("ai", "AI", "\uE99A"), ("capture", "Capture & OCR", ""), ("voice", "Voice", ""), ("overlay", "Overlay", ""),
        ("glossary", "Thuật ngữ chung", ""), ("profile", "Game", ""), ("hotkeys", "Phím tắt", ""), ("web", "Điện thoại / Web", ""),
        ("backup", "Sao lưu", "\uE753"),
    };
    AppSettings S => AppSettings.shared;

    public SettingsWindow()
    {
        Title = "Cài đặt";
        Width = 860; Height = 640; MinWidth = 760; MinHeight = 560;
        Background = Ui.Res("WindowBg");
        Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Resources/AppIcon.ico"));   // giữ đủ các cỡ của .ico (xem MainWindow)
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        foreach (var (_, title, glyph) in tabs)
            sidebar.Items.Add(new ListBoxItem { Content = Ui.H(10, Ui.Icon(glyph, 14), Ui.Text(title, wrap: false)), Padding = new Thickness(10, 7, 10, 7) });
        sidebar.SelectionChanged += (_, _) => ShowPage();
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var side = new Border { Child = sidebar, Background = new SolidColorBrush(Color.FromArgb(10, 0, 0, 0)) };
        var div = new Border { Width = 1, Background = Ui.Res("CardStroke") };
        Grid.SetColumn(div, 1); Grid.SetColumn(page, 2);
        g.Children.Add(side); g.Children.Add(div); g.Children.Add(page);
        Content = g;
        sidebar.SelectedIndex = 0;
        // Tiến độ tải giọng / trạng thái máy chủ web → vẽ lại trang đang mở.
        VoiceCatalog.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(() => { if (IsVisible && CurrentKey == "voice") ShowPage(); });
        WebServer.shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(() => { if (IsVisible && CurrentKey == "web") ShowPage(); });
        Action onBackup = () => { if (IsVisible && CurrentKey == "backup") ShowPage(); };
        BackupModel.Changed += onBackup;
        Closing += (_, _) => saveGlossary?.Invoke();
        Closed += (_, _) => BackupModel.Changed -= onBackup;
    }

    Action? saveGlossary;
    string CurrentKey => tabs[Math.Max(0, sidebar.SelectedIndex)].key;

    public void Select(string key)
    {
        int i = Array.FindIndex(tabs, t => t.key == key);
        if (i >= 0) sidebar.SelectedIndex = i;
    }

    void ShowPage()
    {
        saveGlossary?.Invoke(); saveGlossary = null;
        var key = CurrentKey;
        UIElement body = key switch
        {
            "translate" => Translate(), "ai" => AI(), "capture" => Capture(), "voice" => Voice(), "overlay" => Overlay(),
            "glossary" => Glossary(), "profile" => Profiles(), "hotkeys" => Hotkeys(), "backup" => Backup(), _ => Web(),
        };
        if (body is FrameworkElement fe) fe.Margin = new Thickness(20, 16, 20, 16);
        page.Content = key == "glossary" ? body : Ui.Scroll(body);
    }

    void Reload() => Dispatcher.BeginInvoke(ShowPage);

    // MARK: Dịch

    /// Kết quả nút "Kiểm tra" gần nhất của từng việc (giữ khi trang vẽ lại).
    readonly Dictionary<AITask, (bool ok, string text)> taskTest = new();

    static string PickerLabel(TranslationEngine e) => e switch
    {
        TranslationEngine.auto => "Gemini · miễn phí", TranslationEngine.openAI => "OpenAI · trả phí",
        TranslationEngine.anthropic => "Anthropic Claude · trả phí", TranslationEngine.custom => "API tuỳ chỉnh",
        TranslationEngine.shared => "AI share",
        _ => "Google Translate · miễn phí, không cần key",
    };
    static string PickerLabel(ScreenEngine e) => e switch
    {
        ScreenEngine.gemini => "Gemini · miễn phí", ScreenEngine.openAI => "OpenAI · trả phí", ScreenEngine.anthropic => "Anthropic Claude · trả phí",
        ScreenEngine.custom => "API tuỳ chỉnh", ScreenEngine.shared => "AI share",
        ScreenEngine.google => "Google Translate · không cần key", _ => "Giống dịch phụ đề",
    };
    static string PickerLabel(SummaryEngine e) => e switch
    {
        SummaryEngine.gemini => "Gemini · miễn phí", SummaryEngine.openAI => "OpenAI · trả phí", SummaryEngine.anthropic => "Anthropic Claude · trả phí",
        SummaryEngine.custom => "API tuỳ chỉnh", SummaryEngine.shared => "AI share", _ => "Giống dịch phụ đề",
    };

    /// Cài đặt → Dịch: ngôn ngữ đích, rồi ba khối nổi bật cho ba việc dùng AI (giống bản macOS).
    UIElement Translate()
    {
        var lang = Ui.Picker("", TargetLanguage.all.Select(l => (l.code, l.name)), () => S.targetLanguage, v => S.targetLanguage = v, 200);
        var top = Ui.H(12, Ui.Icon("", 14, Ui.Secondary), Ui.Text("Dịch sang", color: Ui.Secondary, wrap: false), lang);
        if (RuntimeConfig.Enabled)
        {
            var emailBox = new TextBox { Text = S.userEmail, Width = 240, ToolTip = "Email" };
            emailBox.LostFocus += (_, _) => { var t = emailBox.Text.Trim(); if (t != S.userEmail) S.userEmail = t; };
            top.Children.Add(new Border { Width = 24 });
            top.Children.Add(Ui.Text("Email", color: Ui.Secondary, wrap: false));
            top.Children.Add(emailBox);
        }
        top.Margin = new Thickness(4, 0, 0, 16);

        // "AI share" chỉ hiện trong ô chọn AI khi đã nhập token.
        bool hasShare = S.aiShare != null;
        var subEngine = Ui.Picker("", Enum.GetValues<TranslationEngine>().Where(e => e != TranslationEngine.shared || hasShare || S.translationEngine == e)
            .Select(e => (e, PickerLabel(e))), () => S.translationEngine, v => { S.translationEngine = v; Reload(); }, 300);
        var scrEngine = Ui.Picker("", Enum.GetValues<ScreenEngine>().Where(e => e != ScreenEngine.shared || hasShare || S.screenEngine == e)
            .Select(e => (e, e == ScreenEngine.sameAsSubtitle ? $"Giống dịch phụ đề ({Readiness.ShortEngine(S.engine)})" : PickerLabel(e))),
            () => S.screenEngine, v => { S.screenEngine = v; Reload(); }, 300);
        var sumEngine = Ui.Picker("", Enum.GetValues<SummaryEngine>().Where(e => e != SummaryEngine.shared || hasShare || S.summaryEngine == e)
            .Select(e => (e, PickerLabel(e))), () => S.summaryEngine, v => { S.summaryEngine = v; Reload(); }, 300);

        var storyRows = new List<UIElement?> { Ui.Toggle("Tự viết cốt truyện khi đang dịch", () => S.storyEnabled, v => { S.storyEnabled = v; Reload(); }) };
        if (S.storyEnabled) storyRows.Add(Ui.Stepper(() => $"Cập nhật mỗi {S.storyIntervalMin} phút", 5, 60, 5, () => S.storyIntervalMin, v => S.storyIntervalMin = v));

        return Ui.V(0, top,
            TaskBlock(AITask.subtitle, subEngine,
                Ui.Stepper(() => $"Ngữ cảnh: {S.contextPairs} câu trước", 0, 10, 1, () => S.contextPairs, v => S.contextPairs = v),
                Ui.BlockRow("Hàng đợi", Ui.Picker("", Enum.GetValues<QueueMode>().Select(q => (q, Labels.Of(q))), () => S.queueMode, v => S.queueMode = v, 260))),
            TaskBlock(AITask.screen, scrEngine,
                Ui.Slider("Thời gian chờ", 5, 60, 5, () => S.analyzeTimeout, v => S.analyzeTimeout = v, v => $"{(int)v} s"),
                Ui.Toggle("Đọc tóm tắt bằng giọng nói", () => S.analyzeSpeakSummary, v => S.analyzeSpeakSummary = v)),
            TaskBlock(AITask.summary, sumEngine, storyRows.ToArray()));
    }

    /// Khối của một việc dùng AI: chọn AI, chọn model, trạng thái và nút Kiểm tra.
    UIElement TaskBlock(AITask task, UIElement enginePicker, params UIElement?[] extra)
    {
        var e = Readiness.Engine(task);
        var issue = Readiness.IssueOf(task);
        bool required = Readiness.IsRequired(task);
        var trailing = new List<UIElement?>
        {
            issue == null ? Ui.Chip(e.keyless ? "Sẵn sàng · không cần key" : "Đã kiểm tra", Ui.Tone.ok)
                : Ui.Chip(required ? issue.title : $"{issue.title} · không bắt buộc", required ? Ui.Tone.warn : Ui.Tone.idle),
        };
        if (issue?.tab == "ai") trailing.Add(Ui.Btn("Nhập key", () => Select("ai"), kind: Ui.Kind.tinted));
        else if (e.provider != null)
        {
            Button? btn = null;
            btn = Ui.Btn("Kiểm tra", async () =>
            {
                btn!.IsEnabled = false; btn.Content = "Đang kiểm tra…";
                var (ok, msg) = await Readiness.Test(task);
                taskTest[task] = (ok, ok ? $"OK: {msg}" : $"Lỗi: {msg}");
                Reload();
            }, kind: issue == null ? Ui.Kind.secondary : Ui.Kind.tinted, minWidth: 110);
            trailing.Add(btn);
        }
        var rows = new List<UIElement?> { Ui.BlockRow("AI", enginePicker) };
        if (e.provider is string p) rows.Add(Ui.BlockRow("Model", TaskModelBox(task, p)));
        if (taskTest.TryGetValue(task, out var r)) rows.Add(Ui.Caption(r.text, r.ok ? Brushes.Green : Ui.Danger));
        rows.Add(Ui.Divider());
        rows.AddRange(extra);
        return Ui.Block(Readiness.TaskTitle(task), Readiness.TaskGlyph(task), null, trailing.ToArray(), rows.ToArray());
    }

    /// Model riêng cho một việc (mặc định = model ở mục AI).
    UIElement TaskModelBox(AITask task, string provider)
    {
        var box = new ComboBox { Width = 300 };
        var key = $"{task}.{provider}";
        var current = S.TaskModel(task, provider) ?? "";
        // AI share: chỉ các model đã share.
        var models = provider == "shared" ? S.aiShare?.models ?? new List<string>()
            : (S.aiModelLists.TryGetValue(provider, out var saved) && saved.Count > 0 ? (IEnumerable<string>)saved : SuggestedModels(provider)).ToList();
        if (current.Length > 0 && !models.Contains(current)) models.Add(current);
        var def = S.DefaultModel(provider);
        box.Items.Add(new ComboBoxItem { Content = $"Mặc định ({(def.Length == 0 ? "chưa chọn" : def)})", Tag = "" });
        foreach (var m in models) box.Items.Add(new ComboBoxItem { Content = m, Tag = m });
        box.SelectedIndex = current.Length == 0 ? 0 : models.IndexOf(current) + 1;
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is not ComboBoxItem item || item.Tag is not string chosen) return;
            var all = S.taskModels;
            if (chosen.Length == 0) all.Remove(key); else all[key] = chosen;
            S.taskModels = all;
            taskTest.Remove(task);
            Reload();
        };
        return box;
    }

    record CloudInfoRow(string name, string model, bool ready);
    /// Tên, model đang chọn và đã cài đặt chưa của một AI qua mạng (theo tên engine); null = Google Translate.
    CloudInfoRow? CloudInfo(string engine) => engine switch
    {
        "gemini" => new CloudInfoRow("Gemini", S.geminiModel, S.geminiAPIKeys.Count > 0),
        "openAI" => new CloudInfoRow("OpenAI", S.openAIModel, S.openAIKey.Length > 0),
        "anthropic" => new CloudInfoRow("Anthropic", S.anthropicModel, S.anthropicKey.Length > 0),
        "custom" => new CloudInfoRow("API tuỳ chỉnh", S.customModel, S.customReady),
        "shared" => new CloudInfoRow("AI share", S.DefaultModel("shared"), S.aiShare != null && S.aiShareToken.Length > 0),
        _ => null,
    };

    /// Model gợi ý sẵn của từng nhà cung cấp khi chưa bấm "Tải model" ở mục AI.
    static IEnumerable<string> SuggestedModels(string provider) => provider switch
    {
        "gemini" => GeminiBackend.models, "openAI" => OpenAIBackend.models, "anthropic" => AnthropicBackend.models, _ => Array.Empty<string>(),
    };

    // MARK: AI

    /// Một nhà cung cấp trả phí trong mục AI (Gemini có mục riêng vì lưu được nhiều key).
    record AiProvider(string id, string title, string keyHint, string[] suggested,
        Func<string> getKey, Action<string> setKey, Func<string> getModel, Action<string> setModel,
        Func<double> getTimeout, Action<double> setTimeout,
        Func<string, Task<List<string>>> listModels, Func<string, Task<(bool ok, string message)>> test);

    /// Kết quả "Test key" của từng key Gemini đã lưu (giữ lại khi trang vẽ lại sau khi thêm / xoá key).
    readonly Dictionary<string, string> geminiKeyResults = new();

    /// Che key khi hiện trong danh sách: chỉ để lại vài ký tự đầu và cuối.
    static string Mask(string key) => key.Length > 12 ? $"{key[..6]}…{key[^4..]}" : new string('•', key.Length);

    /// Ô chọn model (gõ tay được) + hàm nạp lại danh sách sau khi bấm "Tải model".
    (ComboBox box, Action<IEnumerable<string>> fill) ModelBox(string id, IEnumerable<string> suggested, Func<string> get, Action<string> set)
    {
        var box = new ComboBox { MinWidth = 260, IsEditable = true };
        void Fill(IEnumerable<string> items)
        {
            var cur = get();
            box.Items.Clear();
            foreach (var m in items) box.Items.Add(m);
            if (cur.Length > 0 && !box.Items.Contains(cur)) box.Items.Add(cur);
            box.SelectedItem = cur.Length > 0 ? cur : null;
            box.Text = cur;
        }
        Fill(S.aiModelLists.TryGetValue(id, out var saved) && saved.Count > 0 ? saved : suggested);
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is string m && m != get()) set(m); };
        box.LostFocus += (_, _) => { var t = box.Text.Trim(); if (t.Length > 0 && t != get()) set(t); };
        return (box, Fill);
    }

    void SaveModelList(string id, List<string> list)
    {
        var all = S.aiModelLists;
        all[id] = list;
        S.aiModelLists = all;
    }

    /// Cài đặt → AI: key và model của từng nhà cung cấp. Mục Dịch chỉ còn chọn dùng AI nào.
    UIElement AI()
    {
        var providers = new[]
        {
            new AiProvider("openAI", "OpenAI (trả phí)", "API key (platform.openai.com/api-keys)", OpenAIBackend.models,
                () => S.openAIKey, v => S.openAIKey = v, () => S.openAIModel, v => S.openAIModel = v,
                () => S.openAITimeout, v => S.openAITimeout = v,
                k => OpenAIBackend.ListModels(k), k => OpenAIBackend.Test(k, S.openAIModel)),
            new AiProvider("anthropic", "Anthropic Claude (trả phí)", "API key (console.anthropic.com → API keys)", AnthropicBackend.models,
                () => S.anthropicKey, v => S.anthropicKey = v, () => S.anthropicModel, v => S.anthropicModel = v,
                () => S.anthropicTimeout, v => S.anthropicTimeout = v,
                k => AnthropicBackend.ListModels(k), k => AnthropicBackend.Test(k, S.anthropicModel)),
            new AiProvider("custom", "API tuỳ chỉnh (tương thích OpenAI)", "API key (bỏ trống nếu máy chủ không cần)", Array.Empty<string>(),
                () => S.customKey, v => S.customKey = v, () => S.customModel, v => S.customModel = v,
                () => S.customTimeout, v => S.customTimeout = v,
                k => OpenAIBackend.ListModels(k, OpenAIBackend.NormalizeBaseURL(S.customBaseURL)),
                k => OpenAIBackend.Test(k, S.customModel, OpenAIBackend.NormalizeBaseURL(S.customBaseURL), requiresKey: false)),
        };
        var stack = Ui.V(0);
        if (AIShareClient.Available) stack.Children.Add(AIShareSection());
        stack.Children.Add(GeminiSection());
        foreach (var p in providers) stack.Children.Add(ProviderSection(p));
        return stack;
    }

    /// Kết quả nút Nhập / Kiểm tra của mục AI share (giữ khi trang vẽ lại).
    string? shareResult;

    /// AI share: dán token do chủ server cấp. Key thật nằm trên server, app chỉ gửi token qua proxy và chỉ dùng được
    /// các model đã share; chủ server sửa model hay thu hồi thì app nhận ở lần kiểm tra kế tiếp.
    UIElement AIShareSection()
    {
        var info = S.aiShare;
        var rows = new List<UIElement?>();
        if (info != null)
        {
            var name = Ui.Text(info.label.Length == 0 ? "(không tên)" : info.label, wrap: false);
            name.FontWeight = FontWeights.SemiBold;
            rows.Add(Ui.Row(Ui.H(8, Ui.Icon("\uE8D7", 13, Ui.Secondary), name,
                    Ui.Text("· " + AIShareClient.ProviderName(info.provider), color: Ui.Secondary, wrap: false)),
                Ui.IconBtn("\uE74D", () => { AIShareClient.Remove(); shareResult = null; Reload(); }, "Bỏ AI share này")));
            var models = Ui.Text(string.Join(", ", info.models));
            models.FontFamily = new FontFamily("Consolas");
            rows.Add(Ui.BlockRow("Model", models));
        }
        var tokenBox = new TextBox { Width = 300, ToolTip = "Dán token sts_…" };
        Button? importBtn = null;
        importBtn = Ui.Btn("Nhập", async () =>
        {
            var t = tokenBox.Text.Trim();
            if (t.Length == 0) return;
            importBtn!.IsEnabled = false; importBtn.Content = "Đang nhập…";
            try
            {
                var i = await AIShareClient.ImportToken(t);
                shareResult = $"OK: đã nhập “{i.label}” · {AIShareClient.ProviderName(i.provider)} · {i.models.Count} model";
            }
            catch (Exception e) { shareResult = $"Lỗi: {e.Message}"; }
            Reload();
        }, primary: true);
        rows.Add(Ui.BlockRow(info == null ? "Token" : "Token mới", tokenBox, importBtn));
        if (shareResult != null) rows.Add(ResultText(shareResult));
        rows.Add(Ui.Caption("Chọn “AI share” ở Cài đặt → Dịch để dùng cho từng việc. Key thật nằm trên server của người share; app chỉ giữ token."));

        (string text, Ui.Tone tone, string? uses) st = info == null ? ("Chưa nhập", Ui.Tone.idle, null) : AiStatus("shared", true);
        if (info?.revoked == true) st = ("Bị thu hồi", Ui.Tone.warn, st.uses);
        var trailing = new List<UIElement?> { Ui.Chip(st.text, st.tone) };
        if (info != null)
        {
            Button? check = null;
            check = Ui.Btn("Kiểm tra", async () =>
            {
                check!.IsEnabled = false; check.Content = "Đang kiểm tra…";
                var err = await AIShareClient.Refresh();
                shareResult = err != null ? $"Lỗi: {err.Message}" : await TestKeyAll("shared", S.aiShareToken);
                Reload();
            }, minWidth: 110);
            trailing.Add(check);
        }
        return Ui.Block("AI share", "\uE716", st.uses ?? "Dùng key người khác chia sẻ (qua server, không thấy key)", trailing.ToArray(), rows.ToArray());
    }

    /// Các model cần thử khi bấm Test: model mặc định + model riêng của các việc đang dùng nhà cung cấp này.
    static List<string> ModelsToTest(string p)
    {
        var out_ = new List<string>();
        foreach (var m in new[] { AppSettings.shared.DefaultModel(p) }.Concat(Readiness.TasksUsing(p).Select(t => Readiness.Model(t, p))))
            if (m.Length > 0 && !out_.Contains(m)) out_.Add(m);
        return out_;
    }

    /// Test một key với mọi model cần thử, ghi nhận từng kết quả; trả về dòng kết quả để hiện.
    static async Task<string> TestKeyAll(string p, string key)
    {
        var models = ModelsToTest(p);
        if (models.Count == 0) return "Lỗi: chưa chọn model";
        var fails = new List<string>();
        string okText = "";
        foreach (var m in models)
        {
            var (ok, msg) = await Readiness.Call(p, key, m);
            Readiness.Record(p, m, key, ok);
            if (ok) okText = msg; else fails.Add(models.Count > 1 ? $"{m}: {msg}" : msg);
        }
        return fails.Count == 0 ? $"OK: {okText}" : "Lỗi: " + string.Join("; ", fails);
    }

    /// Trạng thái của một nhà cung cấp và tên các việc đang dùng nó.
    static (string text, Ui.Tone tone, string? uses) AiStatus(string p, bool hasKey)
    {
        var uses = Readiness.TasksUsing(p);
        var usesText = uses.Count == 0 ? null : "Đang dùng cho: " + string.Join(", ", uses.Select(Readiness.TaskTitle));
        if (!hasKey) return ("Chưa có key", uses.Count == 0 ? Ui.Tone.idle : Ui.Tone.warn, usesText);
        if (uses.Count == 0) return ("Chưa dùng", Ui.Tone.idle, usesText);
        return uses.All(t => Readiness.IsVerified(p, Readiness.Model(t, p))) ? ("Đã kiểm tra", Ui.Tone.ok, usesText) : ("Chưa kiểm tra", Ui.Tone.warn, usesText);
    }

    static TextBlock ResultText(string text) => Ui.Caption(text, text.StartsWith("OK") ? Brushes.Green : Ui.Danger);

    /// Gemini miễn phí: lưu nhiều key, app dùng xoay vòng để chia đều quota.
    UIElement GeminiSection()
    {
        var keys = S.geminiAPIKeys;
        var rows = new List<UIElement?>();
        async Task TestKey(string k, Button btn, TextBlock target)
        {
            btn.IsEnabled = false; btn.Content = "Đang test…"; target.Text = "";
            var text = await TestKeyAll("gemini", k);
            target.Text = text; target.Foreground = text.StartsWith("OK") ? Brushes.Green : Ui.Danger;
            if (S.geminiAPIKeys.Contains(k)) { geminiKeyResults[k] = text; Reload(); }
            btn.IsEnabled = true; btn.Content = "Test";
        }
        var savedTests = new List<Action>();
        foreach (var k in keys)
        {
            var key = k;
            var status = geminiKeyResults.TryGetValue(key, out var r) ? ResultText(r)
                : ModelsToTest("gemini").All(m => Readiness.IsVerified("gemini", m, key)) ? Ui.Caption("Đã kiểm tra", Brushes.Green) : Ui.Caption("");
            status.MaxWidth = 300; status.TextTrimming = TextTrimming.CharacterEllipsis; status.TextWrapping = TextWrapping.NoWrap;
            Button? testBtn = null;
            testBtn = Ui.Btn("Test", async () => await TestKey(key, testBtn!, status), minWidth: 90);
            savedTests.Add(async () => await TestKey(key, testBtn!, status));
            var mask = Ui.Text(Mask(key), wrap: false);
            mask.FontFamily = new FontFamily("Consolas");
            rows.Add(Ui.Row(Ui.H(8, Ui.Icon("", 13, Ui.Secondary), mask, status),
                testBtn,
                Ui.IconBtn("", () => { S.geminiAPIKeys = S.geminiAPIKeys.Where(x => x != key).ToList(); geminiKeyResults.Remove(key); Reload(); }, "Xoá key này")));
        }

        var newKey = new PasswordBox { Width = 300 };
        var result = Ui.Caption("");
        Button? testNew = null;
        testNew = Ui.Btn("Test", async () =>
        {
            var k = newKey.Password.Trim();
            if (k.Length > 0) await TestKey(k, testNew!, result);
        }, minWidth: 90);
        rows.Add(Ui.BlockRow(keys.Count == 0 ? "API key" : "Thêm key", newKey,
            Ui.Btn("Lưu", () =>
            {
                var k = newKey.Password.Trim();
                if (k.Length == 0) return;
                if (S.geminiAPIKeys.Contains(k)) { result.Text = "Key này đã có trong danh sách"; return; }
                S.geminiAPIKeys = S.geminiAPIKeys.Append(k).ToList();
                Reload();
            }, primary: true),
            testNew));
        rows.Add(result);

        var (modelBox, fill) = ModelBox("gemini", GeminiBackend.models, () => S.geminiModel, m => S.geminiModel = m);
        Button? loadBtn = null;
        loadBtn = Ui.Btn("Tải model", async () =>
        {
            var k = newKey.Password.Trim().Length > 0 ? newKey.Password.Trim() : S.geminiAPIKey;
            if (k.Length == 0) { result.Text = "Chưa có key để tải danh sách model"; return; }
            loadBtn!.IsEnabled = false; loadBtn.Content = "Đang tải…";
            try
            {
                var list = await GeminiBackend.ListModels(k, S.geminiBaseURL);
                if (list.Count > 0)
                {
                    SaveModelList("gemini", list);
                    if (!list.Contains(S.geminiModel)) S.geminiModel = list[0];
                    fill(list);
                }
                result.Text = $"OK: có {list.Count} model dùng được"; result.Foreground = Brushes.Green;
            }
            catch (Exception e) { result.Text = $"Lỗi: không tải được danh sách: {e.Message}"; result.Foreground = Ui.Danger; }
            loadBtn.IsEnabled = true; loadBtn.Content = "Tải model";
        }, tip: "Lấy danh sách model thật mà key này dùng được");
        rows.Add(Ui.BlockRow("Model", modelBox, loadBtn));
        rows.Add(Ui.Slider("Thời gian chờ", 2, 10, 0.5, () => S.geminiTimeout, x => S.geminiTimeout = x, x => $"{x:0.0} s"));
        var st = AiStatus("gemini", keys.Count > 0);
        var trailing = new List<UIElement?> { Ui.Chip(st.text, st.tone) };
        if (keys.Count > 1) trailing.Add(Ui.Btn("Test tất cả", () => { foreach (var t in savedTests) t(); }));
        return Ui.Block("Gemini", "", st.uses ?? "Miễn phí · lưu được nhiều key, dùng xoay vòng", trailing.ToArray(), rows.ToArray());
    }

    /// Một nhà cung cấp trả phí / tuỳ chỉnh: key (lưu / test / xoá), model (chọn hoặc tải danh sách), thời gian chờ.
    UIElement ProviderSection(AiProvider p)
    {
        bool isCustom = p.id == "custom";
        var rows = new List<UIElement?>();
        if (isCustom)
        {
            var url = new TextBox { Text = S.customBaseURL, Width = 300, ToolTip = "Ví dụ https://openrouter.ai/api/v1" };
            url.LostFocus += (_, _) => { var t = url.Text.Trim(); if (t != S.customBaseURL) { S.customBaseURL = t; Reload(); } };
            rows.Add(Ui.BlockRow("Địa chỉ API", url));
        }
        var key = new PasswordBox { Password = p.getKey(), Width = 300 };
        var result = Ui.Caption("");
        // API tuỳ chỉnh có thể không cần key; hai hãng còn lại bắt buộc.
        bool CanCall(string k) => isCustom ? S.customBaseURL.Trim().Length > 0 : k.Length > 0;
        Button? testBtn = null, loadBtn = null;
        testBtn = Ui.Btn("Test", async () =>
        {
            var k = key.Password.Trim();
            if (!CanCall(k)) { result.Text = isCustom ? "Chưa nhập địa chỉ API" : "Chưa nhập key"; return; }
            testBtn!.IsEnabled = false; testBtn.Content = "Đang test…"; result.Text = "";
            var text = await TestKeyAll(p.id, k);
            result.Text = text; result.Foreground = text.StartsWith("OK") ? Brushes.Green : Ui.Danger;
            testBtn.IsEnabled = true; testBtn.Content = "Test";
        }, minWidth: 90);
        rows.Add(Ui.BlockRow("API key", key,
            Ui.Btn("Lưu", () => { p.setKey(key.Password.Trim()); Reload(); }, primary: true),
            testBtn,
            Ui.IconBtn("", () => { p.setKey(""); key.Password = ""; Reload(); }, "Xoá key")));
        rows.Add(result);
        if (isCustom)
        {
            var model = new TextBox { Text = S.customModel, Width = 300, ToolTip = "Gõ tên model hoặc bấm Tải model" };
            model.LostFocus += (_, _) => { var t = model.Text.Trim(); if (t != S.customModel) S.customModel = t; };
            rows.Add(Ui.BlockRow("Tên model", model));
        }
        var (modelBox, fill) = ModelBox(p.id, p.suggested, p.getModel, p.setModel);
        loadBtn = Ui.Btn("Tải model", async () =>
        {
            var k = key.Password.Trim();
            if (!CanCall(k)) { result.Text = isCustom ? "Chưa nhập địa chỉ API" : "Chưa nhập key"; return; }
            loadBtn!.IsEnabled = false; loadBtn.Content = "Đang tải…";
            try
            {
                var list = await p.listModels(k);
                if (list.Count > 0)
                {
                    SaveModelList(p.id, list);
                    if (isCustom && p.getModel().Length == 0) p.setModel(list[0]);
                    fill(list);
                }
                result.Text = $"OK: có {list.Count} model dùng được"; result.Foreground = Brushes.Green;
            }
            catch (Exception e) { result.Text = $"Lỗi: không tải được danh sách: {e.Message}"; result.Foreground = Ui.Danger; }
            loadBtn.IsEnabled = true; loadBtn.Content = "Tải model";
        }, tip: "Lấy danh sách model thật mà key này dùng được");
        rows.Add(Ui.BlockRow("Model", modelBox, loadBtn));
        rows.Add(Ui.Slider("Thời gian chờ", 2, 15, 0.5, p.getTimeout, p.setTimeout, x => $"{x:0.0} s"));
        bool hasKey = isCustom ? S.customBaseURL.Trim().Length > 0 : p.getKey().Length > 0;
        var st = AiStatus(p.id, hasKey);
        var title = p.id switch { "openAI" => "OpenAI", "anthropic" => "Anthropic Claude", _ => "API tuỳ chỉnh" };
        var glyph = p.id switch { "openAI" => "", "anthropic" => "", _ => "" };
        return Ui.Block(title, glyph, st.uses ?? (isCustom ? "OpenRouter, Groq, Ollama, LM Studio…" : "Trả phí"),
            new UIElement?[] { Ui.Chip(isCustom && !hasKey ? "Chưa có địa chỉ" : st.text, st.tone) }, rows.ToArray());
    }

    // MARK: Capture & OCR

    UIElement Capture()
    {
        var ocrState = WinOcr.Available ? Ui.Caption("Windows OCR (tiếng Anh): sẵn sàng", Brushes.Green) : Ui.Caption(WinOcr.LastError ?? "Windows OCR không dùng được", Ui.Danger);
        return Ui.V(14,
            Ui.Section("Capture",
                Ui.Picker("Tần suất quét", new[] { (2, "2 fps"), (4, "4 fps"), (8, "8 fps") }, () => S.fps, v => S.fps = v),
                Ui.Picker("Độ phân giải quét phụ đề", new[] { (0.5, "0.5×"), (0.75, "0.75×"), (1.0, "1× (giữ nguyên)"), (1.5, "1.5×"), (2.0, "2× (chữ nhỏ)") }, () => S.captureScale, v => S.captureScale = v),
                Ui.Picker("Độ phân giải Dịch màn hình", new[] { (1.0, "1× (giữ nguyên)"), (1.5, "1.5×"), (2.0, "2× (chữ nhỏ)") }, () => S.screenCaptureScale, v => S.screenCaptureScale = v),
                Ui.Caption("Phụ đề chữ to nên 0.5–0.75× vẫn đọc được và OCR nhanh hơn. Dịch màn hình đọc chữ menu, nhật ký nhỏ hơn nên để 1.5–2×. Đổi độ phân giải phụ đề có hiệu lực từ lần Bắt đầu sau."),
                Ui.Slider("Chờ ổn định sau khi đổi", 0, 1000, 50, () => S.stableDelayMs, v => S.stableDelayMs = v, v => $"{(int)v} ms"),
                Ui.Slider("Ngưỡng phát hiện thay đổi", 1, 20, 1, () => S.diffThreshold, v => S.diffThreshold = v, v => $"{(int)v}")),
            Ui.Section("PS5 Remote Play",
                Ui.Toggle("Tự kết nối lại khi mất kết nối PS5", () => S.ps5AutoReconnect, v => S.ps5AutoReconnect = v),
                Ui.Stepper(() => $"Số lần thử tối đa: {S.ps5ReconnectAttempts}", 1, 30, 1, () => S.ps5ReconnectAttempts, v => S.ps5ReconnectAttempts = v),
                Ui.Caption("Tắt thì khi mất kết nối app dừng dịch và quay về màn hình bắt đầu để bạn kết nối lại.")),
            Ui.Section("OCR",
                ocrState,
                Ui.Slider("Bỏ qua chữ nhỏ hơn (tỉ lệ chiều cao vùng)", 0, 0.3, 0.01, () => S.minTextHeight, v => S.minTextHeight = v, v => $"{v:0.00}"),
                Ui.Slider("Coi là trùng nếu giống ≥", 0.5, 1, 0.05, () => S.dedupSimilarity, v => S.dedupSimilarity = v, v => $"{(int)Math.Round(v * 100)}%"),
                Ui.Toggle("Soi thông minh: nghỉ sau mỗi câu phụ đề (câu dài nghỉ tối đa 1,2 s, câu ngắn ~0,3 s) để giảm OCR", () => S.adaptiveCapture, v => S.adaptiveCapture = v),
                Ui.Toggle("Bỏ qua câu chỉ có từ cảm thán (hmm, haha, huh, ugh…) và mô tả âm thanh như [grunts]", () => S.skipInterjections, v => S.skipInterjections = v),
                Ui.Toggle("Không dịch, không đọc câu quá đơn giản (tối đa 5 từ, toàn từ cơ bản như yes, no, okay, let's go hoặc tên nhân vật); vẫn ghi câu gốc vào nhật ký", () => S.skipSimpleLines, v => S.skipSimpleLines = v),
                Ui.Toggle("Chỉ nhận chữ nằm giữa khung phụ đề – bỏ chữ ở mép như nút Quick Save, Back (tắt nếu game canh phụ đề sang trái)", () => S.centerOnlySubtitles, v => S.centerOnlySubtitles = v),
                Ui.Toggle("Bỏ qua chữ giao diện (menu, cài đặt, danh sách) – chỉ dịch khi trông giống phụ đề", () => S.skipUIText, v => S.skipUIText = v),
                Ui.Caption("Nhận biết qua nhiều từ Viết Hoa, nhiều cột/hàng, cỡ chữ lẫn, nhiều số. Tắt nếu game có phụ đề kiểu lạ bị bỏ qua nhầm (xem log “UI[...] bỏ qua”). Có hiệu lực khi Bắt đầu lại.")),
            Ui.Caption("Thay đổi capture có hiệu lực khi Bắt đầu lại. Game có hiệu ứng chữ chạy: tăng “Chờ ổn định”."));
    }

    // MARK: Voice

    UIElement Voice()
    {
        var catalog = VoiceCatalog.shared;
        var v = Ui.V(14);
        var top = new List<UIElement?>
        {
            Ui.Toggle("Đọc bản dịch", () => S.voiceEnabled, x => S.voiceEnabled = x),
            Ui.Picker("Engine", Enum.GetValues<VoiceEngine>().Select(e => (e, Labels.Of(e))), () => S.voiceEngine, x => { S.voiceEngine = x; Reload(); }, 300),
        };
        if (S.voiceEngine == VoiceEngine.edge)
        {
            var edgeVoices = EdgeTTS.VoicesFor(S.targetLanguage);
            top.Add(Ui.Picker($"Giọng Edge ({S.target.name})", new[] { ("", $"Mặc định ({edgeVoices.FirstOrDefault()?.name ?? "—"})") }.Concat(edgeVoices.Select(x => (x.id, x.name))), () => S.edgeVoice, x => S.edgeVoice = x));
            top.Add(Ui.Slider("Tốc độ giọng Edge", -20, 100, 5, () => S.edgeRatePercent, x => S.edgeRatePercent = x, x => x >= 0 ? $"+{(int)x}%" : $"{(int)x}%"));
            top.Add(Ui.Caption("Giọng neural của Microsoft (có giọng nam), miễn phí, cần mạng. Lưu ý: máy chủ miễn phí mất 3–5 giây mới bắt đầu trả âm thanh cho mỗi câu mới, nên KHÔNG hợp với phụ đề thời gian thực. Lỗi 3 lần liên tiếp thì app tự dùng giọng Windows.", Ui.Orange));
        }
        v.Children.Add(Ui.Section("Voice", top.ToArray()));

        if (S.voiceEngine == VoiceEngine.local)
        {
            var rows = new List<UIElement?>();
            if (!SherpaNative.Available) rows.Add(Ui.Caption("Thiếu thư viện sherpa-onnx (sherpa-onnx-c-api.dll). Chạy windows/Scripts/fetch-sherpa.ps1 rồi build lại.", Ui.Danger));
            foreach (var lv in VoiceCatalog.voices)
            {
                bool selected = S.localVoiceID == lv.id, installed = catalog.installed.Contains(lv.id);
                var radio = Ui.Icon(selected ? "" : "", 14, selected ? Ui.AccentStart : Ui.Secondary);
                var name = Ui.V(1, Ui.Text(lv.name), lv.note.Length > 0 ? Ui.Caption(lv.note) : null);
                var right = new List<UIElement>();
                if (catalog.downloading.TryGetValue(lv.id, out var p))
                {
                    right.Add(new ProgressBar { Value = p * 100, Width = 90, Height = 8 });
                    right.Add(Ui.Caption($"{(int)(p * 100)}%"));
                }
                else if (installed)
                {
                    var id = lv.id;
                    right.Add(Ui.Btn("Nghe thử", () => PreviewLocal(id)));
                    right.Add(Ui.Btn("Xoá", () => { catalog.Delete(id); Reload(); }));
                }
                else
                {
                    if (catalog.errors.TryGetValue(lv.id, out var e)) right.Add(Ui.Caption(e, Ui.Danger).Also(t => { t.MaxWidth = 200; t.TextTrimming = TextTrimming.CharacterEllipsis; t.TextWrapping = TextWrapping.NoWrap; }));
                    var id = lv.id;
                    right.Add(Ui.Btn($"Tải ({lv.sizeMB} MB)", () => { catalog.Download(id); S.localVoiceID = id; Reload(); }));
                }
                var row = Ui.Row(Ui.H(8, radio, name), right.ToArray());
                var vid = lv.id;
                radio.Cursor = Cursors.Hand;
                radio.MouseLeftButtonUp += (_, _) => { if (catalog.installed.Contains(vid)) { S.localVoiceID = vid; Reload(); } };
                rows.Add(row);
            }
            rows.Add(Ui.Slider("Tốc độ", 0.8, 1.8, 0.05, () => S.localSpeed, x => S.localSpeed = x, x => $"×{x:0.00}"));
            rows.Add(Ui.Caption("Model neural chạy ngay trên máy, không cần mạng sau khi tải. Mỗi câu mất khoảng 0,1–0,3 s để tạo tiếng. Lần tải đầu kèm 18 MB dữ liệu phiên âm dùng chung. Chỉ có tiếng Việt; ngôn ngữ đích khác sẽ dùng giọng Windows."));
            v.Children.Add(Ui.Section("Giọng AI offline (tiếng Việt)", rows.ToArray()));
        }

        var winVoices = WindowsTTS.VoicesFor(S.target.bcp47);
        var winRows = new List<UIElement?>
        {
            Ui.Picker($"Giọng ({S.target.name})", new[] { ("", $"Mặc định ({winVoices.FirstOrDefault()?.name ?? "giọng hệ thống"})") }.Concat(winVoices.Select(x => (x.id, $"{x.name} – {x.gender}"))), () => S.voiceIdentifier, x => S.voiceIdentifier = x, 320),
        };
        if (winVoices.Count == 0)
            winRows.Add(Ui.Caption("Chưa có giọng Windows cho ngôn ngữ này. Cài trong Settings → Time & language → Speech → Add voices (ví dụ Vietnamese).", Ui.Orange));
        winRows.Add(Ui.Slider("Tốc độ", 0.6, 2.5, 0.05, () => S.voiceRate, x => S.voiceRate = x, x => $"×{x:0.00}"));
        winRows.Add(Ui.Toggle("Ngắt câu đang đọc khi có câu mới (tắt = đọc hết từng câu theo thứ tự)", () => S.interruptSpeech, x => { S.interruptSpeech = x; Reload(); }));
        if (!S.interruptSpeech)
        {
            winRows.Add(Ui.Slider("Khi còn câu đang đọc dở, câu kế tiếp nhanh thêm", 0, 50, 5, () => S.catchUpPercent, x => S.catchUpPercent = x, x => $"+{(int)x}%"));
            if (S.queueMode != QueueMode.fifo)
                winRows.Add(Ui.Caption("Hàng đợi phụ đề đang ở chế độ “chỉ giữ câu mới nhất” nên câu chưa kịp dịch vẫn có thể bị bỏ. Đổi sang “Hội thoại (đọc lần lượt)” ở Cài đặt → Dịch.", Ui.Orange));
        }
        winRows.Add(Ui.Toggle("Không đọc tên người nói ở đầu câu (\"Kratos: …\")", () => S.voiceSkipSpeaker, x => S.voiceSkipSpeaker = x));
        winRows.Add(Ui.Toggle("Tự đọc nhanh hơn với câu dài (+10 % / +20 % / +30 %)", () => S.voiceAdaptiveRate, x => S.voiceAdaptiveRate = x));
        winRows.Add(Ui.Toggle("Phát giọng đọc trên TV / điện thoại thay vì loa máy tính", () => S.voiceOnRemote, x => S.voiceOnRemote = x));
        winRows.Add(Ui.Caption("Gửi âm thanh (đúng giọng đang chọn) tới app Subtitle TV hoặc trang web đang mở qua máy chủ web. Không có máy nào đang xem thì đọc ra loa máy tính như cũ."));
        winRows.Add(Ui.Btn("Nghe thử", () =>
        {
            var p = Pipeline.shared;
            p.ApplyVoiceSettings();
            p.speaker.engine = S.voiceEngine;
            p.speaker.ResetEdgeFailures();
            p.speaker.Speak(S.targetLanguage == "vi" ? "Xin chào, đây là giọng đọc bản dịch của Subly." : "Hello, this is the translation voice.");
        }).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));
        winRows.Add(Ui.Caption("Giọng hay hơn: Settings → Time & language → Speech → Manage voices → thêm giọng (Natural voices nếu có)."));
        v.Children.Add(Ui.Section("Giọng Windows (offline)", winRows.ToArray()));
        return v;
    }

    void PreviewLocal(string id)
    {
        S.localVoiceID = id;
        var p = Pipeline.shared;
        p.ApplyVoiceSettings();
        p.speaker.engine = VoiceEngine.local;
        p.speaker.Speak("Xin chào, đây là giọng đọc bản dịch của Subly.");
    }

    // MARK: Overlay

    UIElement Overlay() => Ui.Section("Overlay phụ đề",
        Ui.Toggle("Hiện bản dịch trên màn hình", () => S.overlayEnabled, v => S.overlayEnabled = v),
        Ui.Picker("Vị trí", Enum.GetValues<OverlayPosition>().Select(p => (p, Labels.Of(p))), () => S.overlayPosition, v => S.overlayPosition = v),
        Ui.Toggle("Hiện cả câu gốc", () => S.overlayShowSource, v => S.overlayShowSource = v),
        Ui.Slider("Cỡ chữ", 14, 40, 1, () => S.overlayFontSize, v => S.overlayFontSize = v, v => $"{(int)v}"),
        Ui.Slider("Độ mờ nền", 0.2, 1, 0.05, () => S.overlayOpacity, v => S.overlayOpacity = v, v => $"{(int)Math.Round(v * 100)}%"),
        Ui.Slider("Bề rộng tối đa", 400, 1600, 50, () => S.overlayMaxWidth, v => S.overlayMaxWidth = v, v => $"{(int)v} px"),
        Ui.Slider("Tự ẩn sau", 0, 15, 1, () => S.overlayHideAfter, v => S.overlayHideAfter = v, v => v == 0 ? "không" : $"{(int)v}s"),
        Ui.Btn("Xem thử overlay", Pipeline.shared.PreviewOverlay).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));

    // MARK: Thuật ngữ

    UIElement Glossary()
    {
        var editor = new GlossaryEditor(() => S.globalGlossary, v => S.globalGlossary = v, "thuat-ngu-chung.csv",
            "Thuật ngữ chung, dùng cho mọi game. Thuật ngữ riêng của từng game nằm ở tab Thuật ngữ trong cửa sổ chính và được ưu tiên khi trùng. Để trống bản dịch = giữ nguyên.");
        saveGlossary = editor.Save;
        return editor;
    }

    // MARK: Game

    UIElement Profiles()
    {
        var nav = AppNav.shared;
        // Đang ở màn hình chơi thì không đổi game ở đây (bấm Đổi game ở cửa sổ chính).
        bool locked = nav.screen == AppNav.Screen.main;
        var list = new ListBox { MinHeight = 260, Background = Brushes.White, IsEnabled = !locked };
        foreach (var p in S.profiles)
        {
            var item = new ListBoxItem
            {
                Tag = p.id, Padding = new Thickness(8, 6, 8, 6),
                Content = Ui.Row(Ui.H(8, Ui.Icon(p.source == ProfileSource.ps5 ? "" : "", 13), Ui.Text(p.name, wrap: false)),
                                 Ui.Caption($"{Labels.Of(p.source)} · {p.glossary.Count} thuật ngữ · {p.speakers.Count} nhân vật")),
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            list.Items.Add(item);
            if (p.id == S.activeProfile.id) list.SelectedItem = item;
        }
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is ListBoxItem it && it.Tag is Guid id && id != S.activeProfileID && S.profiles.FirstOrDefault(p => p.id == id) is Profile p)
                nav.SwitchProfile(p);
        };
        var buttons = Ui.H(8,
            Ui.Btn("Game mới…", () => { App.ShowMain(); nav.ShowNewProfile(); }).Also(b => b.IsEnabled = !locked),
            Ui.Btn("Đổi tên", () => { nav.RenameProfile(S.activeProfile, this); Reload(); }),
            Ui.Btn("Nhân bản", () => { nav.DuplicateProfile(S.activeProfile); Reload(); }).Also(b => b.IsEnabled = !locked),
            Ui.Btn("Xoá", () => { nav.DeleteProfile(S.activeProfile); Reload(); }).Also(b => b.IsEnabled = !locked && S.profiles.Count > 1));
        var note = locked ? $"Đang chơi “{S.activeProfile.name}”. Muốn chọn game khác: bấm Đổi game ở cửa sổ chính."
                          : "Mỗi game có nguồn hình, vùng phụ đề, thuật ngữ và tên nhân vật riêng. Chọn game để chơi ở màn hình Bắt đầu.";
        return Ui.V(8, Ui.Caption(note), list, buttons);
    }

    // MARK: Phím tắt

    UIElement Hotkeys()
    {
        UIElement Rec(string label, Func<KeyCombo> get, Action<KeyCombo> set) => Ui.Row(Ui.Text(label), new KeyRecorder(get, set));
        return Ui.V(8,
            Ui.Section("Phím tắt toàn cục",
                Ui.Toggle("Bật phím tắt toàn cục", () => S.hotkeysEnabled, v => { S.hotkeysEnabled = v; HotkeyManager.shared.Apply(); }),
                Rec("Bắt đầu / Dừng", () => S.hotkeyToggle, v => S.hotkeyToggle = v),
                Rec("Dịch màn hình (thủ công)", () => S.hotkeyAnalyze, v => S.hotkeyAnalyze = v),
                Rec("Bật / tắt voice", () => S.hotkeyVoice, v => S.hotkeyVoice = v),
                Rec("Bật / tắt overlay", () => S.hotkeyOverlay, v => S.hotkeyOverlay = v)),
            Ui.Caption("Bấm vào ô rồi nhấn tổ hợp mới (cần Ctrl, Alt hoặc Win). Hoạt động cả khi game đang chạy toàn màn hình. Nếu một phím không hoạt động, có thể app khác đã dùng tổ hợp đó."));
    }

    // MARK: Điện thoại / Web

    UIElement Web()
    {
        var server = WebServer.shared;
        var status = server.status.kind switch
        {
            WebServer.StatusKind.off => Ui.Text("đang tắt", color: Ui.Secondary),
            WebServer.StatusKind.starting => Ui.Text("đang mở…", color: Ui.Secondary),
            WebServer.StatusKind.running => Ui.Text($"đang chạy · {server.clientCount} máy đang xem", color: Brushes.Green),
            _ => Ui.Text(server.status.message, color: Ui.Danger),
        };
        var port = new TextBox { Text = S.webServerPort.ToString(), Width = 90 };
        void ApplyPort() { if (int.TryParse(port.Text, out var p) && p > 0 && p <= 65535 && p != S.webServerPort) { S.webServerPort = p; server.Apply(); Reload(); } }
        port.KeyDown += (_, e) => { if (e.Key == Key.Enter) ApplyPort(); };
        port.LostFocus += (_, _) => ApplyPort();
        var v = Ui.V(14,
            Ui.Section("Xem trên điện thoại / máy tính bảng",
                Ui.Toggle("Cho điện thoại / máy tính bảng trong cùng mạng Wi‑Fi xem phụ đề", () => S.webServerEnabled, x => { S.webServerEnabled = x; server.Apply(); Reload(); }),
                Ui.H(8, Ui.Text("Cổng"), port),
                Ui.H(6, Ui.Text("Trạng thái:"), status),
                Ui.Caption("Trang web có ba phần: phụ đề thời gian thực, nhật ký phụ đề và nút Dịch toàn màn hình. Chỉ máy trong mạng nội bộ mở được; không có mật khẩu, nên tắt khi dùng Wi‑Fi công cộng. Lần đầu Windows có thể hỏi cho phép qua tường lửa: chọn mạng Private.")));
        if (server.status.kind == WebServer.StatusKind.running)
        {
            var urls = WebServer.Urls(server.status.port);
            var first = urls.FirstOrDefault();
            if (first != null && !first.Contains(Environment.MachineName.ToLowerInvariant()))
            {
                var qr = new Image { Source = Qr(first), Width = 150, Height = 150 };
                RenderOptions.SetBitmapScalingMode(qr, BitmapScalingMode.NearestNeighbor);
                var addrs = Ui.V(6, Ui.Text("Quét mã bằng Camera của điện thoại, hoặc gõ một trong các địa chỉ:"));
                foreach (var u in urls) addrs.Children.Add(new TextBox { Text = u, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, FontFamily = new FontFamily("Consolas") });
                addrs.Children.Add(Ui.Caption("iPhone/Safari: Chia sẻ → Thêm vào MH chính để mở toàn màn hình như một app. Android/Chrome: menu ⋮ → Thêm vào màn hình chính."));
                var row = Ui.H(16, new Border { Child = qr, Padding = new Thickness(8), Background = Brushes.White, CornerRadius = new CornerRadius(8) }, addrs.Also(a => a.MaxWidth = 440));
                row.Children.OfType<FrameworkElement>().ToList().ForEach(c => c.VerticalAlignment = VerticalAlignment.Top);
                v.Children.Add(Ui.Section("Mở trên điện thoại", row));
            }
            else v.Children.Add(Ui.Section("Mở trên điện thoại", Ui.Text("Máy tính chưa nối mạng nội bộ nào.", color: Ui.Orange)));
        }
        return v;
    }

    // MARK: Sao lưu

    string backupUser = "";

    /// Cài đặt → Sao lưu: đăng nhập tài khoản, sao lưu dữ liệu máy này, khôi phục từ bản của máy bất kỳ.
    UIElement Backup()
    {
        var v = Ui.V(14);
        if (!BackupClient.Available)
        {
            v.Children.Add(Ui.Section("Sao lưu", Ui.Text("Bản app này không có server sao lưu.", color: Ui.Secondary)));
            return v;
        }
        var busy = BackupModel.busy;
        UIElement? busyRow = busy == null ? null : Ui.H(8,
            BackupModel.progress is double p ? new ProgressBar { Value = p, Maximum = 1, Width = 140, Height = 6 } : new ProgressBar { IsIndeterminate = true, Width = 80, Height = 6 },
            Ui.Text(busy, color: Ui.Secondary, wrap: false));
        if (!BackupModel.LoggedIn)
        {
            var user = new TextBox { Text = backupUser, Width = 260 };
            var pass = new PasswordBox { Width = 260 };
            void DoLogin()
            {
                backupUser = user.Text.Trim();
                if (backupUser.Length == 0 || pass.Password.Length == 0 || BackupModel.busy != null) return;
                _ = BackupModel.Login(backupUser, pass.Password);
            }
            pass.KeyDown += (_, e) => { if (e.Key == Key.Enter) DoLogin(); };
            var login = Ui.Btn("Đăng nhập", DoLogin, primary: true);
            login.IsEnabled = busy == null;
            v.Children.Add(Ui.Section("Tài khoản sao lưu",
                Ui.H(8, Ui.Text("Tên đăng nhập").Also(t => t.Width = 110), user),
                Ui.H(8, Ui.Text("Mật khẩu").Also(t => t.Width = 110), pass),
                Ui.H(10, login, busyRow),
                Ui.Caption("Sao lưu toàn bộ dữ liệu (cài đặt, game, thuật ngữ, nhân vật, phụ đề đã dịch, cốt truyện, ảnh dịch màn hình, API key, PS5) lên server để đổi máy không phải cài lại từ đầu. Tài khoản do admin cấp."),
                Ui.SupportText(11.5)));
        }
        else
        {
            var mine = BackupModel.backups.FirstOrDefault(b => b.machine == BackupModel.ThisMachine);
            var backupBtn = Ui.Btn(Ui.IconLabel("", "Sao lưu máy này lên server"), () => _ = BackupModel.BackupNow(), primary: true);
            backupBtn.IsEnabled = busy == null;
            var logout = Ui.Btn("Đăng xuất", () => _ = BackupModel.Logout());
            logout.IsEnabled = busy == null;
            v.Children.Add(Ui.Section("Tài khoản",
                Ui.Row(Ui.H(8, Ui.Icon("", 15), Ui.Text(S.accountUser, bold: true)), logout),
                Ui.H(10, backupBtn, busyRow),
                Ui.Caption(mine != null ? $"Lần sao lưu cuối của máy này: {mine.Date:dd/MM/yyyy HH:mm} · {BackupModel.Size(mine.size)}"
                    : BackupModel.loaded ? "Máy này chưa sao lưu lần nào." : ""),
                Ui.Caption("Mỗi máy giữ một bản mới nhất trên server, sao lưu lại sẽ ghi đè. Giọng đọc AI đã tải không nằm trong bản sao lưu (tải lại ở Cài đặt → Voice).")));

            var list = Ui.V(10);
            if (BackupModel.backups.Count == 0)
                list.Children.Add(Ui.Text(BackupModel.loaded ? "Chưa có bản sao lưu nào." : "Đang tải danh sách…", color: Ui.Secondary));
            foreach (var b in BackupModel.backups)
            {
                var title = Ui.H(6, Ui.Text(b.name.Length > 0 ? b.name : "(không tên)", bold: true, wrap: false),
                    b.machine == BackupModel.ThisMachine ? Ui.Chip("máy này", Ui.Tone.ok) : null);
                var info = Ui.V(2, title, Ui.Caption($"{b.PlatformLabel} · IP {b.ip} · {b.Date:dd/MM/yyyy HH:mm} · {BackupModel.Size(b.size)}"));
                var restore = Ui.Btn("Khôi phục", () => ConfirmRestore(b));
                restore.IsEnabled = busy == null;
                var del = Ui.InlineIconBtn("", () =>
                {
                    if (Ui.Confirm($"Xoá bản sao lưu của {b.name} khỏi server? Dữ liệu trên các máy không bị ảnh hưởng.", "Xoá bản sao lưu")) _ = BackupModel.Delete(b);
                }, "Xoá bản sao lưu này trên server");
                del.IsEnabled = busy == null;
                list.Children.Add(Ui.Row(Ui.H(10, Ui.Icon(b.platform == "win" ? "" : "", 20, Ui.Secondary), info), restore, del));
            }
            var refresh = Ui.LinkBtn("Tải lại danh sách", () => _ = BackupModel.Refresh());
            v.Children.Add(Ui.Section("Bản sao lưu trên server", list, refresh,
                Ui.Caption("Khôi phục sẽ thay toàn bộ dữ liệu trên máy này bằng bản đã chọn (có thể là bản của máy khác, kể cả Mac) rồi khởi động lại app. Dữ liệu cũ được cất ở thư mục before-restore.")));
            if (!BackupModel.loaded && busy == null) Dispatcher.BeginInvoke(() => _ = BackupModel.Refresh());
        }
        if (BackupModel.message is string msg)
            v.Children.Add(Ui.Text(msg, color: BackupModel.isError ? Ui.Danger : Brushes.Green));
        return v;
    }

    void ConfirmRestore(BackupInfo b)
    {
        var text = $"Toàn bộ dữ liệu trên máy này sẽ bị thay bằng bản sao lưu của {b.name} ({b.PlatformLabel}, {b.Date:dd/MM/yyyy HH:mm}). App sẽ khởi động lại.";
        if (b.platform != "win") text += "\n\nBản này từ Mac: phím tắt và giọng đọc của máy này được giữ nguyên, các khung chụp màn hình (ngoài PS5) cần vẽ lại.";
        if (Ui.Confirm(text, $"Khôi phục từ {b.name}?")) _ = BackupModel.Restore(b, App.Args);
    }

    static BitmapSource Qr(string text)
    {
        using var gen = new QRCoder.QRCodeGenerator();
        using var data = gen.CreateQrCode(text, QRCoder.QRCodeGenerator.ECCLevel.M);
        var png = new QRCoder.PngByteQRCode(data).GetGraphic(8);
        var bi = new BitmapImage();
        bi.BeginInit();
        bi.StreamSource = new MemoryStream(png);
        bi.CacheOption = BitmapCacheOption.OnLoad;
        bi.EndInit();
        bi.Freeze();
        return bi;
    }
}
