import SwiftUI
import AppKit

/// Hỏi email lần đầu mở app (bản phát hành). Email gửi kèm lên server để chủ app biết máy của ai khi duyệt.
struct EmailPromptView: View {
    let onDone: () -> Void
    @ObservedObject var settings = AppSettings.shared
    @State private var email = AppSettings.shared.userEmail
    @FocusState private var focused: Bool

    private var valid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard let at = e.firstIndex(of: "@"), at != e.startIndex else { return false }
        let domain = e[e.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !e.contains(" ")
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge").font(.system(size: 40)).foregroundStyle(Theme.accentGradient)
            Text("Nhập email của bạn").font(.title3.weight(.semibold))
            Text("Nhập email để đăng ký dùng thử app.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            TextField("ban@example.com", text: $email)
                .textFieldStyle(.roundedBorder).frame(width: 280).focused($focused)
                .onSubmit { if valid { save() } }
            Button("Tiếp tục", action: save)
                .buttonStyle(.borderedProminent).disabled(!valid).keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(width: 460, height: 320)
        .onAppear { focused = true }
    }

    private func save() {
        settings.userEmail = email.trimmingCharacters(in: .whitespaces)
        onDone()
    }
}
