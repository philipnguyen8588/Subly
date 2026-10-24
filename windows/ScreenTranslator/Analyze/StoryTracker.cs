using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Tự viết cốt truyện của game đang chơi: định kỳ khi đang dịch, một lần sau khi dừng, hoặc khi người dùng bấm cập nhật.
/// Mỗi lần lấy các câu phụ đề (và tóm tắt "Dịch màn hình") sau con trỏ đã lưu của game, gửi model cùng cốt truyện đã có,
/// rồi lưu bài viết liền mạch, đoạn diễn biến mới và nhân vật vào nhật ký. Con trỏ chỉ tiến khi lưu thành công.
/// Dùng trên UI thread.
public sealed class StoryTracker : INotifyPropertyChanged
{
    public static readonly StoryTracker shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

    public enum Trigger { timer, stop, manual, catchUp }

    bool _running;
    public bool isRunning { get => _running; private set { _running = value; Raise(nameof(isRunning)); } }
    int _runningLines;
    /// Số câu đang được đưa vào cốt truyện (khi `isRunning`).
    public int runningLines { get => _runningLines; private set { _runningLines = value; Raise(nameof(runningLines)); } }
    int _pendingLines, _pendingScreens, _backlog;
    /// Số câu đã dịch / số lần dịch màn hình chưa được đưa vào cốt truyện của game đang chọn.
    public int pendingLines { get => _pendingLines; private set { if (_pendingLines != value) { _pendingLines = value; Raise(nameof(pendingLines)); } } }
    public int pendingScreens { get => _pendingScreens; private set { if (_pendingScreens != value) { _pendingScreens = value; Raise(nameof(pendingScreens)); } } }
    /// Số câu đã dịch trong cả nhật ký của game (để mời "Tóm tắt từ đầu nhật ký").
    public int backlogLines { get => _backlog; private set { if (_backlog != value) { _backlog = value; Raise(nameof(backlogLines)); } } }
    string? _error, _notice;
    public string? lastError { get => _error; private set { _error = value; Raise(nameof(lastError)); } }
    /// Lý do tạm hoãn (không phải lỗi): hết quota, chưa có câu mới…
    public string? notice { get => _notice; private set { _notice = value; Raise(nameof(notice)); } }

    readonly AppSettings settings = AppSettings.shared;
    readonly HistoryStore store = HistoryStore.shared;
    DispatcherTimer? loop, pendingTimer;
    double loopInterval;
    CancellationTokenSource? stopCts, catchUpCts;
    /// Chuỗi cập nhật do người dùng bấm: chạy tiếp tới khi hết câu tồn, kể cả khi đang tắt tự động.
    bool chainManual;
    /// Người dùng vừa bấm "Tóm tắt từ đầu nhật ký" và chưa lưu được lần nào → chưa đặt con trỏ ở cuối nhật ký.
    bool fromStart;
    int failStreak;
    DateTime nextAutoAllowed = DateTime.MinValue;

    const int lineCap = 150, charCap = 12_000;

    double interval => settings.forceStoryInterval ?? Math.Max(1, settings.storyIntervalMin) * 60.0;
    string activeProfile => HistoryStore.ProfileKey(settings.activeProfile.id);

    public void DismissError() { lastError = null; notice = null; }

    /// Gọi một lần lúc khởi động, sau khi `Pipeline.shared` đã có.
    public void Begin()
    {
        Pipeline.shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Pipeline.isRunning)) App.RunOnUI(PipelineChanged); };
        settings.Changed += key =>
        {
            if (key is "storyEnabled" or "storyIntervalMin" or "activeProfileID" or "profiles" or "activeProfile") App.RunOnUI(Watch);
        };
        pendingTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        pendingTimer.Tick += (_, _) => { pendingTimer!.Stop(); RefreshPending(); };
        void Soon() => App.RunOnUI(() => { pendingTimer!.Stop(); pendingTimer.Start(); });
        store.EntryAdded += _ => Soon();
        store.AnalysisAdded += _ => Soon();
        store.EntriesCleared += Soon;
        Watch();
    }

    /// Cài đặt hoặc game đổi: đặt con trỏ cho game chưa có cốt truyện, bật / tắt vòng định kỳ.
    void Watch()
    {
        var profile = activeProfile;
        if (settings.storyOn && !isRunning && !fromStart && store.LoadStory(profile) == null) store.StartStoryFromNow(profile);
        bool want = settings.storyOn && Pipeline.shared.isRunning;
        if (!want) { loop?.Stop(); loop = null; }
        else if (loop == null || loopInterval != interval)
        {
            loop?.Stop();
            loopInterval = interval;
            loop = new DispatcherTimer { Interval = TimeSpan.FromSeconds(loopInterval) };
            loop.Tick += (_, _) => _ = Run(Trigger.timer);
            loop.Start();
        }
        RefreshPending();
    }

    bool wasRunning;
    void PipelineChanged()
    {
        bool running = Pipeline.shared.isRunning;
        if (running == wasRunning) return;
        wasRunning = running;
        stopCts?.Cancel(); stopCts = null;
        Watch();
        if (running || !settings.storyOn) return;
        // Sửa khung dịch làm pipeline dừng rồi chạy lại ngay → chờ một lúc, vẫn dừng mới coi là hết buổi chơi.
        var cts = stopCts = new CancellationTokenSource();
        _ = After(8, cts.Token, () => { if (!Pipeline.shared.isRunning) _ = Run(Trigger.stop); });
    }

    static async Task After(double seconds, CancellationToken ct, Action then)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(seconds), ct); } catch (OperationCanceledException) { return; }
        if (!ct.IsCancellationRequested) then();
    }

    public void RefreshPending()
    {
        var profile = activeProfile;
        var p = store.StoryPending(profile);
        pendingLines = p.lines;
        pendingScreens = p.screens;
        backlogLines = store.StoryBacklog(profile);
    }

    /// Nút "Cập nhật ngay": đưa các câu mới (sau con trỏ) vào cốt truyện.
    public void UpdateNow()
    {
        chainManual = true;
        _ = Run(Trigger.manual);
    }

    /// Nút "Tóm tắt từ đầu nhật ký": xoá cốt truyện đang có của game rồi viết lại từ câu đầu tiên, nhiều lượt cho tới hết.
    /// Nút "Đọc lại các màn hình đã dịch" (Bách khoa): đưa con trỏ màn hình về đầu để các màn hình nhật ký dịch trước đây
    /// được tách thành mục bách khoa / hồ sơ nhân vật; con trỏ câu phụ đề giữ nguyên nên diễn biến không bị viết lại.
    public void RescanScreens()
    {
        ResetState();
        store.RewindStoryScreens(activeProfile);
        RefreshPending();
        UpdateNow();
    }

    public void SummarizeFromStart()
    {
        ResetState();
        store.ResetStory(false);
        fromStart = true;
        RefreshPending();
        UpdateNow();
    }

    /// Xoá cốt truyện của game đang chọn. `fromNow`: chỉ viết tiếp từ những câu sau lúc này.
    public void Reset(bool fromNow)
    {
        if (!fromNow) { SummarizeFromStart(); return; }
        ResetState();
        store.ResetStory(true);
        RefreshPending();
    }

    void ResetState()
    {
        catchUpCts?.Cancel(); catchUpCts = null;
        fromStart = false;
        failStreak = 0;
        nextAutoAllowed = DateTime.MinValue;
        lastError = null;
        notice = null;
    }

    int MinimumWeight(Trigger trigger, bool manual)
    {
        if (manual) return 1;
        return trigger == Trigger.stop ? 5 : settings.forceStoryInterval != null ? 3 : 15;
    }

    async Task Run(Trigger trigger)
    {
        if (isRunning) return;
        bool manual = trigger == Trigger.manual || (trigger == Trigger.catchUp && chainManual);
        if (trigger != Trigger.manual && trigger != Trigger.catchUp) chainManual = false;
        if (!manual && !settings.storyOn) return;
        var profile = activeProfile;
        var pending = store.StoryPending(profile);
        if (pending.lines + 5 * pending.screens < MinimumWeight(trigger, manual))
        {
            if (trigger == Trigger.manual) notice = "Chưa có câu mới nào để đưa vào cốt truyện";
            return;
        }
        if (!manual && DateTime.Now < nextAutoAllowed) return;

        isRunning = true;
        runningLines = Math.Min(pending.lines, lineCap);
        int counted = 0;
        try
        {
            if (manual) { if (!await SessionCheck.shared.AuthorizeAction()) return; }
            else if (!SessionCheck.shared.Valid()) return;

            var current = store.LoadStory(profile);
            long cursor = current?.lastEntryID ?? 0, screenCursor = current?.lastAnalysisID ?? 0;
            // Lỗi liên tiếp (thường do đoạn quá dài bị cắt cụt) → mỗi lần lấy ít câu hơn.
            int cap = Math.Max(40, lineCap >> failStreak);
            var entries = store.StoryEntries(profile, cursor, cap + 1);
            bool more = entries.Count > cap;
            if (more) entries.RemoveAt(entries.Count - 1);
            int chars = 0, keep = 0;
            foreach (var e in entries)
            {
                chars += e.source.Length + 1;
                if (chars > charCap && keep >= 20) break;
                keep++;
            }
            if (keep < entries.Count) { entries = entries.Take(keep).ToList(); more = true; }
            var screens = store.StoryAnalyses(profile, screenCursor);
            if (more && entries.Count > 0) { var last = entries[^1].timestamp; screens = screens.Where(s => s.timestamp <= last).ToList(); }
            // Lượt chỉ có màn hình (không có câu phụ đề mới, ví dụ khi đọc lại màn hình cũ) lấy được nhiều màn hình hơn.
            int screenCap = entries.Count == 0 ? 15 : 5;
            if (screens.Count > screenCap) { screens = screens.Take(screenCap).ToList(); more = true; }
            if (entries.Count == 0 && screens.Count == 0) return;

            var skipped = BackendKind.skipped.ToString();
            counted = entries.Count(e => e.backend != skipped);
            runningLines = counted;
            lastError = null;
            notice = null;
            var (input, focus) = BuildInput(current, entries, screens);
            var outp = await Pipeline.shared.router.UpdateStory(input, focus, background: !manual);
            var u = outp.update;
            var now = DateTime.Now;
            var story = new GameStory
            {
                profile = profile,
                narrative = StoryUpdate.MergeNarrative(current?.narrative ?? "", u),
                characters = StoryUpdate.MergeCharacters(current?.characters ?? new(), u.characters),
                lore = StoryUpdate.MergeLore(current?.lore ?? new(), u.lore),
                lastEntryID = entries.Count > 0 ? entries[^1].id : cursor,
                lastAnalysisID = screens.Count > 0 ? screens[^1].id : screenCursor,
                updated = now, backend = outp.backend.ToString(),
            };
            var from = entries.Count > 0 ? entries[0].timestamp : screens.Count > 0 ? screens[0].timestamp : now;
            var to = entries.Count > 0 ? entries[^1].timestamp : screens.Count > 0 ? screens[^1].timestamp : now;
            StoryUpdate.MarkSeen(story.characters, focus, u.characters, new DateTimeOffset(to).ToUnixTimeMilliseconds() / 1000.0);
            var part = u.partSummary.Length == 0 ? null : new StoryPart
            {
                timestamp = now, profile = profile, title = u.partTitle.Length == 0 ? $"Diễn biến lúc {from:HH:mm}" : u.partTitle,
                summary = u.partSummary, from = from, to = to, entryFrom = entries.Count > 0 ? entries[0].id : cursor,
                entryTo = story.lastEntryID, lineCount = counted, backend = outp.backend.ToString(), latencyMs = outp.ms,
            };
            if (!store.SaveStoryUpdate(story, cursor, part))
            {
                Log.Info("Cốt truyện: bỏ kết quả vì cốt truyện của game vừa được xoá / viết lại");
                return;
            }
            fromStart = false;
            failStreak = 0;
            nextAutoAllowed = DateTime.MinValue;
            Log.Info($"Cốt truyện [{outp.backend}] +{counted} câu, {screens.Count} màn hình, {outp.ms}ms: " +
                     $"{part?.title ?? "(không có diễn biến mới)"} · truyện {story.narrative.Length} ký tự · " +
                     $"{story.characters.Count} nhân vật (id ≤ {story.lastEntryID})");
            if (more) ScheduleCatchUp(manual);
        }
        catch (TranslationRouter.StoryException e) when (e.busy)
        {
            notice = e.Message + (manual ? " · sẽ tự thử lại sau 1 phút" : "");
            Log.Info($"Cốt truyện: {e.Message}");
            // Chuỗi do người dùng bấm (tóm tắt cả nhật ký): hết quota thì chờ rồi chạy tiếp, không bắt bấm lại.
            if (manual) ScheduleCatchUp(true, 60);
        }
        catch (Exception e)
        {
            failStreak++;
            nextAutoAllowed = DateTime.Now.AddSeconds(Math.Min(interval * Math.Pow(2, failStreak), 3600));
            bool retrying = manual && failStreak < 3;
            lastError = $"Không cập nhật được cốt truyện: {e.Message}" + (retrying ? " · đang thử lại với ít câu hơn" : "");
            Log.Error($"Cốt truyện {counted} câu lỗi: {e.Message}");
            if (retrying) ScheduleCatchUp(true, 15);
        }
        finally
        {
            isRunning = false;
            runningLines = 0;
            RefreshPending();
        }
    }

    /// Còn câu tồn (nhật ký dài hơn một lượt) → chạy lượt tiếp sau một lúc, không dồn request làm hết quota/phút.
    void ScheduleCatchUp(bool manual, double? fixedWait = null)
    {
        chainManual = manual;
        catchUpCts?.Cancel();
        var cts = catchUpCts = new CancellationTokenSource();
        double wait = fixedWait ?? (settings.forceStoryInterval != null ? 5 : manual ? 10 : 30);
        _ = After(wait, cts.Token, () => _ = Run(Trigger.catchUp));
    }

    /// Ba khối gửi model: cốt truyện đã có, nhân vật đã biết (chi tiết chỉ với người có mặt trong câu mới), câu mới.
    public static (string input, string focus) BuildInput(GameStory? story, List<TranslationEntry> entries,
                                                          List<(long id, DateTime timestamp, string text)> screens)
    {
        var items = entries.Select(e => (t: e.timestamp, text: e.source)).ToList();
        // Chữ gốc trên màn hình (nhật ký, codex, nhiệm vụ…), giống câu phụ đề cũng dùng bản gốc.
        items.AddRange(screens.Select(s =>
        {
            var src = TextUtils.Normalize(s.text);
            return (t: s.timestamp, text: "[Screen] " + (src.Length > 1500 ? src[..1500] : src));
        }));
        items = items.OrderBy(i => i.t).ToList();
        var lines = new List<string>();
        DateTime? prev = null;
        foreach (var (t, text) in items)
        {
            if (prev is DateTime p && (t - p).TotalSeconds > 300) lines.Add("[…later…]");
            lines.Add(text);
            prev = t;
        }
        var focus = string.Join("\n", lines);
        var haystack = StoryUpdate.NameKey(focus);
        var detailed = new List<string>();
        var others = new List<string>();
        foreach (var c in story?.characters ?? new())
        {
            if (!haystack.Contains(StoryUpdate.NameKey(c.name))) { others.Add(c.name); continue; }
            var fields = string.Join("; ", new[] { ("role", c.role), ("personality", c.personality), ("background", c.background), ("relations", c.relations), ("status", c.status) }
                .Where(f => f.Item2.Length > 0).Select(f => $"{f.Item1}: {f.Item2}"));
            detailed.Add($"- {c.name}: {(fields.Length == 0 ? "(nothing known yet)" : fields)}");
        }
        var known = string.Join("\n", detailed);
        if (others.Count > 0) known += (known.Length == 0 ? "" : "\n") + "Other known names: " + string.Join(", ", others);
        var narrative = story?.narrative ?? "";
        var loreNames = string.Join(", ", (story?.lore ?? new()).Select(l => l.name));
        var input = "STORY SO FAR:\n" + (narrative.Length == 0 ? "(empty: this is the first update)" : narrative) +
                    "\n\nKNOWN CHARACTERS:\n" + (known.Length == 0 ? "(none yet)" : known) +
                    "\n\nKNOWN LORE:\n" + (loreNames.Length == 0 ? "(none yet)" : loreNames) +
                    "\n\nNEW LINES:\n" + focus;
        return (input, focus);
    }
}
