import SwiftUI

/// Ô tìm dùng chung: chữ đang gõ chỉ được đưa vào `text` (và chạy tìm) sau khi ngừng gõ `delay` giây.
/// Enter hoặc nút xoá áp dụng ngay. Gõ liên tục thì không tìm, tránh lọc lại danh sách dài sau mỗi phím.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var size: CGFloat = 13
    var height: CGFloat = 36
    var delay: Duration = .milliseconds(700)
    var focus: FocusState<Bool>.Binding? = nil

    @State private var draft = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var ownFocus: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: size)).foregroundStyle(.tertiary)
            field
            if !draft.isEmpty {
                Button { draft = ""; apply() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Xoá ô tìm")
            }
        }
        .padding(.horizontal, 10).frame(height: height)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: AppButtonStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: AppButtonStyle.radius).strokeBorder(Theme.controlStroke))
        .onAppear { draft = text }
        // Ô tìm bị đặt lại từ nơi khác (đổi game, xoá…) → hiện đúng chữ đó.
        .onChange(of: text) { _, t in if t != draft { pending?.cancel(); draft = t } }
        .onChange(of: draft) { _, d in
            pending?.cancel()
            guard d != text else { return }
            pending = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                apply()
            }
        }
        .onDisappear { pending?.cancel() }
    }

    @ViewBuilder private var field: some View {
        let tf = TextField(prompt, text: $draft).textFieldStyle(.plain).font(.system(size: size)).onSubmit(apply)
        if let focus { tf.focused(focus) } else { tf.focused($ownFocus) }
    }

    private func apply() {
        pending?.cancel()
        if text != draft { text = draft }
    }
}
