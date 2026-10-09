import Foundation
import AppKit

/// Kiểm tra máy với server. Mô hình: app LUÔN mở bình thường; chỉ khi người dùng bấm Bắt đầu / Dịch màn hình
/// mới chặn nếu máy chưa được duyệt (hiện màn hình lỗi chung). Nền kiểm tra lại mỗi vài giờ; đang chạy mà mất
/// quyền thì dừng dịch. Người dùng không thấy thông tin gì về duyệt/hết hạn.
@MainActor
final class SessionCheck: ObservableObject {
    static let shared = SessionCheck()

    /// Khoảng kiểm tra ngầm.
    private let recheckOK: TimeInterval = 3 * 3600      // đã có vé: vài giờ một lần
    private let recheckWaiting: TimeInterval = 120      // chưa có vé: thử lại thường xuyên hơn để bắt được lúc vừa duyệt

    private var onLostAccess: (() -> Void)?
    private var poll: Task<Void, Never>?

    func begin(onLostAccess: @escaping () -> Void) {
        self.onLostAccess = onLostAccess
        guard RuntimeConfig.enabled else { return }
        Task { await refresh() }
        schedule()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Kiểm tra nhanh bằng vé đã lưu (không gọi mạng). Dùng ở các bước dịch để im lặng ngừng khi mất quyền.
    func valid() -> Bool {
        guard RuntimeConfig.enabled else { return true }
        return Ticket.current()?.looksValid ?? false
    }

    /// Gọi khi người dùng CHỦ ĐỘNG dùng tính năng (bấm Bắt đầu / Dịch màn hình).
    /// Có vé hợp lệ → true. Chưa có → hỏi server một lần; vẫn không → hiện lỗi chung và trả false.
    func authorizeAction() async -> Bool {
        guard RuntimeConfig.enabled else { return true }
        if valid() { return true }
        await refresh()
        if valid() { return true }
        WindowManager.shared.showStartupError()
        return false
    }

    /// Hỏi server, cập nhật vé. Đang chạy mà sau khi hỏi thấy mất quyền → gọi onLostAccess.
    func refresh() async {
        let wasValid = valid()
        switch await SessionClient.fetchTicket() {
        case .ticket(let raw): Ticket.save(raw)
        case .denied: Ticket.clear()
        case .unreachable: break        // giữ nguyên vé cũ còn hạn
        }
        if wasValid, !valid() { onLostAccess?() }
    }

    private func schedule() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let wait = (self?.valid() == true ? self?.recheckOK : self?.recheckWaiting) ?? 3600
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }
}
