import SwiftUI

/// Mục "Hỏi đáp" của tab Cốt truyện: gõ câu hỏi về cốt truyện (vd. "Iron Kingdom có những ai?"), app trả lời
/// chỉ dựa trên cốt truyện, nhân vật, bách khoa và phụ đề đã ghi lại của game đang chọn.
struct StoryChatView: View {
    @ObservedObject var chat = StoryChat.shared
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var draft = ""
    @FocusState private var focused: Bool
    private static let bottomID = "story-chat-bottom"

    private var suggestions: [String] {
        var out = ["Tóm tắt cốt truyện đến hiện tại", "Nhân vật chính là ai?", "Ai đang đồng hành cùng nhân vật chính?"]
        let lore = store.story?.lore ?? []
        if let f = lore.first(where: { $0.kind == "faction" }) { out.append("\(f.name) có những ai?") }
        if let p = lore.first(where: { $0.kind == "place" }) { out.append("\(p.name) là nơi nào?") }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if chat.turns.isEmpty { intro }
                        ForEach(chat.turns) { t in turn(t) }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(14)
                }
                .onChange(of: chat.turns) { _, _ in
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            Divider()
            inputBar
        }
        .onAppear { focused = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hỏi về cốt truyện “\(settings.activeProfile.name)”", systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: 14, weight: .semibold))
            Text("App trả lời dựa trên cốt truyện, nhân vật, bách khoa và phụ đề đã ghi lại của game này: chỉ những gì bạn đã chơi tới, không tiết lộ trước. Mỗi câu hỏi dùng một lượt AI (engine của “Tóm tắt & cốt truyện”).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.story == nil {
                Text("Game này chưa có cốt truyện: app chỉ tìm được trong phụ đề nên câu trả lời sẽ sơ sài.")
                    .font(.caption).foregroundStyle(.orange)
            }
            FlowLayout(spacing: 6) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        Text(s).font(.system(size: 12.5))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(chat.isRunning)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentStart.opacity(0.06)))
    }

    private func turn(_ t: StoryChat.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 60)
                Text(t.question)
                    .font(.system(size: 13.5)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accentGradient))
            }
            HStack(alignment: .top) {
                answer(t)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private func answer(_ t: StoryChat.Turn) -> some View {
        if let a = t.answer {
            VStack(alignment: .leading, spacing: 8) {
                Text(a).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let b = t.backend {
                        Text("\(b.label) · \(String(format: "%.1f", Double(t.ms) / 1000))s").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button { Clipboard.copy(a) } label: { Image(systemName: "doc.on.doc").font(.caption) }
                        .buttonStyle(.borderless).help("Copy")
                }
            }
        } else if let err = t.error {
            Label(err, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Đang tìm trong cốt truyện…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Hỏi về cốt truyện, vd. Iron Kingdom có những ai?", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 13.5))
                .focused($focused)
                .onSubmit { send(draft) }
                .padding(.horizontal, 12).frame(height: 36)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: AppButtonStyle.radius))
                .overlay(RoundedRectangle(cornerRadius: AppButtonStyle.radius).strokeBorder(Theme.controlStroke))
            Button { send(draft) } label: {
                if chat.isRunning { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane.fill") }
            }
            .appButton(.primary)
            .disabled(chat.isRunning || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Gửi câu hỏi (Enter)")
            if !chat.turns.isEmpty {
                Button { chat.clear() } label: { Image(systemName: "trash") }
                    .appIconButton().disabled(chat.isRunning).help("Xoá hội thoại")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func send(_ text: String) {
        guard !chat.isRunning, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.ask(text)
        draft = ""
        focused = true
    }
}
