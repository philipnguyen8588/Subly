using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Worker cho một vùng phụ đề: capture → gate → chờ ổn định → OCR → dedup → báo về Pipeline.
public sealed class RegionWorker
{
    public readonly Region region;
    readonly IFrameCapture capture;
    readonly FrameGate gate;
    readonly WinOcr ocr = new();
    readonly SerialQueue ocrQueue;
    readonly SerialQueue gateQueue;
    bool ocrBusy;                   // chỉ đọc/ghi trên gateQueue
    DateTime ocrStartedAt;          // chỉ đọc/ghi trên gateQueue
    bool reportedHang;              // chỉ đọc/ghi trên gateQueue
    volatile bool stopped;
    bool restarting;                // chỉ đọc/ghi trên gateQueue
    string lastText = "";
    /// Các câu đã nhận còn đang được nhớ (để lọc trùng). `missingSince`: lần OCR đầu tiên không còn thấy câu này
    /// (null = vẫn đang trên màn hình). Màn hình đứng yên thì không OCR nên không ai đánh dấu → câu vẫn được nhớ.
    readonly List<(string text, DateTime? missingSince)> recent = new();
    readonly double dedup;
    readonly bool skipUI, skipInterjections, skipSimple;
    readonly double stableDelay;
    Frame? pendingPB;
    CancellationTokenSource? stableTimer;
    DateTime? changingSince;        // video chuyển động liên tục → OCR sau maxWait dù chưa ổn định
    readonly double maxWait;
    int frameCount, ocrRuns, heldFrames;
    // Chụp thông minh: sau khi nhận một câu, câu đó còn nằm trên màn hình một lúc (dài thì lâu, ngắn thì nhanh),
    // nên trong khoảng đó bỏ qua khung hình, không so sánh, không OCR.
    readonly bool adaptive;
    DateTime holdUntil = DateTime.MinValue;      // chỉ đọc/ghi trên gateQueue
    int dupStreak;
    DateTime lastLookAt = DateTime.MinValue;     // lần OCR trước xong lúc nào (chỉ dùng trên ocrQueue)
    /// Cỡ chữ phụ đề đã học trong phiên (chiều cao hàng, tỉ lệ theo vùng); hàng nhỏ hơn 60 % mức này bị bỏ. Chỉ dùng trên ocrQueue.
    double? subtitleHeight;
    Timer? statsTimer;
    public Action<string, Region>? onText;
    public Action<Region>? onEmpty;
    public Action<string, Region>? onUI;       // chữ giao diện (menu/cài đặt) → bỏ qua
    public Action<string, Region>? onSkipped;  // câu quá đơn giản → chỉ ghi nhật ký, không dịch, không đọc
    public Action? onOCR;
    public Action<bool>? onActiveChange;
    /// Luồng chụp chết và không khởi động lại được → thông báo lỗi; null = đã chạy lại bình thường.
    public Action<string?>? onCaptureError;
    /// Tên nhân vật đã học + game có hiện tên không (đọc trực tiếp từ settings mỗi lần OCR vì danh sách tăng dần).
    public Func<IList<string>> speakerNames = () => Array.Empty<string>();
    public Func<bool> usesNames = () => true;
    /// Game hiện tên ở dòng riêng phía trên câu thoại.
    public Func<bool> namesAbove = () => false;
    bool appActive = true;

    public RegionWorker(Region region, AppSettings settings)
    {
        this.region = region;
        ocrQueue = new SerialQueue($"ocr.{region.name}", ThreadPriority.AboveNormal);
        gateQueue = new SerialQueue($"gate.{region.name}", ThreadPriority.AboveNormal);
        capture = region.embedded ? new PS5FrameCapture(region, settings.fps)
                                  : new RegionCapture(region, settings.fps, settings.captureScale);
        gate = new FrameGate(settings.diffThreshold);
        ocr.minTextHeight = settings.minTextHeight;
        ocr.centerOnly = settings.centerOnlySubtitles;
        dedup = settings.dedupSimilarity;
        skipUI = settings.skipUIText;
        skipInterjections = settings.skipInterjections;
        skipSimple = settings.skipSimpleLines;
        adaptive = settings.adaptiveCapture;
        stableDelay = Math.Max(0, settings.stableDelayMs) / 1000;
        maxWait = Math.Max(stableDelay, 0.4);
        capture.onFrame = f => gateQueue.Async(() => Handle(f));
        capture.onStopped = e => gateQueue.Async(() => RestartCapture(e));
    }

    /// Chạy trên gateQueue. Luồng chụp bị dừng (cửa sổ đóng, màn hình ngủ, lỗi…) → thử mở lại vài lần.
    void RestartCapture(Exception error)
    {
        if (stopped || restarting) return;
        restarting = true;
        CancelStable(); pendingPB = null; changingSince = null;
        gate.Reset();
        _ = Task.Run(async () =>
        {
            var lastError = error.Message;
            for (int attempt = 1; attempt <= 5; attempt++)
            {
                await Task.Delay(attempt * 2000);
                if (stopped) return;
                try
                {
                    capture.Start();
                    // Người dùng bấm Dừng đúng lúc đang mở lại → đóng luồng vừa mở.
                    if (stopped) { capture.Stop(); return; }
                    Log.Info($"Vùng '{region.name}': đã mở lại luồng chụp (lần {attempt})");
                    gateQueue.Async(() => restarting = false);
                    onCaptureError?.Invoke(null);
                    return;
                }
                catch (Exception e)
                {
                    lastError = e.Message;
                    Log.Warn($"Vùng '{region.name}': mở lại luồng chụp lỗi (lần {attempt}/5): {lastError}");
                }
            }
            gateQueue.Async(() => restarting = false);
            onCaptureError?.Invoke($"Mất luồng chụp: {lastError}");
        });
    }

    public void Start()
    {
        capture.Start();
        statsTimer = new Timer(_ => gateQueue.Async(() =>
        {
            Log.Info($"STATS[{region.name}] frames/10s={frameCount} ocr/10s={ocrRuns} nghỉ/10s={heldFrames}");
            // Một lượt OCR (bình thường dưới 0,2 s) quá 10 s chưa xong: bộ nhận dạng chữ đã treo, chỉ mở lại app mới hết.
            if (ocrBusy && (DateTime.UtcNow - ocrStartedAt).TotalSeconds > 10 && !reportedHang)
            {
                reportedHang = true;
                Log.Error($"OCR[{region.name}] treo {(int)(DateTime.UtcNow - ocrStartedAt).TotalSeconds} s trong Windows OCR");
                onCaptureError?.Invoke("Nhận dạng chữ của Windows bị treo, phụ đề không được dịch. Thoát hẳn app rồi mở lại.");
            }
            frameCount = 0; ocrRuns = 0; heldFrames = 0;
        }), null, 10000, 10000);
    }

    public void Stop()
    {
        statsTimer?.Dispose(); statsTimer = null;
        stopped = true;
        capture.Stop();
        gateQueue.Async(() => { CancelStable(); pendingPB = null; });
        gateQueue.Dispose();
        ocrQueue.Dispose();
    }

    void CancelStable() { stableTimer?.Cancel(); stableTimer = null; }

    /// Chạy trên gateQueue. Frame đổi → đợi `stableDelay` không có thay đổi nữa rồi mới OCR.
    void Handle(Frame pb)
    {
        if (stopped) return;
        frameCount++;
        if (region.appBundleID is string bid && !region.followsWindow)
        {
            bool active = WindowFinder.FrontmostBundleID == bid;
            if (active != appActive)
            {
                appActive = active;
                Log.Info($"Vùng '{region.name}': {region.appName ?? bid} {(active ? "ở phía trước → tiếp tục" : "không ở phía trước → tạm dừng")}");
                if (!active) { CancelStable(); pendingPB = null; changingSince = null; gate.Reset(); }
                onActiveChange?.Invoke(active);
            }
            if (!active) return;
        }
        if (adaptive && DateTime.UtcNow < holdUntil) { heldFrames++; return; }      // đang trong khoảng nghỉ
        RegionPreviewProvider.shared.PushFrame(region.id, pb);
        var v = gate.Process(pb);
        switch (v.kind)
        {
            case FrameGate.Kind.first:
                RunOCR(pb);
                break;
            case FrameGate.Kind.changed:
                pendingPB = pb;
                var now = DateTime.UtcNow;
                changingSince ??= now;
                // Nền video đổi liên tục: không đợi mãi, OCR sau maxWait kể từ lần đổi đầu tiên.
                if ((now - changingSince.Value).TotalSeconds >= maxWait) { FlushPending(); return; }
                CancelStable();
                var cts = new CancellationTokenSource();
                stableTimer = cts;
                _ = Task.Delay(TimeSpan.FromSeconds(stableDelay), cts.Token).ContinueWith(t =>
                {
                    if (!t.IsCanceled) gateQueue.Async(() => { if (stableTimer == cts) FlushPending(); });
                }, TaskScheduler.Default);
                break;
            case FrameGate.Kind.unchanged:
                if (pendingPB != null) FlushPending();
                break;
        }
    }

    /// Chạy trên gateQueue: OCR frame đang chờ và reset trạng thái chờ.
    void FlushPending()
    {
        CancelStable();
        changingSince = null;
        var p = pendingPB;
        if (p == null) return;
        pendingPB = null;
        RunOCR(p);
    }

    /// Câu đã đọc mà không còn thấy trên màn hình quá chừng này thì quên (đủ để bỏ qua vài khung OCR đọc trượt
    /// hoặc phụ đề nháy tắt rồi hiện lại cùng một câu).
    const double forgetAfter = 4;

    /// Ước lượng một câu thoại nằm trên màn hình bao lâu (nói nhanh ~3,2 từ/giây, tối thiểu 1 s) và nghỉ nửa thời gian đó,
    /// TRỪ ĐI `lag` = khoảng app không nhìn màn hình trước khi thấy câu này (câu có thể đã hiện từ lúc đó).
    public static double HoldAfterSubtitle(string text, double lag = 0)
    {
        double words = text.Split(new[] { ' ', '\n' }, StringSplitOptions.RemoveEmptyEntries).Length;
        double display = Math.Max(1.0, words / 3.2);
        return Math.Min(1.2, Math.Max(0.3, display * 0.5 - Math.Max(0, lag)));
    }

    /// Đặt khoảng nghỉ (gọi từ hàng đợi OCR) và bảo bộ so khung coi khung đầu tiên sau khi nghỉ là "mới".
    void Hold(double seconds)
    {
        if (!adaptive || seconds <= 0) return;
        gateQueue.Async(() =>
        {
            holdUntil = DateTime.UtcNow.AddSeconds(seconds);
            CancelStable(); pendingPB = null; changingSince = null;
            gate.Reset();
        });
    }

    void AddRecent(IEnumerable<string> items)
    {
        foreach (var d in items) recent.Add((d, null));
        if (recent.Count > 6) recent.RemoveRange(0, recent.Count - 6);
    }

    void RunOCR(Frame pb)
    {
        if (ocrBusy) { pendingPB = pb; return; }
        ocrBusy = true;
        ocrStartedAt = DateTime.UtcNow;
        ocrRuns++;
        ocrQueue.Async(() =>
        {
            try { DoOCR(pb); }
            finally
            {
                // Xong OCR: nếu trong lúc bận có khung mới đang chờ (và không có timer chờ ổn định) thì OCR luôn.
                gateQueue.Async(() =>
                {
                    ocrBusy = false;
                    if (!stopped && stableTimer == null && pendingPB != null) FlushPending();
                });
            }
        });
    }

    void DoOCR(Frame pb)
    {
        if (stopped) return;
        ocr.minRowHeight = (subtitleHeight ?? 0) * 0.6;
        var r = ocr.Recognize(pb).GetAwaiter().GetResult();
        if (r == null) return;
        double lag = Math.Min(2.5, (DateTime.UtcNow - lastLookAt).TotalSeconds);
        lastLookAt = DateTime.UtcNow;
        onOCR?.Invoke();
        // Game hiện tên ở dòng riêng phía trên: ghép "Tên" + câu bên dưới thành "Tên: câu".
        IList<string> rows = r.lines;
        bool nameJoined = false;
        if (namesAbove()) (rows, nameJoined) = SpeakerNames.JoinNameAbove(r.lines, speakerNames());
        var text = nameJoined ? string.Join(" ", rows) : r.text;
        if (text.Length == 0 || TextUtils.LetterCount(text) < 2)
        {
            RegionPreviewProvider.shared.ReportOCR(region.id, r.ms, text);
            if (lastText.Length > 0) { lastText = ""; onEmpty?.Invoke(region); }
            // Phụ đề đã biến mất: bắt đầu đếm thời gian vắng mặt của mọi câu đang nhớ.
            var gone = DateTime.UtcNow;
            for (int i = 0; i < recent.Count; i++) if (recent[i].missingSince == null) recent[i] = (recent[i].text, gone);
            return;
        }
        // Chữ giao diện (menu, cài đặt, danh sách) → không dịch, không đọc.
        if (skipUI)
        {
            // Dòng tên riêng (Viết Hoa, không dấu câu, cỡ chữ khác câu thoại) không được tính là dấu hiệu chữ giao diện.
            var v = nameJoined
                ? SubtitleClassifier.Classify(string.Join(" ", r.lines.Skip(1)), Math.Max(1, r.rows - 1), r.maxPerRow, 1)
                : SubtitleClassifier.Classify(r);
            if (v.isUI)
            {
                RegionPreviewProvider.shared.ReportOCR(region.id, r.ms, "⏸ " + text);
                if (!TextUtils.SameLine(text, lastText, dedup))
                    Log.Info($"UI[{region.name}] bỏ qua ({string.Join(", ", v.reasons)}): {Head(text, 80)}");
                lastText = text;
                onUI?.Invoke(text, region);
                Hold(0.8);      // menu / màn hình cài đặt đứng yên lâu, không cần soi liên tục
                return;
            }
        }
        RegionPreviewProvider.shared.ReportOCR(region.id, r.ms, text);
        // Tách thành từng câu thoại và lọc trùng theo từng câu (so với 6 câu gần nhất trong 20 s).
        var now = DateTime.UtcNow;
        // Chỉ nhớ những câu ĐANG nằm trên màn hình: câu còn hiện liên tục thì không đọc lại, dù đứng yên bao lâu.
        // Câu OCR không còn thấy quá `forgetAfter` giây, hoặc đã bị câu mới thay thế (xem dưới), thì quên:
        // A → B → A đọc lại A. Thời gian vắng mặt chỉ tính từ lần OCR thấy câu đã biến mất, không theo đồng hồ.
        var onScreen = SubtitleSplitter.Utterances(rows, speakerNames(), usesNames());
        recent.RemoveAll(x => x.missingSince is DateTime m && (now - m).TotalSeconds > forgetAfter);
        for (int i = 0; i < recent.Count; i++)
        {
            if (SubtitleSplitter.Score(recent[i].text, onScreen) >= dedup) recent[i] = (recent[i].text, null);
            else if (recent[i].missingSince == null) recent[i] = (recent[i].text, now);
        }
        var fresh = SubtitleSplitter.Fresh(rows, speakerNames(), usesNames(), recent.Select(x => x.text).ToList(), dedup);
        bool changed = text != lastText;
        lastText = text;
        // Câu chỉ có từ cảm thán (hmm, haha, huh…): không dịch, không đọc; vẫn ghi nhớ để không xét lại.
        if (skipInterjections)
        {
            var dropped = fresh.Where(SubtitleSplitter.IsInterjectionOnly).ToList();
            if (dropped.Count > 0)
            {
                fresh.RemoveAll(SubtitleSplitter.IsInterjectionOnly);
                AddRecent(dropped);
                Log.Info($"CẢM THÁN[{region.name}] bỏ qua: {string.Join(" ⏎ ", dropped)}");
                if (fresh.Count == 0) return;
            }
        }
        // Mẩu chữ lạc đứng một mình (chữ trong cảnh game, nút bấm): không dịch, không đọc; ghi nhớ để không xét lại.
        if (skipUI)
        {
            var stray = fresh.Where(SubtitleSplitter.IsStrayFragment).ToList();
            if (stray.Count > 0)
            {
                fresh.RemoveAll(SubtitleSplitter.IsStrayFragment);
                AddRecent(stray);
                Log.Info($"LẠC[{region.name}] bỏ qua: {string.Join(" ⏎ ", stray)}");
                if (fresh.Count == 0) { Hold(0.6); return; }
            }
        }
        // Câu quá đơn giản (1–2 từ, toàn từ cơ bản): người chơi tự hiểu → không dịch, không đọc, chỉ ghi vào nhật ký.
        // Không có từ tiếng Anh thật nào (OCR đọc bậy: "imph", "impr") thì bỏ hẳn. Đều được ghi nhớ để không xét lại.
        if (skipSimple)
        {
            var simple = fresh.Where(SubtitleSplitter.IsSimple).ToList();
            if (simple.Count > 0)
            {
                fresh.RemoveAll(SubtitleSplitter.IsSimple);
                AddRecent(simple);
                var real = simple.Where(SubtitleSplitter.HasEnglishWord).ToList();
                var junk = simple.Where(s => !SubtitleSplitter.HasEnglishWord(s)).ToList();
                if (real.Count > 0)
                {
                    Log.Info($"ĐƠN GIẢN[{region.name}] không dịch, chỉ ghi nhật ký: {string.Join(" ⏎ ", real)}");
                    onSkipped?.Invoke(string.Join("\n", real), region);
                }
                if (junk.Count > 0) Log.Info($"VÔ NGHĨA[{region.name}] bỏ hẳn: {string.Join(" ⏎ ", junk)}");
                if (fresh.Count == 0) { Hold(0.4); return; }
            }
        }
        if (fresh.Count == 0)
        {
            if (changed) Log.Info($"DUP[{region.name}] đã đọc rồi: {Head(text, 60)}");
            // Câu cũ vẫn còn trên màn hình: soi thưa dần (0,4 → 0,6 s) cho tới khi có câu mới.
            dupStreak++;
            Hold(dupStreak >= 2 ? 0.6 : 0.4);
            return;
        }
        dupStreak = 0;
        // Có câu mới thật: câu cũ nào không còn trên màn hình là đã được thay thế → quên ngay.
        recent.RemoveAll(x => x.missingSince != null);
        AddRecent(fresh);
        bool droppedOld = string.Join(" ", fresh).Length < text.Length - 3;
        Log.Info($"OCR[{region.name}] {r.ms:0}ms{(fresh.Count > 1 ? $" [{fresh.Count} câu]" : "")}{(droppedOld ? " [bỏ câu cũ]" : "")}: {string.Join(" ⏎ ", fresh)}");
        // Học cỡ chữ phụ đề từ những hàng chắc chắn là lời thoại (từ 4 từ trở lên).
        var sure = r.lines.Zip(r.lineHeights).Where(p => TextUtils.WordCount(p.First) >= 4).Select(p => p.Second).ToList();
        if (sure.Count > 0) { var h = sure.Max(); subtitleHeight = subtitleHeight is double s ? s * 0.7 + h * 0.3 : h; }
        onText?.Invoke(string.Join("\n", fresh), region);
        Hold(HoldAfterSubtitle(string.Join(" ", fresh), lag));
    }

    static string Head(string s, int n) => s.Length > n ? s[..n] : s;
}

/// Bản dịch mới nhất của một khu vực dịch thêm, hiện ngay tại khung đó trên hình PS5.
public sealed record RegionCaption(string source, string translated, DateTime at);

/// Điều phối: các RegionWorker → hàng đợi dịch có thứ tự → giọng đọc + overlay + web + nhật ký. Dùng trên UI thread.
public sealed class Pipeline : INotifyPropertyChanged
{
    public static readonly Pipeline shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

    bool _running; public bool isRunning { get => _running; private set { _running = value; Raise(nameof(isRunning)); } }
    public int ocrCount { get; private set; }
    public int translateCount { get; private set; }
    public string lastSource { get; private set; } = "";
    public string lastTranslated { get; private set; } = "";
    public BackendKind? lastBackend { get; private set; }
    public int lastMs { get; private set; }
    public DateTime? lastAt { get; private set; }
    public Dictionary<Guid, string?> workerErrors { get; private set; } = new();
    /// true = app gắn không ở phía trước
    public Dictionary<Guid, bool> inactiveRegions { get; private set; } = new();
    /// vùng đang hiện chữ giao diện (bị bỏ qua)
    public Dictionary<Guid, string> skippedUI { get; private set; } = new();
    public int skippedCount { get; private set; }
    /// Bản dịch mới nhất của từng khu vực dịch thêm (hiện ngay tại khung trên hình PS5).
    public Dictionary<Guid, RegionCaption> regionCaptions { get; private set; } = new();

    readonly AppSettings settings = AppSettings.shared;
    public readonly TranslationRouter router;
    public readonly Speaker speaker = new();
    SubtitleOverlay? _overlay;
    public SubtitleOverlay overlay => _overlay ??= new SubtitleOverlay();
    public readonly ScreenAnalyzer analyzer;
    List<RegionWorker> workers = new();
    DispatcherTimer? warmTimer;

    Pipeline()
    {
        router = new TranslationRouter();
        analyzer = new ScreenAnalyzer(router, speaker);
    }

    // MARK: control

    public void Toggle()
    {
        if (isRunning) Stop(); else _ = Start();
    }

    public async Task Start()
    {
        if (isRunning) return;
        if (!await SessionCheck.shared.AuthorizeAction()) return;
        var regions = settings.subtitleRegions.Where(r => r.enabled).ToList();
        if (regions.Count == 0) { ShowAlert("Chưa có vùng phụ đề", "Mở tab Màn hình: chọn vùng game (hoặc kết nối PS5) rồi vẽ khung phụ đề."); return; }
        if (!WinOcr.Available) { ShowAlert("Chưa có OCR tiếng Anh", WinOcr.LastError ?? "Windows OCR không dùng được."); return; }
        ResetQueue();
        ApplyVoiceSettings();
        router.SeedContextFromHistory();
        workerErrors = new(); inactiveRegions = new(); skippedUI = new();
        var started = new List<RegionWorker>();
        int gen = queueGeneration;      // Dừng / chạy lại làm số này tăng → câu OCR xong muộn của lần chạy cũ bị bỏ
        foreach (var r in regions)
        {
            var w = new RegionWorker(r, settings);
            w.onText = (text, region) => App.RunOnUI(() =>
            {
                if (queueGeneration != gen) return;
                skippedUI.Remove(region.id);
                Submit(text, region);
            });
            w.onSkipped = (text, region) => App.RunOnUI(() =>
            {
                if (queueGeneration != gen) return;
                LogSkipped(text, region);
            });
            w.onCaptureError = msg => App.RunOnUI(() =>
            {
                if (queueGeneration != gen) return;
                workerErrors[r.id] = msg;
                Raise(nameof(workerErrors));
            });
            w.onEmpty = region => App.RunOnUI(() =>
            {
                skippedUI.Remove(region.id);
                if (region.extra) { if (regionCaptions.Remove(region.id)) Raise(nameof(regionCaptions)); }   // chữ trong khu vực đã biến mất → bỏ bản dịch tại khung
                else overlay.Hide();
                Raise(nameof(skippedUI));
            });
            var st = settings;
            // Khu vực dịch thêm (r.extra): không lấy tên nhân vật, chỉ OCR rồi dịch.
            w.speakerNames = () => st.speakers;
            w.usesNames = () => st.showsSpeakerNames && !r.extra;
            w.namesAbove = () => st.showsSpeakerNames && st.speakerAbove && !r.extra;
            w.onUI = (text, region) => App.RunOnUI(() =>
            {
                if (!skippedUI.ContainsKey(region.id)) skippedCount++;
                skippedUI[region.id] = text;
                overlay.Hide();
                Raise(nameof(skippedUI));
            });
            w.onActiveChange = active => App.RunOnUI(() =>
            {
                inactiveRegions[r.id] = !active;
                if (!active) { overlay.Hide(); speaker.Stop(); }
                Raise(nameof(inactiveRegions));
            });
            w.onOCR = () => App.RunOnUI(() => { ocrCount++; Raise(nameof(ocrCount)); });
            try
            {
                await Task.Run(w.Start);
                started.Add(w);
            }
            catch (Exception e)
            {
                Log.Error($"Không start được vùng '{r.name}': {e.Message}");
                workerErrors[r.id] = e.Message;
            }
        }
        workers = started;
        isRunning = started.Count > 0;
        Raise(nameof(workerErrors));
        if (isRunning)
        {
            // Giữ máy không ngủ khi đang dịch.
            Win32.SetThreadExecutionState(Win32.ES_CONTINUOUS | Win32.ES_SYSTEM_REQUIRED);
            ApplyVoiceSettings();
            speaker.PreloadLocal();
            speaker.KeepWarm();
            warmTimer?.Stop();
            warmTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            warmTimer.Tick += (_, _) =>
            {
                if (!isRunning || !settings.voiceOn) return;
                // Chỉ giữ kết nối Edge khi vừa có thoại; im lặng lâu thì thôi (câu kế tiếp tự mở lại trong lúc dịch).
                if ((DateTime.UtcNow - lastSubmitAt).TotalSeconds >= 120) return;
                ApplyVoiceSettings();
                speaker.KeepWarm();
            };
            warmTimer.Start();
        }
        else if (workerErrors.Count > 0)
        {
            ShowAlert("Không bắt đầu được", string.Join("\n", workerErrors.Values.Where(v => v != null)));
        }
        RegionPreviewProvider.shared.pipelineRunning = isRunning;
        Log.Info($"Pipeline running with {started.Count} region(s)");
    }

    public void Stop()
    {
        if (!isRunning) return;
        var ws = workers;
        workers = new();
        isRunning = false;
        warmTimer?.Stop(); warmTimer = null;
        Win32.SetThreadExecutionState(Win32.ES_CONTINUOUS);
        RegionPreviewProvider.shared.pipelineRunning = false;
        ResetQueue();
        speaker.Stop();
        speaker.ReleaseResources();
        overlay.Hide();
        skippedUI = new();
        Raise(nameof(skippedUI));
        regionCaptions = new();
        Raise(nameof(regionCaptions));
        Task.Run(() => { foreach (var w in ws) w.Stop(); });
        Log.Info("Pipeline stopped");
    }

    /// Xoá bản dịch đang hiện của một khu vực (khi người dùng xoá khu vực đó).
    public void ClearRegionCaption(Guid id)
    {
        if (regionCaptions.Remove(id)) Raise(nameof(regionCaptions));
    }

    public void RestartIfRunning()
    {
        if (!isRunning) return;
        Stop();
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        t.Tick += async (_, _) => { t.Stop(); await Start(); };
        t.Start();
    }

    /// Dịch thủ công toàn bộ vùng manual đang bật.
    public void AnalyzeScreen()
    {
        var regions = settings.manualRegions.Where(r => r.enabled).ToList();
        if (regions.Count == 0)
        {
            ShowAlert("Chưa có màn hình game", "Mở tab Màn hình: chọn vùng game (hoặc kết nối PS5) trước.");
            return;
        }
        _ = Task.Run(async () =>
        {
            if (!await SessionCheck.shared.AuthorizeAction()) return;
            App.RunOnUI(() => { if (settings.overlayOn) overlay.Hud("Đang phân tích màn hình…", 3); });
            var a = await analyzer.Analyze(regions);
            App.RunOnUI(() =>
            {
                if (a != null) { if (settings.overlayOn) overlay.Hud($"Xong: {(a.summary.Length > 120 ? a.summary[..120] : a.summary)}", 8); }
                else if (analyzer.lastError is string e && settings.overlayOn) overlay.Hud($"Không phân tích được: {e}", 4);
            });
        });
    }

    public OverlayStyle overlayStyle => new(settings.overlayFontSize, settings.overlayOpacity, settings.overlayShowSource,
                                           settings.overlayMaxWidth, settings.overlayPosition, settings.overlayHideAfter);

    public void PreviewOverlay() =>
        overlay.Show("Đây là bản dịch hiển thị trên overlay.", "This is how the overlay looks.", settings.subtitleRegions.FirstOrDefault(), overlayStyle);

    // MARK: hàng đợi dịch có thứ tự
    //
    // Mỗi câu thoại là một việc có số thứ tự. Việc được dịch lần lượt hoặc song song tuỳ engine,
    // nhưng luôn được ĐỌC đúng thứ tự: việc nào tới lượt mà đã dịch xong thì đọc ngay, không chờ cả khối.

    record Job(int seq, string text, string? speakerName, Region region, int utterance, bool lastOfUtterance, bool firstOfBatch, string fullSource);

    int jobSeq, utteranceSeq, nextToEmit, inFlight;
    readonly List<Job> pendingJobs = new();
    readonly Dictionary<int, (Job job, TranslationRouter.Output? output)> finished = new();
    readonly Dictionary<int, List<string>> utteranceParts = new();
    readonly Dictionary<int, int> utteranceMs = new();
    readonly Dictionary<int, BackendKind> utteranceBackend = new();
    string batchSource = "", batchOutput = "";
    int lastEmittedUtterance = -1;
    int queueGeneration;
    DateTime lastSubmitAt = DateTime.UtcNow;

    /// `batch` có thể gồm nhiều câu thoại (ngăn bởi xuống dòng) khi hai người nói hiện cùng lúc.
    void Submit(string batch, Region region)
    {
        lastSubmitAt = DateTime.UtcNow;
        if (settings.queueMode == QueueMode.latestWins)
        {
            // Chế độ "chỉ giữ câu mới nhất": bỏ các việc chưa bắt đầu dịch.
            foreach (var j in pendingJobs) finished[j.seq] = (j, null);
            pendingJobs.Clear();
        }
        bool first = true;
        foreach (var rawText in batch.Split('\n'))
        {
            var text = rawText;
            string? speakerName = null;
            if (settings.showsSpeakerNames && !region.extra)
            {
                if (SpeakerNames.Learn(rawText) is string name) settings.LearnSpeaker(name);
                var n = SpeakerNames.Normalize(rawText, settings.speakers);
                text = n.text;
                speakerName = n.speaker;
                if (text != rawText) Log.Info($"Chuẩn hoá tên người nói: {Head(rawText, 40)} → {Head(text, 40)}");
            }
            utteranceSeq++;
            pendingJobs.Add(new Job(jobSeq, text, speakerName, region, utteranceSeq, true, first, text));
            jobSeq++;
            first = false;
        }
        if (settings.voiceOn) { ApplyVoiceSettings(); speaker.Prewarm(); }
        Pump();
    }

    static string Head(string s, int n) => s.Length > n ? s[..n] : s;

    void Pump()
    {
        int limit = Math.Max(1, router.parallelism);
        while (inFlight < limit && pendingJobs.Count > 0)
        {
            var job = pendingJobs[0];
            pendingJobs.RemoveAt(0);
            inFlight++;
            int gen = queueGeneration;
            _ = Task.Run(async () =>
            {
                var outp = await router.Translate(job.text);
                App.RunOnUI(() =>
                {
                    if (gen != queueGeneration) return;       // đã Dừng / đổi game trong lúc dịch
                    inFlight--;
                    if (outp == null) Log.Warn($"No translation for: {job.text}");
                    finished[job.seq] = (job, outp);
                    Drain();
                    Pump();
                });
            });
        }
    }

    /// Phát các việc đã xong theo đúng thứ tự.
    void Drain()
    {
        while (finished.TryGetValue(nextToEmit, out var item))
        {
            finished.Remove(nextToEmit);
            nextToEmit++;
            if (item.output != null) Emit(item.job, item.output);
            if (item.job.lastOfUtterance) FinishUtterance(item.job);
        }
    }

    void Emit(Job job, TranslationRouter.Output outp)
    {
        if (job.region.extra)
        {
            // Khu vực dịch thêm: chỉ hiện bản dịch ngay tại khung (không vào dải phụ đề chung, không đọc, không gửi web / TV).
            if (!utteranceParts.TryGetValue(job.utterance, out var xp)) utteranceParts[job.utterance] = xp = new();
            xp.Add(outp.text);
            utteranceMs[job.utterance] = utteranceMs.GetValueOrDefault(job.utterance) + outp.ms;
            utteranceBackend[job.utterance] = outp.backend;
            translateCount++;
            Log.Info($"TR[{outp.backend}] {outp.ms}ms [{job.region.name}]: {outp.text}");
            var prev = regionCaptions.GetValueOrDefault(job.region.id);
            bool append = !job.firstOfBatch && prev != null;
            regionCaptions[job.region.id] = new RegionCaption(append ? prev!.source + "\n" + job.text : job.text,
                                                              append ? prev!.translated + "\n" + outp.text : outp.text, DateTime.Now);
            Raise(nameof(regionCaptions));
            return;
        }
        if (job.firstOfBatch) { batchSource = ""; batchOutput = ""; }
        // Các đoạn của cùng một câu nối liền bằng khoảng trắng; câu thoại khác thì xuống dòng.
        var sep = batchOutput.Length == 0 ? "" : (job.utterance == lastEmittedUtterance ? " " : "\n");
        batchSource += sep + job.text;
        batchOutput += sep + outp.text;
        lastEmittedUtterance = job.utterance;
        if (!utteranceParts.TryGetValue(job.utterance, out var parts)) utteranceParts[job.utterance] = parts = new();
        parts.Add(outp.text);
        utteranceMs[job.utterance] = utteranceMs.GetValueOrDefault(job.utterance) + outp.ms;
        utteranceBackend[job.utterance] = outp.backend;
        translateCount++;
        lastSource = batchSource;
        lastTranslated = batchOutput;
        lastBackend = outp.backend;
        lastMs = outp.ms;
        lastAt = DateTime.Now;
        Raise(nameof(lastTranslated));
        Log.Info($"TR[{outp.backend}] {outp.ms}ms: {outp.text}");
        WebServer.shared.Subtitle(batchSource, batchOutput, job.firstOfBatch);
        if (settings.voiceOn)
        {
            ApplyVoiceSettings();
            var toSpeak = settings.voiceSkipSpeaker && settings.showsSpeakerNames && job.speakerName != null
                ? SpeakerNames.StripForVoice(outp.text, job.speakerName, settings.speakers)
                : outp.text;
            // Chỉ câu đầu của một lô mới được phép cắt câu đang đọc (nếu bật "ngắt"); các câu sau đọc nối tiếp.
            speaker.Speak(toSpeak, !job.firstOfBatch);
        }
        if (settings.overlayOn && !job.region.embedded)   // nguồn PS5: phụ đề hiện ngay trong tab Màn hình
            overlay.Show(lastTranslated, lastSource, job.region, overlayStyle);
    }

    void FinishUtterance(Job job)
    {
        if (!utteranceParts.Remove(job.utterance, out var parts) || parts.Count == 0) return;
        utteranceMs.Remove(job.utterance, out var ms);
        var backend = utteranceBackend.Remove(job.utterance, out var b) ? b : BackendKind.google;
        HistoryStore.shared.Add(job.region.name, job.fullSource, string.Join(" ", parts), backend, ms,
                                RegionKind.subtitle, settings.targetLanguage, HistoryStore.ProfileKey(settings.activeProfile.id));
    }

    /// Câu quá đơn giản: ghi nguyên câu gốc vào nhật ký (không dịch, không đọc, không hiện overlay).
    void LogSkipped(string batch, Region region)
    {
        foreach (var raw in batch.Split('\n'))
        {
            var text = raw;
            if (settings.showsSpeakerNames && !region.extra)
            {
                if (SpeakerNames.Learn(raw) is string name) settings.LearnSpeaker(name);
                text = SpeakerNames.Normalize(raw, settings.speakers).text;
            }
            HistoryStore.shared.Add(region.name, text, text, BackendKind.skipped, 0, RegionKind.subtitle,
                                    settings.targetLanguage, HistoryStore.ProfileKey(settings.activeProfile.id));
        }
    }

    /// Dùng cho cờ kiểm thử --feed: đưa thẳng văn bản vào hàng đợi dịch như thể OCR vừa đọc được.
    public void TestFeed(string batch)
    {
        var r = settings.subtitleRegions.FirstOrDefault() ?? new Region { name = "Test", width = 1, height = 1 };
        Submit(batch, r);
    }

    void ResetQueue()
    {
        queueGeneration++;
        pendingJobs.Clear(); finished.Clear(); inFlight = 0;
        nextToEmit = jobSeq;
        utteranceParts.Clear(); utteranceMs.Clear(); utteranceBackend.Clear();
    }

    public void ApplyVoiceSettings()
    {
        speaker.rate = settings.voiceRate;
        speaker.interrupt = settings.interruptSpeech;
        speaker.voiceIdentifier = settings.voiceIdentifier;
        speaker.language = settings.targetLanguage;
        speaker.adaptiveRate = settings.voiceAdaptiveRate;
        speaker.catchUpBoost = settings.catchUpPercent / 100;
        speaker.silent = settings.forceMute;
        speaker.engine = settings.forceEngine ?? settings.voiceEngine;
        speaker.edgeRatePercent = settings.edgeRatePercent;
        speaker.localVoiceID = settings.localVoiceID;
        speaker.localSpeed = settings.localSpeed;
        speaker.edgeVoice = settings.edgeVoice.Length == 0 ? EdgeTTS.DefaultVoice(settings.targetLanguage) : settings.edgeVoice;
        speaker.onEngineFallback ??= msg => App.RunOnUI(() => overlay.Hud(msg, 3));
        // Giọng đọc trên TV / điện thoại: chỉ khi có máy đang xem, không thì đọc ra loa máy này như cũ.
        speaker.remote = settings.voiceOnRemote && settings.webServerOn && WebServer.shared.hasViewers;
        speaker.onRemoteAudio ??= (data, mime, flush, text) => WebServer.shared.Audio(data, mime, flush, text);
    }

    // MARK: alerts

    public void ShowAlert(string title, string msg)
    {
        if (settings.suppressAlerts) { Log.Warn($"ALERT suppressed: {title} – {msg}"); return; }
        App.RunOnUI(() => MessageBox.Show(msg, title, MessageBoxButton.OK, MessageBoxImage.Information));
    }
}
