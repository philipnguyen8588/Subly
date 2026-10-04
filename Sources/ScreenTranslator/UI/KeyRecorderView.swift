import SwiftUI
import AppKit

/// Nút hiện tổ hợp phím; bấm vào rồi nhấn tổ hợp mới để ghi.
struct KeyRecorderView: View {
    @Binding var combo: KeyCombo
    @State private var recording = false

    var body: some View {
        ZStack {
            KeyCaptureView(isActive: recording) { c in
                combo = c
                recording = false
            } onCancel: { recording = false }
            .frame(width: 0, height: 0)
            Button {
                recording.toggle()
            } label: {
                Text(recording ? "Nhấn tổ hợp phím…" : combo.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
        }
    }
}

struct KeyCaptureView: NSViewRepresentable {
    var isActive: Bool
    var onKey: (KeyCombo) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let v = CaptureNSView()
        v.onKey = onKey
        v.onCancel = onCancel
        return v
    }
    func updateNSView(_ v: CaptureNSView, context: Context) {
        v.onKey = onKey
        v.onCancel = onCancel
        if isActive {
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        } else if v.window?.firstResponder === v {
            v.window?.makeFirstResponder(nil)
        }
    }

    final class CaptureNSView: NSView {
        var onKey: ((KeyCombo) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }   // Esc
            var mods: UInt32 = 0
            let f = event.modifierFlags
            if f.contains(.command) { mods |= KeyCombo.cmd }
            if f.contains(.option) { mods |= KeyCombo.option }
            if f.contains(.shift) { mods |= KeyCombo.shift }
            if f.contains(.control) { mods |= KeyCombo.control }
            guard mods & (KeyCombo.cmd | KeyCombo.option | KeyCombo.control) != 0 else {
                NSSound.beep(); return
            }
            onKey?(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
        }
        override func resignFirstResponder() -> Bool { onCancel?(); return true }
    }
}
