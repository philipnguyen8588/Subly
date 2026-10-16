import SwiftUI

/// Phủ lên nội dung màn hình chính khi PS5 mất kết nối và app đang tự kết nối lại.
struct ReconnectOverlay: View {
    @ObservedObject var reconnector = PS5Reconnector.shared
    @ObservedObject var stream = PS5Stream.shared
    @State private var pin = ""

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.55)).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Mất kết nối PS5").font(.title2.weight(.bold))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(line(now: ctx.date)).font(.callout.weight(.medium)).monospacedDigit()
                }
                if !reconnector.lastError.isEmpty {
                    Text(reconnector.lastError).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(3).frame(maxWidth: 380)
                }
                if case .needsPin = stream.state {
                    HStack {
                        SecureField("Mã PIN đăng nhập PS5", text: $pin).textFieldStyle(.roundedBorder).frame(width: 200)
                        Button("Gửi") { stream.sendPin(pin); pin = "" }.disabled(pin.isEmpty).appButton(.primary)
                    }
                }
                HStack(spacing: 10) {
                    Button { reconnector.retryNow() } label: { Label("Thử ngay", systemImage: "arrow.clockwise") }
                        .appButton(.secondary, fill: true)
                        .disabled(reconnector.nextRetryAt == nil)
                    Button { AppNav.shared.leaveToStart(reason: "Đã dừng tự kết nối lại PS5.") } label: {
                        Label("Về màn hình bắt đầu", systemImage: "chevron.left")
                    }
                    .appButton(.danger, fill: true)
                }
                .frame(width: 400)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 20)
        }
    }

    private func line(now: Date) -> String {
        let n = "lần \(max(1, reconnector.attempt))/\(reconnector.maxAttempts)"
        if let at = reconnector.nextRetryAt {
            let s = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
            return reconnector.attempt == 0 ? "Tự kết nối lại sau \(s) giây…" : "Lần \(reconnector.attempt) chưa được. Thử lại sau \(s) giây…"
        }
        return "Đang kết nối lại (\(n)): \(stream.state.label)"
    }
}
