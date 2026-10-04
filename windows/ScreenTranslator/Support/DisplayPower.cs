using System;
using System.Windows.Threading;

namespace ScreenTranslator;

/// Tắt màn hình để tiết kiệm điện trong khi app vẫn dịch + đọc. Di chuột / gõ phím thì Windows tự bật lại.
public sealed class DisplayPower
{
    public static readonly DisplayPower shared = new();
    DispatcherTimer? watch;
    uint inputAtSleep;

    /// Tắt màn hình sau `delay` giây (để tay kịp rời chuột; chuột còn rung là màn hình bật lại ngay).
    public void SleepDisplay(double delay = 2)
    {
        Pipeline.shared.overlay.Hud($"Tắt màn hình sau {(int)delay} giây. Di chuột hoặc gõ phím để bật lại.", delay);
        // Màn hình tắt thì máy dễ tự ngủ → giữ máy thức tới khi màn hình bật lại, để phiên PS5, dịch và giọng đọc không bị ngắt.
        Win32.SetThreadExecutionState(Win32.ES_CONTINUOUS | Win32.ES_SYSTEM_REQUIRED);
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(delay) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            Pipeline.shared.overlay.Hide();
            try
            {
                Win32.PostMessage(Win32.HWND_BROADCAST, Win32.WM_SYSCOMMAND, new IntPtr(Win32.SC_MONITORPOWER), new IntPtr(2));
                Log.Info("Tắt màn hình (SC_MONITORPOWER), giữ máy thức");
            }
            catch (Exception e) { Log.Error($"Không tắt được màn hình: {e.Message}"); DidWake(); return; }
            inputAtSleep = LastInput();
            watch?.Stop();
            watch = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            watch.Tick += (_, _) => { if (LastInput() != inputAtSleep) DidWake(); };
            watch.Start();
        };
        t.Start();
    }

    static uint LastInput()
    {
        var li = new Win32.LASTINPUTINFO { cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Win32.LASTINPUTINFO>() };
        Win32.GetLastInputInfo(ref li);
        return li.dwTime;
    }

    void DidWake()
    {
        watch?.Stop(); watch = null;
        Win32.SetThreadExecutionState(Win32.ES_CONTINUOUS | (Pipeline.shared.isRunning ? Win32.ES_SYSTEM_REQUIRED : 0));
        Log.Info("Màn hình bật lại");
    }
}
