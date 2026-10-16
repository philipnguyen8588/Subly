import Foundation

/// Tự kết nối lại PS5 khi đang chơi mà mất kết nối (bật/tắt ở màn Bắt đầu và Cài đặt → Capture & OCR).
/// Đang thử thì màn hình chính hiện lớp phủ (ReconnectOverlay); hết lượt thử hoặc tắt tính năng thì về màn Bắt đầu.
@MainActor
final class PS5Reconnector: ObservableObject {
    static let shared = PS5Reconnector()

    @Published private(set) var active = false
    /// Lần thử hiện tại (1…maxAttempts); 0 = chưa thử lần nào.
    @Published private(set) var attempt = 0
    /// Thời điểm thử lại kế tiếp; nil = đang thử.
    @Published private(set) var nextRetryAt: Date?
    @Published private(set) var lastError = ""

    /// Cờ test (--simulate-ps5-drop): không kết nối thật, mỗi lần thử tự báo lỗi sau 1 giây.
    var simulate = false

    private var resumeTranslation = false
    private var timer: Task<Void, Never>?
    private static let delays: [Double] = [3, 5, 10, 15]

    var maxAttempts: Int { max(1, AppSettings.shared.ps5ReconnectAttempts) }

    /// Phiên PS5 đang chơi vừa rớt (hoặc một lần thử lại vừa thất bại).
    func connectionLost(_ reason: String, wasTranslating: Bool) {
        guard AppSettings.shared.ps5AutoReconnect else {
            AppNav.shared.leaveToStart(reason: "Mất kết nối PS5: \(reason)")
            return
        }
        if !active {
            active = true
            attempt = 0
            resumeTranslation = wasTranslating
            Log.info("PS5: mất kết nối (\(reason)) → tự kết nối lại")
        }
        lastError = reason
        scheduleNext()
    }

    private func scheduleNext() {
        timer?.cancel()
        guard attempt < maxAttempts else {
            let n = attempt, err = lastError   // cancel() xoá lastError
            cancel()
            AppNav.shared.leaveToStart(reason: "Không kết nối lại được PS5 sau \(n) lần thử: \(err)")
            return
        }
        let delay = Self.delays[min(attempt, Self.delays.count - 1)]
        nextRetryAt = Date().addingTimeInterval(delay)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryNow()
        }
    }

    /// Nút "Thử ngay" hoặc hết giờ chờ.
    func retryNow() {
        guard active else { return }
        timer?.cancel()
        nextRetryAt = nil
        attempt += 1
        Log.info("PS5: thử kết nối lại lần \(attempt)/\(maxAttempts)")
        if simulate {
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.active else { return }
                self.connectionLost("Giả lập: PS5 không trả lời", wasTranslating: false)
            }
        } else {
            PS5Coordinator.connect()
        }
    }

    /// Có hình trở lại: tắt lớp phủ, dịch tiếp nếu trước đó đang dịch.
    func streamingResumed() {
        guard active else { return }
        let resume = resumeTranslation
        Log.info("PS5: đã kết nối lại sau \(attempt) lần thử")
        cancel()
        if resume { Task { await Pipeline.shared.start() } }
    }

    func cancel() {
        timer?.cancel(); timer = nil
        active = false
        attempt = 0
        nextRetryAt = nil
        lastError = ""
        resumeTranslation = false
    }
}
