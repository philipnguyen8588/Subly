import SwiftUI
import AppKit

/// Phím điều hướng của tab Nhật ký. Mục đang xem đăng ký một hàm xử lý; phím được bắt bằng NSEvent local monitor nên
/// không cần view nào giữ focus. Bỏ qua khi đang gõ chữ (ô tìm kiếm…), khi giữ ⌘ / ⌥ / ⌃, và khi đang mở ảnh dịch
/// màn hình (modal đó tự dùng ←/→/Esc).
@MainActor
final class LogKeys {
    static let shared = LogKeys()
    enum Key { case up, down, left, right, pageUp, pageDown, home, end, toggle }

    private var monitor: Any?
    private var handler: (id: UUID, run: (Key) -> Bool)?

    /// Mục vừa hiện ra đăng ký; mục cũ có thể huỷ đăng ký sau đó nên phải so `id` để không xoá nhầm của mục mới.
    func register(_ id: UUID, _ run: @escaping (Key) -> Bool) {
        handler = (id, run)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { LogKeys.shared.handle(event) ? nil : event }
        }
    }

    func unregister(_ id: UUID) { if handler?.id == id { handler = nil } }

    private func handle(_ e: NSEvent) -> Bool {
        guard let h = handler, ShotViewer.shared.currentID == nil,
              e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let w = e.window, w.isKeyWindow, w.attachedSheet == nil, !(w.firstResponder is NSText),
              let key = Self.key(e.keyCode) else { return false }
        return h.run(key)
    }

    private static func key(_ code: UInt16) -> Key? {
        switch code {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .home
        case 119: return .end
        case 49, 36, 76: return .toggle      // Space, Return, Enter
        default: return nil
        }
    }
}

/// Cuộn mượt một ScrollView bằng ↑/↓ (từng đoạn ngắn), Page Up/Down (gần một màn hình), Home/End.
/// Gắn vào ScrollView bằng `.keyScroll($scroller)`.
struct KeyScroller {
    struct Metrics: Equatable { var offset: CGFloat = 0, viewport: CGFloat = 0, content: CGFloat = 0 }
    var position = ScrollPosition()
    var metrics = Metrics()

    /// Trả về false nếu phím không phải phím cuộn.
    mutating func scroll(_ key: LogKeys.Key) -> Bool {
        let page = max(100, metrics.viewport * 0.85)
        let step: CGFloat
        switch key {
        case .up: step = -80
        case .down: step = 80
        case .pageUp: step = -page
        case .pageDown: step = page
        case .home: step = -.greatestFiniteMagnitude
        case .end: step = .greatestFiniteMagnitude
        default: return false
        }
        let maxY = max(0, metrics.content - metrics.viewport)
        let target = min(maxY, max(0, metrics.offset + step))
        // Ghi luôn vị trí đích để giữ phím (lặp phím) cộng dồn mượt, không chờ ScrollView báo lại.
        metrics.offset = target
        withAnimation(.easeOut(duration: 0.16)) { position.scrollTo(y: target) }
        return true
    }
}

extension View {
    func keyScroll(_ scroller: Binding<KeyScroller>) -> some View {
        scrollPosition(scroller.position)
            .onScrollGeometryChange(for: KeyScroller.Metrics.self) {
                KeyScroller.Metrics(offset: $0.contentOffset.y, viewport: $0.containerSize.height, content: $0.contentSize.height)
            } action: { _, m in scroller.wrappedValue.metrics = m }
    }

    /// Đăng ký xử lý phím khi view hiện, huỷ khi view ẩn.
    func logKeys(_ id: UUID, _ run: @escaping (LogKeys.Key) -> Bool) -> some View {
        onAppear { LogKeys.shared.register(id, run) }
            .onDisappear { LogKeys.shared.unregister(id) }
    }
}

/// Chọn phần tử kế tiếp / trước đó trong một danh sách theo phím ←/→ (đi quá đầu / cuối thì dừng ở đó).
func stepSelection<ID: Equatable>(_ ids: [ID], current: ID?, by delta: Int) -> ID? {
    guard !ids.isEmpty else { return nil }
    guard let c = current, let i = ids.firstIndex(of: c) else { return delta >= 0 ? ids.first : ids.last }
    return ids[min(ids.count - 1, max(0, i + delta))]
}
