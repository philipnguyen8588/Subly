import AppKit
import SwiftUI

struct OverlayStyle {
    var fontSize: Double = 22
    var opacity: Double = 0.7
    var showSource = true
    var maxWidth: Double = 900
    var position: OverlayPosition = .belowRegion
    var hideAfter: Double = 6
}

final class OverlayModel: ObservableObject {
    @Published var translated = ""
    @Published var source = ""
    @Published var style = OverlayStyle()
}

/// Panel không nhận chuột, nổi trên mọi thứ kể cả app fullscreen.
@MainActor
final class SubtitleOverlay {
    private let panel: NSPanel
    private let model = OverlayModel()
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
    }

    func show(translated: String, source: String, near region: Region?, style: OverlayStyle) {
        model.style = style
        model.translated = translated
        model.source = style.showSource ? source : ""
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 600, height: 80)

        let primaryH = NSScreen.screens[0].frame.maxY
        let nsRegion: NSRect
        if let region {
            let cur = WindowFinder.currentRect(of: region)
            nsRegion = NSRect(x: cur.minX, y: primaryH - cur.maxY, width: cur.width, height: cur.height)
        } else {
            nsRegion = NSScreen.main?.frame ?? NSScreen.screens[0].frame
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(nsRegion) } ?? NSScreen.main ?? NSScreen.screens[0]
        let w = min(max(size.width, 300), screen.visibleFrame.width - 40)
        var x: CGFloat
        var y: CGFloat
        switch (region == nil ? .screenBottom : style.position) {
        case .belowRegion:
            x = nsRegion.midX - w / 2
            y = nsRegion.minY - size.height - 8
            if y < screen.frame.minY + 10 { y = nsRegion.maxY + 8 }
        case .aboveRegion:
            x = nsRegion.midX - w / 2
            y = nsRegion.maxY + 8
            if y + size.height > screen.frame.maxY - 10 { y = nsRegion.minY - size.height - 8 }
        case .screenBottom:
            x = screen.frame.midX - w / 2
            y = screen.frame.minY + 40
        }
        x = max(screen.frame.minX + 20, min(x, screen.frame.maxX - w - 20))
        panel.setFrame(NSRect(x: x, y: y, width: w, height: size.height), display: true)
        panel.orderFrontRegardless()

        hideTask?.cancel()
        if style.hideAfter > 0 {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(style.hideAfter * 1_000_000_000))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    /// Thông báo ngắn ở đáy màn hình (ví dụ "Đang phân tích…").
    func hud(_ text: String, seconds: Double = 2) {
        var s = OverlayStyle()
        s.fontSize = 16; s.showSource = false; s.hideAfter = seconds; s.position = .screenBottom
        show(translated: text, source: "", near: nil, style: s)
    }

    func hide() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(SpeakerColors.styled(model.translated, size: model.style.fontSize, weight: .semibold, onDark: true))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
            if !model.source.isEmpty {
                Text(model.source)
                    .font(.system(size: max(11, model.style.fontSize * 0.55)))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .frame(maxWidth: model.style.maxWidth, alignment: .center)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(model.style.opacity), in: RoundedRectangle(cornerRadius: 12))
        .padding(4)
    }
}
