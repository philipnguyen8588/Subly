using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;

namespace ScreenTranslator;

/// Tóm tắt các câu phụ đề người dùng chọn trong nhật ký, rồi lưu vào mục "Tóm tắt" của game đang chọn. Dùng trên UI thread.
public sealed class StorySummarizer : INotifyPropertyChanged
{
    public static readonly StorySummarizer shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

    int _running;
    /// Số câu đang được tóm tắt (0 = rảnh).
    public int runningCount { get => _running; private set { _running = value; Raise(nameof(runningCount)); Raise(nameof(isRunning)); } }
    string? _error;
    public string? lastError { get => _error; private set { _error = value; Raise(nameof(lastError)); } }
    long? _saved;
    /// Id bản tóm tắt vừa lưu, để giao diện chuyển sang mục Tóm tắt.
    public long? lastSavedID { get => _saved; private set { _saved = value; Raise(nameof(lastSavedID)); } }

    public bool isRunning => runningCount > 0;

    public void DismissError() => lastError = null;

    public async void Summarize(IEnumerable<TranslationEntry> entries)
    {
        var sorted = entries.OrderBy(e => e.id).ToList();
        if (isRunning || sorted.Count == 0) return;
        var profile = HistoryStore.ProfileKey(AppSettings.shared.activeProfile.id);
        runningCount = sorted.Count;
        lastError = null;
        try
        {
            var r = await Pipeline.shared.router.SummarizeStory(sorted.Select(e => e.source).ToList());
            var skipped = BackendKind.skipped.ToString();
            var lines = sorted.Select((e, i) => new AnalysisLine { id = i, source = e.source, target = e.backend == skipped ? "" : e.translated }).ToList();
            var title = r.title.Length == 0 ? $"Đoạn {sorted.Count} câu lúc {sorted[0].timestamp:HH:mm}" : r.title;
            var saved = HistoryStore.shared.AddSummary(title, r.summary, lines, sorted[0].timestamp, sorted[^1].timestamp, r.backend, r.ms, profile);
            Log.Info($"Tóm tắt [{r.backend}] {sorted.Count} câu, {r.ms}ms: {title}");
            lastSavedID = saved.id;
        }
        catch (Exception e)
        {
            lastError = $"Không tóm tắt được: {e.Message}";
            Log.Error($"Tóm tắt {sorted.Count} câu lỗi: {e.Message}");
        }
        finally { runningCount = 0; }
    }
}
