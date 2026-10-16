using System;
using System.ComponentModel;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Tự kết nối lại PS5 khi đang chơi mà mất kết nối (bật/tắt ở màn Bắt đầu và Cài đặt → Capture & OCR).
/// Đang thử thì màn hình chính hiện lớp phủ (ReconnectOverlay); hết lượt thử hoặc tắt tính năng thì về màn Bắt đầu.
/// Lỗi "PS5 còn giữ phiên cũ" vẫn do PS5Stream tự thử lại (busyRetries) trước khi tới đây.
public sealed class PS5Reconnector : INotifyPropertyChanged
{
    public static readonly PS5Reconnector shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise() => App.RunOnUI(() => PropertyChanged?.Invoke(this, new(null)));

    public bool active { get; private set; }
    /// Lần thử hiện tại (1…maxAttempts); 0 = chưa thử lần nào.
    public int attempt { get; private set; }
    /// Thời điểm thử lại kế tiếp; null = đang thử.
    public DateTime? nextRetryAt { get; private set; }
    public string lastError { get; private set; } = "";
    /// Cờ test (--simulate-ps5-drop): không kết nối thật, mỗi lần thử tự báo lỗi sau 1 giây.
    public bool simulate;

    bool resumeTranslation;
    CancellationTokenSource? timer;
    static readonly double[] delays = { 3, 5, 10, 15 };

    public int maxAttempts => Math.Max(1, AppSettings.shared.ps5ReconnectAttempts);

    /// Phiên PS5 đang chơi vừa rớt (hoặc một lần thử lại vừa thất bại). Gọi trên luồng UI.
    public void ConnectionLost(string reason, bool wasTranslating)
    {
        if (!AppSettings.shared.ps5AutoReconnect) { AppNav.shared.LeaveToStart($"Mất kết nối PS5: {reason}"); return; }
        if (!active)
        {
            active = true;
            attempt = 0;
            resumeTranslation = wasTranslating;
            Log.Info($"PS5: mất kết nối ({reason}) → tự kết nối lại");
        }
        lastError = reason;
        ScheduleNext();
    }

    void ScheduleNext()
    {
        timer?.Cancel();
        if (attempt >= maxAttempts)
        {
            var n = attempt; var err = lastError;
            Cancel();
            AppNav.shared.LeaveToStart($"Không kết nối lại được PS5 sau {n} lần thử: {err}");
            return;
        }
        var delay = delays[Math.Min(attempt, delays.Length - 1)];
        nextRetryAt = DateTime.Now.AddSeconds(delay);
        Raise();
        var cts = timer = new CancellationTokenSource();
        _ = Task.Delay(TimeSpan.FromSeconds(delay), cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled) App.RunOnUI(RetryNow);
        });
    }

    /// Nút "Thử ngay" hoặc hết giờ chờ.
    public void RetryNow()
    {
        if (!active) return;
        timer?.Cancel();
        nextRetryAt = null;
        attempt++;
        Raise();
        Log.Info($"PS5: thử kết nối lại lần {attempt}/{maxAttempts}");
        if (simulate)
        {
            var cts = timer = new CancellationTokenSource();
            _ = Task.Delay(1000, cts.Token).ContinueWith(t =>
            {
                if (!t.IsCanceled) App.RunOnUI(() => { if (active) ConnectionLost("Giả lập: PS5 không trả lời", false); });
            });
        }
        else PS5Coordinator.Connect();
    }

    /// Có hình trở lại: tắt lớp phủ, dịch tiếp nếu trước đó đang dịch.
    public void StreamingResumed()
    {
        if (!active) return;
        var resume = resumeTranslation;
        Log.Info($"PS5: đã kết nối lại sau {attempt} lần thử");
        Cancel();
        if (resume) _ = Pipeline.shared.Start();
    }

    public void Cancel()
    {
        timer?.Cancel(); timer = null;
        active = false;
        attempt = 0;
        nextRetryAt = null;
        lastError = "";
        resumeTranslation = false;
        Raise();
    }
}
