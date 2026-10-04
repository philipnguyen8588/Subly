using System;
using System.Collections.Generic;
using System.Windows.Interop;

namespace ScreenTranslator;

/// Phím tắt toàn cục bằng RegisterHotKey (hoạt động cả khi game đang chạy toàn màn hình, không cần quyền đặc biệt).
public sealed class HotkeyManager
{
    public static readonly HotkeyManager shared = new();
    public enum HotkeyAction { toggle = 1, analyze = 2, voice = 3, overlay = 4 }

    HwndSource? source;
    readonly Dictionary<int, HotkeyAction> registered = new();
    public event System.Action<HotkeyAction>? Pressed;

    void EnsureWindow()
    {
        if (source != null) return;
        var p = new HwndSourceParameters("ScreenTranslatorHotkeys") { Width = 0, Height = 0, WindowStyle = 0, ParentWindow = new IntPtr(-3) /* HWND_MESSAGE */ };
        source = new HwndSource(p);
        source.AddHook((IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (msg == Win32.WM_HOTKEY && registered.TryGetValue(w.ToInt32(), out var a))
            {
                handled = true;
                Pressed?.Invoke(a);
            }
            return IntPtr.Zero;
        });
    }

    /// Đăng ký lại toàn bộ theo cài đặt. Trả về danh sách phím không đăng ký được (đã bị app khác chiếm).
    public List<string> Apply()
    {
        EnsureWindow();
        foreach (var id in registered.Keys) Win32.UnregisterHotKey(source!.Handle, id);
        registered.Clear();
        var failed = new List<string>();
        var s = AppSettings.shared;
        if (!s.hotkeysEnabled) return failed;
        void Reg(HotkeyAction a, KeyCombo k)
        {
            int id = (int)a;
            if (Win32.RegisterHotKey(source!.Handle, id, k.modifiers | Win32.MOD_NOREPEAT, k.keyCode)) registered[id] = a;
            else { failed.Add(k.display); Log.Warn($"Không đăng ký được phím tắt {k.display} (đã bị app khác dùng?)"); }
        }
        Reg(HotkeyAction.toggle, s.hotkeyToggle);
        Reg(HotkeyAction.analyze, s.hotkeyAnalyze);
        Reg(HotkeyAction.voice, s.hotkeyVoice);
        Reg(HotkeyAction.overlay, s.hotkeyOverlay);
        Log.Info($"Hotkeys: {s.hotkeyToggle.display} bật/tắt, {s.hotkeyAnalyze.display} dịch màn hình, {s.hotkeyVoice.display} voice, {s.hotkeyOverlay.display} overlay");
        return failed;
    }

    /// Tạm bỏ đăng ký (khi đang ghi phím mới trong Cài đặt).
    public void Suspend()
    {
        if (source == null) return;
        foreach (var id in registered.Keys) Win32.UnregisterHotKey(source.Handle, id);
        registered.Clear();
    }
}
