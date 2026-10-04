import AppKit
import SwiftUI
import Combine

/// Hiện khung của vùng ngay trên màn hình: kéo trong khung để di chuyển, kéo mép/góc để đổi kích thước.
@MainActor
final class RegionEditor: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RegionEditor()

    @Published private(set) var visible: Set<UUID> = []
    private var panels: [UUID: RegionFramePanel] = [:]
    private var commitWork: [UUID: DispatchWorkItem] = [:]

    func isVisible(_ id: UUID) -> Bool { visible.contains(id) }

    func toggle(_ region: Region) {
        if isVisible(region.id) { hide(region.id) } else { show(region) }
    }

    func show(_ region: Region) {
        guard !region.embedded else { return }   // vùng PS5 nhúng chỉnh ngay trong tab PS5
        hide(region.id)
        let cg = WindowFinder.currentRect(of: region)
        let primaryH = NSScreen.screens[0].frame.maxY
        let frame = NSRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
        let p = RegionFramePanel(regionID: region.id, frame: frame)
        p.delegate = self
        let model = RegionFrameModel(name: region.name, kind: region.kind, size: frame.size)
        p.model = model
        p.contentView = NSHostingView(rootView: RegionFrameView(
            model: model,
            onDrag: { [weak p] corner, ended in p?.drag(corner: corner, ended: ended) },
            onClose: { [weak self] in self?.hide(region.id) }))
        p.orderFrontRegardless()
        panels[region.id] = p
        visible.insert(region.id)
    }

    func hide(_ id: UUID) {
        commitWork[id]?.perform(); commitWork[id]?.cancel(); commitWork[id] = nil
        if let p = panels.removeValue(forKey: id) { p.delegate = nil; p.orderOut(nil) }
        visible.remove(id)
    }

    func hideAll() { for id in Array(panels.keys) { hide(id) } }

    func showAll(_ regions: [Region]) { for r in regions { show(r) } }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { changed(notification) }
    func windowDidResize(_ notification: Notification) { changed(notification) }

    private func changed(_ n: Notification) {
        guard let p = n.object as? RegionFramePanel else { return }
        p.model?.size = p.frame.size
        let id = p.regionID
        commitWork[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.commit(id) }
        commitWork[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)   // gom các thay đổi khi đang kéo
    }

    /// Ghi khung mới vào cài đặt (toạ độ CG), tính lại offset theo cửa sổ bên dưới, khởi động lại capture nếu đang chạy.
    private func commit(_ id: UUID) {
        commitWork[id] = nil
        guard let p = panels[id] else { return }
        let settings = AppSettings.shared
        guard let i = settings.regions.firstIndex(where: { $0.id == id }) else { return }
        let primaryH = NSScreen.screens[0].frame.maxY
        let f = p.frame
        let cg = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height).integral
        var r = settings.regions[i]
        guard r.rect != cg || r.winOffsetX == nil else { return }
        r.rect = cg
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) }),
           let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            r.displayID = did
        }
        if r.appBundleID != nil || r.winOffsetX != nil {
            let mode = r.appMode
            RegionActions.attachWindow(&r)     // cập nhật app/cửa sổ/offset theo vị trí mới
            r.appMode = mode
        }
        settings.regions[i] = r
        Log.info("Vùng '\(r.name)' → \(Int(cg.minX)),\(Int(cg.minY)) \(Int(cg.width))×\(Int(cg.height))")
        RegionPreviewProvider.shared.refreshNow()
        if r.kind == .subtitle { Pipeline.shared.restartIfRunning() }
    }
}

final class RegionFrameModel: ObservableObject {
    @Published var name: String
    @Published var size: CGSize
    let kind: RegionKind
    init(name: String, kind: RegionKind, size: CGSize) { self.name = name; self.kind = kind; self.size = size }
}

final class RegionFramePanel: NSPanel {
    let regionID: UUID
    var model: RegionFrameModel?

    init(regionID: UUID, frame: NSRect) {
        self.regionID = regionID
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 80, height: 30)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(frame, display: true)
    }
    override var canBecomeKey: Bool { true }

    // Kéo thủ công theo vị trí chuột toàn cục (ổn định dù cửa sổ đang di chuyển dưới con trỏ).
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero
    private var dragging = false

    func drag(corner: Int?, ended: Bool) {
        if ended { dragging = false; return }
        let m = NSEvent.mouseLocation
        if !dragging { dragging = true; startMouse = m; startFrame = frame }
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        var f = startFrame
        if let c = corner {
            // góc theo toạ độ view: 0 trên-trái, 1 trên-phải, 2 dưới-trái, 3 dưới-phải
            if c == 0 || c == 2 { f.origin.x += dx; f.size.width -= dx } else { f.size.width += dx }
            if c == 0 || c == 1 { f.size.height += dy } else { f.origin.y += dy; f.size.height -= dy }
            if f.size.width < minSize.width {
                if c == 0 || c == 2 { f.origin.x = startFrame.maxX - minSize.width }
                f.size.width = minSize.width
            }
            if f.size.height < minSize.height {
                if c == 2 || c == 3 { f.origin.y = startFrame.maxY - minSize.height }
                f.size.height = minSize.height
            }
        } else {
            f.origin.x += dx; f.origin.y += dy
        }
        setFrame(f, display: true)
    }
}

struct RegionFrameView: View {
    @ObservedObject var model: RegionFrameModel
    let onDrag: (_ corner: Int?, _ ended: Bool) -> Void
    let onClose: () -> Void

    private var tint: Color { model.kind == .subtitle ? Theme.accentEnd : Theme.accentStart }

    private func dragGesture(_ corner: Int?) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in onDrag(corner, false) }
            .onEnded { _ in onDrag(corner, true) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // nền: kéo để di chuyển
            Rectangle().fill(tint.opacity(0.10))
                .contentShape(Rectangle())
                .gesture(dragGesture(nil))
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 5])).foregroundStyle(tint)
                .allowsHitTesting(false)
            // tay nắm 4 góc: kéo để đổi kích thước
            GeometryReader { g in
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(tint)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle().inset(by: -6))
                        .position(x: i % 2 == 0 ? 8 : g.size.width - 8, y: i < 2 ? 8 : g.size.height - 8)
                        .gesture(dragGesture(i))
                        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: model.kind == .subtitle ? "captions.bubble.fill" : "viewfinder")
                Text(model.name).fontWeight(.semibold).lineLimit(1)
                Text("\(Int(model.size.width)) × \(Int(model.size.height))").monospacedDigit().opacity(0.85)
                Text("· kéo để di chuyển, kéo góc để đổi cỡ").opacity(0.75).lineLimit(1)
                Button(action: onClose) {
                    Label("Xong", systemImage: "checkmark").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.white.opacity(0.25)))
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint, in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 22).padding(.top, 6)
            .fixedSize()
        }
    }
}
