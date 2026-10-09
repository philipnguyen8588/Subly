using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace ScreenTranslator;

/// Kiểm tra máy với server. Mô hình: app LUÔN mở bình thường; chỉ khi người dùng bấm Bắt đầu / Dịch màn hình
/// mới chặn nếu máy chưa được duyệt (hiện màn hình lỗi chung). Nền kiểm tra lại mỗi vài giờ; đang chạy mà mất
/// quyền thì dừng dịch. Người dùng không thấy thông tin gì về duyệt/hết hạn.
/// Tương đương SessionCheck.swift của bản macOS.
public sealed class SessionCheck
{
    public static readonly SessionCheck shared = new();

    // Khoảng kiểm tra ngầm.
    static readonly TimeSpan RecheckOK = TimeSpan.FromHours(3);       // đã có vé: vài giờ một lần
    static readonly TimeSpan RecheckWaiting = TimeSpan.FromMinutes(2); // chưa có vé: thử lại thường xuyên hơn

    Action? onLostAccess;
    CancellationTokenSource? poll;
    readonly SemaphoreSlim refreshLock = new(1, 1);

    public void Begin(Action onLostAccess)
    {
        this.onLostAccess = onLostAccess;
        if (!RuntimeConfig.Enabled) return;
        _ = Refresh();
        Schedule();
        SystemEvents.PowerModeChanged += (_, e) => { if (e.Mode == PowerModes.Resume) _ = Refresh(); };
    }

    /// Kiểm tra nhanh bằng vé đã lưu (không gọi mạng). Dùng ở các bước dịch để im lặng ngừng khi mất quyền.
    public bool Valid()
    {
        if (!RuntimeConfig.Enabled) return true;
        return Ticket.Current()?.LooksValid() ?? false;
    }

    /// Gọi khi người dùng CHỦ ĐỘNG dùng tính năng (bấm Bắt đầu / Dịch màn hình).
    /// Có vé hợp lệ → true. Chưa có → hỏi server một lần; vẫn không → hiện lỗi chung và trả false.
    public async Task<bool> AuthorizeAction()
    {
        if (!RuntimeConfig.Enabled) return true;
        if (Valid()) return true;
        await Refresh();
        if (Valid()) return true;
        App.RunOnUI(StartupErrorWindow.Present);
        return false;
    }

    /// Hỏi server, cập nhật vé. Đang chạy mà sau khi hỏi thấy mất quyền → gọi onLostAccess.
    public async Task Refresh()
    {
        if (!RuntimeConfig.Enabled) return;
        if (!await refreshLock.WaitAsync(0)) return;   // tránh nhiều lần hỏi chồng nhau
        try
        {
            var wasValid = Valid();
            var r = await SessionClient.FetchTicket();
            switch (r.Kind)
            {
                case SessionClient.ResultKind.Ticket: Ticket.Save(r.Ticket!); break;
                case SessionClient.ResultKind.Denied: Ticket.Clear(); break;
                case SessionClient.ResultKind.Unreachable: break;   // giữ nguyên vé cũ còn hạn
            }
            if (wasValid && !Valid()) App.RunOnUI(() => onLostAccess?.Invoke());
        }
        finally { refreshLock.Release(); }
    }

    void Schedule()
    {
        poll?.Cancel();
        poll = new CancellationTokenSource();
        var ct = poll.Token;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                var wait = Valid() ? RecheckOK : RecheckWaiting;
                try { await Task.Delay(wait, ct); } catch (TaskCanceledException) { return; }
                if (ct.IsCancellationRequested) return;
                await Refresh();
            }
        }, ct);
    }
}
