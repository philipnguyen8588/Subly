import AppKit

/// Tắt màn hình để tiết kiệm điện trong khi app vẫn dịch + đọc. Di chuột / gõ phím thì macOS tự bật lại.
@MainActor
final class DisplayPower {
    static let shared = DisplayPower()
    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Tắt màn hình sau `delay` giây (để tay kịp rời chuột; chuột còn rung là màn hình bật lại ngay).
    func sleepDisplay(after delay: Double = 2) {
        Pipeline.shared.overlay.hud("Tắt màn hình sau \(Int(delay)) giây. Di chuột hoặc gõ phím để bật lại.", seconds: delay)
        // Màn hình tắt thì máy dễ tự ngủ → giữ máy thức tới khi màn hình bật lại, để phiên PS5, dịch và giọng đọc không bị ngắt.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Dịch phụ đề khi màn hình tắt")
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                                              object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.didWake() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            do { try p.run(); Log.info("Tắt màn hình (pmset displaysleepnow), giữ máy thức") }
            catch { Log.error("Không tắt được màn hình: \(error.localizedDescription)"); self.didWake() }
        }
    }

    private func didWake() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        Log.info("Màn hình bật lại")
    }
}
