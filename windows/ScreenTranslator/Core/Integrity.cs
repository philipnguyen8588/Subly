using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Vài lớp làm khó việc can thiệp lúc chạy. Chỉ bật ở bản phát hành (có cấu hình server);
/// bản dev (không có subly.local.env) bỏ qua để còn gỡ lỗi được. Không phải chống phá tuyệt đối —
/// khoá thật nằm ở server duyệt máy. Tương đương Integrity.swift của bản macOS (ở đó là PT_DENY_ATTACH
/// + kiểm chữ ký); trên Windows là chống gắn debugger.
public static class Integrity
{
    [DllImport("kernel32.dll")] static extern bool IsDebuggerPresent();
    [DllImport("kernel32.dll")] static extern bool CheckRemoteDebuggerPresent(IntPtr hProcess, ref bool pbDebuggerPresent);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

    /// Gọi sớm lúc khởi động bản phát hành.
    public static void Arm()
    {
        if (!RuntimeConfig.Enabled) return;
        if (DebuggerAttached())
        {
            // Đang bị gắn debugger (soi/sửa lúc chạy) → dừng, không nêu lý do.
            Environment.Exit(0);
        }
        // Kiểm tra lại định kỳ: ai gắn debugger sau khi app đã mở cũng bị dừng.
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(30)); } catch { return; }
                if (DebuggerAttached()) Environment.Exit(0);
            }
        });
    }

    static bool DebuggerAttached()
    {
        if (Debugger.IsAttached || IsDebuggerPresent()) return true;
        bool remote = false;
        try { if (CheckRemoteDebuggerPresent(GetCurrentProcess(), ref remote) && remote) return true; } catch { }
        return false;
    }
}
