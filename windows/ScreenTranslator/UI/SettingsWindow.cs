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

/// Cửa sổ Cài đặt: 9 mục ở thanh bên (Dịch, AI, Capture & OCR, Voice, Overlay, Thuật ngữ chung, Game, Phím tắt, Điện thoại / Web).
public sealed class SettingsWindow : Window
{
    readonly ListBox sidebar = new() { Width = 200, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(6) };
    readonly ContentControl page = new();
    static readonly (string key, string title, string glyph)[] tabs =
    {
        ("translate", "Dịch", ""), ("ai", "AI", "\uE99A"), ("capture", "Capture & OCR", ""), ("voice", "Voice", ""), ("overlay", "Overlay", ""),
        ("glossary", "Thuật ngữ chung", ""), ("profile", "Game", ""), ("hotkeys", "Phím tắt", ""), ("web", "Điện thoại / Web", ""),
    };
    AppSettings S => AppSettings.shared;

    public SettingsWindow()
    {
        Title = "Cài đặt";
        Width = 860; Height = 640; MinWidth = 760; MinHeight = 560;
        Background = Ui.Res("WindowBg");
        Icon = new BitmapImage(new Uri("pack://application:,,,/Resources/AppIcon.ico"));
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
        Closing += (_, _) => saveGlossary?.Invoke();
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
            "glossary" => Glossary(), "profile" => Profiles(), "hotkeys" => Hotkeys(), _ => Web(),
        };
        if (body is FrameworkElement fe) fe.Margin = new Thickness(20, 16, 20, 16);
        page.Content = key == "glossary" ? body : Ui.Scroll(body);
    }

    void Reload() => Dispatcher.BeginInvoke(ShowPage);

    // MARK: Dịch

    UIElement Translate()
    {
        // Dưới mỗi ô chọn AI: chọn model riêng cho việc đó (mặc định = model ở mục AI), hoặc cảnh báo chưa cài đặt.
        (UIElement row, Action update) ModelRow(AITask task, Func<string> engine, Func<string> fallback)
        {
            var box = new ComboBox { MinWidth = 280 };
            var text = Ui.Caption("");
            var panel = Ui.V(6, Ui.H(8, Ui.Text("Model"), box), Ui.Row(text, Ui.Btn("Cài đặt AI…", () => Select("ai"))));
            bool filling = false;
            void Update()
            {
                var id = engine();
                var info = CloudInfo(id);
                panel.Visibility = info == null ? Visibility.Collapsed : Visibility.Visible;
                if (info == null) return;
                var current = S.TaskModel(task, id) ?? "";
                var models = (S.aiModelLists.TryGetValue(id, out var saved) && saved.Count > 0 ? (IEnumerable<string>)saved : SuggestedModels(id)).ToList();
                if (current.Length > 0 && !models.Contains(current)) models.Add(current);
                var def = S.DefaultModel(id);
                filling = true;
                box.Items.Clear();
                box.Items.Add(new ComboBoxItem { Content = $"Mặc định ({(def.Length == 0 ? "chưa chọn" : def)})", Tag = "" });
                foreach (var name in models) box.Items.Add(new ComboBoxItem { Content = name, Tag = name });
                box.SelectedIndex = current.Length == 0 ? 0 : models.IndexOf(current) + 1;
                filling = false;
                text.Text = info.ready ? "Thiếu model cần dùng? Bấm Tải model ở mục AI." : $"Chưa cài đặt {info.name} {fallback()}";
                text.Foreground = info.ready ? Ui.Secondary : Ui.Orange;
            }
            box.SelectionChanged += (_, _) =>
            {
                if (filling || box.SelectedItem is not ComboBoxItem item || item.Tag is not string chosen) return;
                var all = S.taskModels;
                var key = $"{task}.{engine()}";
                if (chosen.Length == 0) all.Remove(key); else all[key] = chosen;
                S.taskModels = all;
            };
            Update();
            return (panel, Update);
        }
        var (subNote, updateSub) = ModelRow(AITask.subtitle, () => S.translationEngine == TranslationEngine.auto ? "gemini" : S.translationEngine.ToString(),
            () => "nên sẽ dùng Google Translate.");
        var (screenNote, updateScreen) = ModelRow(AITask.screen, () => S.effectiveScreenEngine.ToString(), () => "nên sẽ dùng Google Translate.");
        var (summaryNote, updateSummary) = ModelRow(AITask.summary, () => S.effectiveSummaryEngine.ToString(),
            () => S.effectiveSummaryEngine == SummaryEngine.gemini
                ? "nên Tóm tắt sẽ thử AI khác đã có key, Cốt truyện không chạy được."
                : "nên sẽ dùng Gemini.");
        void UpdateNotes() { updateSub(); updateScreen(); updateSummary(); }

        // Mục Tài khoản: email gửi lên server để chủ app nhận diện/duyệt máy (chỉ bản phát hành có kiểm tra máy).
        UIElement? account = null;
        if (RuntimeConfig.Enabled)
        {
            var emailBox = new TextBox { Text = S.userEmail, MinWidth = 320 };
            emailBox.LostFocus += (_, _) => { var t = emailBox.Text.Trim(); if (t != S.userEmail) S.userEmail = t; };
            account = Ui.Section("Tài khoản", Ui.V(3, Ui.Caption("Email"), emailBox));
        }

        return Ui.V(14,
            account,
            Ui.Section("Ngôn ngữ",
                Ui.Picker("Dịch sang", TargetLanguage.all.Select(l => (l.code, l.name)), () => S.targetLanguage, v => S.targetLanguage = v)),
            Ui.Section("Dịch phụ đề",
                Ui.Picker("AI", Enum.GetValues<TranslationEngine>().Select(e => (e, Labels.Of(e))), () => S.translationEngine, v => { S.translationEngine = v; UpdateNotes(); }, 420),
                subNote,
                Ui.Stepper(() => $"Ngữ cảnh: {S.contextPairs} câu trước", 0, 10, 1, () => S.contextPairs, v => S.contextPairs = v)),
            Ui.Section("Dịch màn hình (thủ công)",
                Ui.Picker("AI", Enum.GetValues<ScreenEngine>().Select(e => (e, Labels.Of(e))), () => S.screenEngine, v => { S.screenEngine = v; UpdateNotes(); }, 420),
                screenNote,
                Ui.Toggle("Đọc tóm tắt bằng giọng nói", () => S.analyzeSpeakSummary, v => S.analyzeSpeakSummary = v),
                Ui.Slider("Timeout", 5, 60, 5, () => S.analyzeTimeout, v => S.analyzeTimeout = v, v => $"{(int)v}s")),
            Ui.Section("Tóm tắt & cốt truyện (tab Nhật ký)",
                Ui.Picker("AI", Enum.GetValues<SummaryEngine>().Select(e => (e, Labels.Of(e))), () => S.summaryEngine, v => { S.summaryEngine = v; UpdateNotes(); }, 420),
                summaryNote,
                Ui.Toggle("Tự động viết cốt truyện game khi đang dịch", () => S.storyEnabled, v => S.storyEnabled = v),
                Ui.Stepper(() => $"Cập nhật mỗi {S.storyIntervalMin} phút (khi có đủ câu mới)", 5, 60, 5, () => S.storyIntervalMin, v => S.storyIntervalMin = v),
                Ui.Caption("Mỗi lần cập nhật tốn 1 request, dùng chung quota với dịch phụ đề. Xem ở Nhật ký → Cốt truyện.")),
            Ui.Section("Hàng đợi phụ đề",
                Ui.Picker("Chế độ", Enum.GetValues<QueueMode>().Select(q => (q, Labels.Of(q))), () => S.queueMode, v => S.queueMode = v)));
    }

    record CloudInfoRow(string name, string model, bool ready);
    /// Tên, model đang chọn và đã cài đặt chưa của một AI qua mạng (theo tên engine); null = Google Translate.
    CloudInfoRow? CloudInfo(string engine) => engine switch
    {
        "gemini" => new CloudInfoRow("Gemini", S.geminiModel, S.geminiAPIKeys.Count > 0),
        "openAI" => new CloudInfoRow("OpenAI", S.openAIModel, S.openAIKey.Length > 0),
        "anthropic" => new CloudInfoRow("Anthropic", S.anthropicModel, S.anthropicKey.Length > 0),
        "custom" => new CloudInfoRow("API tuỳ chỉnh", S.customModel, S.customReady),
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
        var stack = Ui.V(14, GeminiSection());
        foreach (var p in providers) stack.Children.Add(ProviderSection(p));
        return stack;
    }

    /// Gemini miễn phí: lưu nhiều key, app dùng xoay vòng để chia đều quota.
    UIElement GeminiSection()
    {
        var keys = S.geminiAPIKeys;
        var rows = new List<UIElement?>();
        async Task TestKey(string k, Button btn, TextBlock target)
        {
            btn.IsEnabled = false; btn.Content = "Đang test…"; target.Text = "";
            var (ok, msg) = await GeminiBackend.Test(k, S.geminiModel);
            target.Text = ok ? $"OK: {msg}" : $"Lỗi: {msg}";
            if (S.geminiAPIKeys.Contains(k)) geminiKeyResults[k] = target.Text;
            btn.IsEnabled = true; btn.Content = "Test key";
        }
        var savedTests = new List<Action>();
        foreach (var k in keys)
        {
            var key = k;
            var status = Ui.Caption(geminiKeyResults.TryGetValue(key, out var r) ? r : "");
            status.MaxWidth = 300; status.TextTrimming = TextTrimming.CharacterEllipsis; status.TextWrapping = TextWrapping.NoWrap;
            Button? testBtn = null;
            testBtn = Ui.Btn("Test key", async () => await TestKey(key, testBtn!, status));
            savedTests.Add(async () => await TestKey(key, testBtn!, status));
            var mask = Ui.Text(Mask(key), wrap: false);
            mask.FontFamily = new FontFamily("Consolas");
            rows.Add(Ui.Row(Ui.H(8, Ui.Icon("\uE8D7", 13, Ui.Secondary), mask, status),
                testBtn,
                Ui.Btn("Xoá key", () => { S.geminiAPIKeys = S.geminiAPIKeys.Where(x => x != key).ToList(); geminiKeyResults.Remove(key); Reload(); })));
        }

        var newKey = new PasswordBox { MinWidth = 320 };
        var result = Ui.Caption("");
        Button? testNew = null;
        testNew = Ui.Btn("Test key", async () =>
        {
            var k = newKey.Password.Trim();
            if (k.Length > 0) await TestKey(k, testNew!, result);
        });
        var buttons = Ui.H(8,
            Ui.Btn("Lưu key", () =>
            {
                var k = newKey.Password.Trim();
                if (k.Length == 0) return;
                if (S.geminiAPIKeys.Contains(k)) { result.Text = "Key này đã có trong danh sách"; return; }
                S.geminiAPIKeys = S.geminiAPIKeys.Append(k).ToList();
                Reload();
            }, primary: true),
            testNew);
        if (keys.Count > 1)
        {
            buttons.Children.Add(Ui.Btn("Test tất cả", () => { foreach (var t in savedTests) t(); }));
            buttons.Children.Add(Ui.Btn("Xoá tất cả", () =>
            {
                if (!Ui.Confirm($"Xoá cả {keys.Count} key Gemini đã lưu?")) return;
                S.geminiAPIKeys = new List<string>(); geminiKeyResults.Clear(); Reload();
            }));
        }
        rows.Add(Ui.V(3, Ui.Caption("Thêm API key (aistudio.google.com/apikey)"), newKey));
        rows.Add(buttons);
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
                result.Text = $"Có {list.Count} model dùng được";
            }
            catch (Exception e) { result.Text = $"Không tải được danh sách: {e.Message}"; }
            loadBtn.IsEnabled = true; loadBtn.Content = "Tải model";
        }, tip: "Lấy danh sách model thật mà key này dùng được");
        rows.Add(Ui.Row(Ui.H(8, Ui.Text("Model"), modelBox), loadBtn));
        rows.Add(Ui.Slider("Timeout phụ đề", 2, 10, 0.5, () => S.geminiTimeout, x => S.geminiTimeout = x, x => $"{x:0.0}s"));
        rows.Add(Ui.Caption(keys.Count > 1
            ? $"Đang có {keys.Count} key: mỗi request dùng key kế tiếp, key nào hết quota (429) thì nghỉ và các key còn lại chạy tiếp. Quota gộp khoảng {S.geminiRPM} request/phút, {S.geminiRPD} request/ngày."
            : "Thêm nhiều key (mỗi key từ một tài khoản Google) để app dùng xoay vòng: quota miễn phí được cộng lại và ít bị gián đoạn khi một key hết lượt."));
        return Ui.Section("Gemini (miễn phí, nhiều key dùng xoay vòng)", rows.ToArray());
    }

    /// Một nhà cung cấp trả phí: key (lưu / test / xoá), model (chọn hoặc tải danh sách), thời gian chờ.
    UIElement ProviderSection(AiProvider p)
    {
        bool isCustom = p.id == "custom";
        var rows = new List<UIElement?>();
        if (isCustom)
        {
            var url = new TextBox { Text = S.customBaseURL, MinWidth = 320 };
            url.LostFocus += (_, _) => { var t = url.Text.Trim(); if (t != S.customBaseURL) S.customBaseURL = t; };
            rows.Add(Ui.V(3, Ui.Caption("Địa chỉ API (ví dụ https://openrouter.ai/api/v1)"), url));
        }
        var key = new PasswordBox { Password = p.getKey(), MinWidth = 320 };
        var result = Ui.Caption("");
        // API tuỳ chỉnh có thể không cần key; hai hãng còn lại bắt buộc.
        bool CanCall(string k) => isCustom ? S.customBaseURL.Trim().Length > 0 : k.Length > 0;
        Button? testBtn = null, loadBtn = null;
        testBtn = Ui.Btn("Test key", async () =>
        {
            var k = key.Password.Trim();
            if (!CanCall(k)) { result.Text = isCustom ? "Chưa nhập địa chỉ API" : "Chưa nhập key"; return; }
            testBtn!.IsEnabled = false; testBtn.Content = "Đang test…"; result.Text = "";
            var (ok, msg) = await p.test(k);
            result.Text = ok ? $"OK: {msg}" : $"Lỗi: {msg}";
            testBtn.IsEnabled = true; testBtn.Content = "Test key";
        });
        rows.Add(Ui.V(3, Ui.Caption(p.keyHint), key));
        rows.Add(Ui.H(8,
            Ui.Btn("Lưu key", () => { p.setKey(key.Password.Trim()); result.Text = "Đã lưu"; }, primary: true),
            testBtn,
            Ui.Btn("Xoá key", () => { p.setKey(""); key.Password = ""; result.Text = "Đã xoá key"; })));
        rows.Add(result);

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
                result.Text = $"Có {list.Count} model dùng được";
            }
            catch (Exception e) { result.Text = $"Không tải được danh sách: {e.Message}"; }
            loadBtn.IsEnabled = true; loadBtn.Content = "Tải model";
        }, tip: "Lấy danh sách model thật mà key này dùng được");
        rows.Add(Ui.Row(Ui.H(8, Ui.Text("Model"), modelBox), loadBtn));
        rows.Add(Ui.Slider("Timeout phụ đề", 2, 15, 0.5, p.getTimeout, p.setTimeout, x => $"{x:0.0}s"));
        if (isCustom)
            rows.Add(Ui.Caption("Dùng cho máy chủ nói giao thức Chat Completions của OpenAI: OpenRouter, Groq, DeepSeek, hoặc model chạy trên máy như Ollama (http://localhost:11434/v1), LM Studio. Model: gõ tên vào ô hoặc bấm Tải model."));
        return Ui.Section(p.title, rows.ToArray());
    }

    // MARK: Capture & OCR

    UIElement Capture()
    {
        var ocrState = WinOcr.Available ? Ui.Caption("Windows OCR (tiếng Anh): sẵn sàng", Brushes.Green) : Ui.Caption(WinOcr.LastError ?? "Windows OCR không dùng được", Ui.Danger);
        return Ui.V(14,
            Ui.Section("Capture",
                Ui.Picker("Tần suất quét", new[] { (2, "2 fps"), (4, "4 fps"), (8, "8 fps") }, () => S.fps, v => S.fps = v),
                Ui.Picker("Phóng to ảnh cho OCR", new[] { (1.0, "1× (giữ nguyên)"), (1.5, "1.5×"), (2.0, "2× (chữ nhỏ)") }, () => S.captureScale, v => S.captureScale = v),
                Ui.Slider("Chờ ổn định sau khi đổi", 0, 1000, 50, () => S.stableDelayMs, v => S.stableDelayMs = v, v => $"{(int)v} ms"),
                Ui.Slider("Ngưỡng phát hiện thay đổi", 1, 20, 1, () => S.diffThreshold, v => S.diffThreshold = v, v => $"{(int)v}")),
            Ui.Section("OCR",
                ocrState,
                Ui.Slider("Bỏ qua chữ nhỏ hơn (tỉ lệ chiều cao vùng)", 0, 0.3, 0.01, () => S.minTextHeight, v => S.minTextHeight = v, v => $"{v:0.00}"),
                Ui.Slider("Coi là trùng nếu giống ≥", 0.5, 1, 0.05, () => S.dedupSimilarity, v => S.dedupSimilarity = v, v => $"{(int)Math.Round(v * 100)}%"),
                Ui.Toggle("Soi thông minh: nghỉ sau mỗi câu phụ đề (câu dài nghỉ tối đa 1,2 s, câu ngắn ~0,3 s) để giảm OCR", () => S.adaptiveCapture, v => S.adaptiveCapture = v),
                Ui.Toggle("Bỏ qua câu chỉ có từ cảm thán (hmm, haha, huh, ugh…) và mô tả âm thanh như [grunts]", () => S.skipInterjections, v => S.skipInterjections = v),
                Ui.Toggle("Không dịch, không đọc câu quá đơn giản (1–2 từ, hoặc tối đa 5 từ toàn từ cơ bản như yes, no, okay, let's go); vẫn ghi câu gốc vào nhật ký", () => S.skipSimpleLines, v => S.skipSimpleLines = v),
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
        var list = new ListBox { MinHeight = 260, Background = Brushes.White };
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
            if (p.id == S.activeProfileID) list.SelectedItem = item;
        }
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is ListBoxItem it && it.Tag is Guid id && id != S.activeProfileID && S.profiles.FirstOrDefault(p => p.id == id) is Profile p)
                AppNav.shared.SwitchProfile(p);
        };
        var buttons = Ui.H(8,
            Ui.Btn("Game mới…", () => { App.ShowMain(); AppNav.shared.ShowNewProfile(); }),
            Ui.Btn("Đổi tên", () =>
            {
                var p = S.activeProfile;
                if (Ui.Ask("Tên game", "Ví dụ: God of War Ragnarök", p.name, this) is string n) { p.name = n; S.activeProfile = p; Reload(); }
            }),
            Ui.Btn("Nhân bản", () =>
            {
                var p = S.activeProfile.Clone();
                p.id = Guid.NewGuid(); p.name += " (bản sao)";
                foreach (var r in p.regions) r.id = Guid.NewGuid();
                var ps = S.profiles; ps.Add(p); S.profiles = ps; S.activeProfileID = p.id;
                S.NotifyAll();
                Reload();
            }),
            Ui.Btn("Xoá", () =>
            {
                if (S.profiles.Count <= 1) return;
                var cur = S.activeProfile;
                if (!Ui.Confirm($"Xoá game “{cur.name}” (vùng, thuật ngữ, tên nhân vật)? Nhật ký vẫn giữ trong file.")) return;
                Pipeline.shared.Stop();
                var ps = S.profiles.Where(x => x.id != cur.id).ToList();
                S.profiles = ps;
                S.activeProfileID = ps.FirstOrDefault()?.id;
                S.NotifyAll();
                Reload();
            }).Also(b => b.IsEnabled = S.profiles.Count > 1));
        return Ui.V(8, Ui.Caption("Mỗi game có nguồn hình, vùng phụ đề, thuật ngữ và tên nhân vật riêng. Chọn một game để chuyển sang."), list, buttons);
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
