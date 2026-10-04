using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace ScreenTranslator;

/// Ô ghi phím tắt: bấm vào rồi nhấn tổ hợp mới (cần Ctrl, Alt hoặc Win). Esc để huỷ.
public sealed class KeyRecorder : Button
{
    readonly Func<KeyCombo> get;
    readonly Action<KeyCombo> set;
    bool recording;

    public KeyRecorder(Func<KeyCombo> get, Action<KeyCombo> set)
    {
        this.get = get; this.set = set;
        MinWidth = 150;
        Focusable = true;
        Refresh();
        Click += (_, _) => { recording = true; HotkeyManager.shared.Suspend(); Refresh(); Focus(); };
        LostKeyboardFocus += (_, _) => { if (recording) { recording = false; HotkeyManager.shared.Apply(); Refresh(); } };
        PreviewKeyDown += OnKey;
    }

    void Refresh()
    {
        Content = recording ? "Nhấn tổ hợp phím…" : get().display;
        Background = recording ? new SolidColorBrush(Color.FromArgb(51, 97, 111, 250)) : Brushes.White;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (!recording) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape) { recording = false; HotkeyManager.shared.Apply(); Refresh(); return; }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        var m = Keyboard.Modifiers;
        uint mods = 0;
        if (m.HasFlag(ModifierKeys.Control)) mods |= KeyCombo.Control;
        if (m.HasFlag(ModifierKeys.Alt)) mods |= KeyCombo.Alt;
        if (m.HasFlag(ModifierKeys.Shift)) mods |= KeyCombo.Shift;
        if (m.HasFlag(ModifierKeys.Windows)) mods |= KeyCombo.Win;
        if ((mods & (KeyCombo.Control | KeyCombo.Alt | KeyCombo.Win)) == 0) return;   // cần Ctrl, Alt hoặc Win
        var vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        recording = false;
        set(new KeyCombo(vk, mods));
        HotkeyManager.shared.Apply();
        Refresh();
    }
}
