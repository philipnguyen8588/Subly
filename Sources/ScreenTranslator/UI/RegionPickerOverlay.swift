import AppKit

/// Phủ mọi màn hình bằng cửa sổ trong suốt, người dùng kéo để vẽ vùng. Trả về rect theo toạ độ CG toàn cục.
@MainActor
final class RegionPicker {
    static let shared = RegionPicker()
    private var windows: [PickerWindow] = []
    private var completion: ((CGRect, CGDirectDisplayID)?) -> Void = { _ in }

    func begin(completion: @escaping ((CGRect, CGDirectDisplayID)?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        for screen in NSScreen.screens {
            let w = PickerWindow(screen: screen)
            w.onFinish = { [weak self] result in self?.finish(result) }
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    private func finish(_ result: (CGRect, CGDirectDisplayID)?) {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        completion(result)
    }
}

final class PickerWindow: NSWindow {
    var onFinish: (((CGRect, CGDirectDisplayID)?) -> Void)?
    private let displayID: CGDirectDisplayID

    init(screen: NSScreen) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.onFinish = { [weak self] rectInWindow in
            guard let self else { return }
            guard let r = rectInWindow else { self.onFinish?(nil); return }
            let screenRect = self.convertToScreen(r)          // gốc dưới-trái toàn cục
            let primaryH = NSScreen.screens[0].frame.maxY
            let cg = CGRect(x: screenRect.minX, y: primaryH - screenRect.maxY,
                            width: screenRect.width, height: screenRect.height)
            self.onFinish?((cg.integral, self.displayID))
        }
        contentView = v
        makeFirstResponder(v)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PickerView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let r = current {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.systemYellow.setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 2; p.stroke()
            let label = "\(Int(r.width)) × \(Int(r.height))"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            (label as NSString).draw(at: NSPoint(x: r.minX + 4, y: r.maxY + 4), withAttributes: attrs)
        } else {
            let hint = "Kéo chuột để chọn vùng phụ đề/text • Esc để huỷ"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white]
            let size = (hint as NSString).size(withAttributes: attrs)
            (hint as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.6), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = NSRect(origin: start!, size: .zero)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil }
        guard let r = current, r.width >= 20, r.height >= 10 else { needsDisplay = true; return }
        onFinish?(r)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
