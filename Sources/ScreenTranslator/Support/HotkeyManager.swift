import Foundation
import Carbon
import AppKit

/// Phím tắt toàn cục bằng Carbon RegisterEventHotKey: không cần quyền Accessibility, hoạt động cả khi game fullscreen.
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Action: UInt32, CaseIterable { case toggle = 1, analyze, voice, overlay }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().fire(hk.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        if status != noErr { Log.error("InstallEventHandler failed: \(status)") }
    }

    @discardableResult
    func register(_ action: Action, combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5354_5231), id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.warn("Hotkey \(combo.display) for \(action) failed: \(status)")
            return false
        }
        refs[action.rawValue] = ref
        actions[action.rawValue] = handler
        Log.info("Hotkey \(combo.display) → \(action)")
        return true
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(ref) }
        actions.removeValue(forKey: action.rawValue)
    }

    func unregisterAll() { for a in Action.allCases { unregister(a) } }

    private func fire(_ id: UInt32) {
        guard let a = actions[id] else { return }
        Task { @MainActor in a() }
    }
}
