import SwiftUI

/// Thêm tên nhân vật từ một câu trong nhật ký: bấm chọn các từ tạo thành tên (dùng cho tên dài / lạ app không tự nhận ra,
/// ví dụ "Charles, Botanist This tun here…" → "Charles, Botanist").
struct AddSpeakerSheet: View {
    struct Item: Identifiable {
        let id = UUID()
        let source: String
    }

    let source: String
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var range: ClosedRange<Int>?
    @State private var name = ""
    @FocusState private var focused: Bool

    /// Các từ đầu câu (tên luôn nằm ở đầu câu phụ đề).
    private var words: [String] { Array(source.split(separator: " ").prefix(14).map(String.init)) }

    private var cleanName: String {
        name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-–—!?\""))
            .trimmingCharacters(in: .whitespaces)
    }
    private var exists: Bool { settings.speakers.contains { $0.lowercased() == cleanName.lowercased() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Thêm tên nhân vật", systemImage: "person.crop.circle.badge.plus").font(.title3.weight(.semibold))
            Text("Bấm từ đầu và từ cuối của tên. Có thể sửa trực tiếp trong ô bên dưới.")
                .font(.callout).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    let on = range?.contains(i) ?? false
                    Button { tap(i) } label: {
                        Text(w).font(.system(size: 14, weight: on ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.07))))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if source.split(separator: " ").count > words.count { Text("…").foregroundStyle(.tertiary).padding(.vertical, 4) }
            }
            HStack {
                Text("Tên:").font(.callout.weight(.medium))
                TextField("Tên nhân vật", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(add)
            }
            if exists {
                Label("Tên này đã có trong danh sách nhân vật của game.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            } else if !settings.showsSpeakerNames {
                Label("Game này đang tắt “hiện tên người nói”; thêm tên sẽ bật lại.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Áp dụng cho các câu sau; câu cũ trong nhật ký giữ nguyên.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Thêm", action: add).buttonStyle(GradientButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
                    .disabled(cleanName.isEmpty || exists)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: guess)
    }

    /// Lần bấm đầu chọn một từ; các lần sau nới vùng chọn tới từ được bấm (bấm lại từ đã chọn ở mép → thu lại một từ).
    private func tap(_ i: Int) {
        if let r = range {
            if r.count > 1, i == r.upperBound { range = r.lowerBound...(i - 1) }
            else if r.count > 1, i == r.lowerBound { range = (i + 1)...r.upperBound }
            else if r == i...i { range = nil }
            else { range = min(r.lowerBound, i)...max(r.upperBound, i) }
        } else {
            range = i...i
        }
        name = range.map { words[$0].joined(separator: " ") } ?? ""
        name = cleanName
    }

    /// Đoán sẵn: chuỗi từ Viết Hoa ở đầu câu, bỏ từ cuối nếu nó là chữ đầu câu thoại ("Charles, Botanist This tun…").
    private func guess() {
        var n = 0
        for w in words {
            guard let f = w.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) || ["of", "the", "de", "von", "van"].contains(w.lowercased()) else { break }
            n += 1
            if w.hasSuffix(":") { break }
        }
        if n >= 2, !words[n - 1].hasSuffix(":") { n -= 1 }
        if n >= 1 { range = 0...(n - 1); name = words[0..<n].joined(separator: " "); name = cleanName }
    }

    private func add() {
        let n = cleanName
        guard !n.isEmpty, !exists else { return }
        if !settings.showsSpeakerNames { settings.showsSpeakerNames = true }
        settings.learnSpeaker(n)
        dismiss()
    }
}

/// Xếp các phần tử thành hàng, hết chỗ thì xuống dòng (như chữ trong đoạn văn).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (i, x) in zip(row.indices, row.xs) {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var indices: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width > 0, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            let x = r.width > 0 ? r.width + spacing : 0
            r.indices.append(i); r.xs.append(x)
            r.width = x + size.width; r.height = max(r.height, size.height)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
