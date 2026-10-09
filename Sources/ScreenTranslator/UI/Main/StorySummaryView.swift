import SwiftUI

/// Mục "Tóm tắt" của tab Nhật ký: các bản tóm tắt cốt truyện người dùng đã tạo từ phụ đề, mới nhất trước.
struct StorySummaryView: View {
    let search: String
    let summaries: [StorySummary]
    @ObservedObject var summarizer = StorySummarizer.shared
    @State private var expanded: Set<Int64> = []
    @State private var pendingDelete: StorySummary?

    private var rows: [StorySummary] {
        guard !search.isEmpty else { return summaries }
        let q = search.lowercased()
        return summaries.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            if rows.isEmpty, !summarizer.isRunning {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.badge.star").font(.system(size: 30)).foregroundStyle(.quaternary)
                    Text(summaries.isEmpty
                         ? "Ở mục Phụ đề, chọn nhiều câu (kéo chuột, hoặc bấm một câu rồi Shift-bấm câu khác) và bấm Tóm tắt.\nBản tóm tắt của game này sẽ được lưu ở đây."
                         : "Không có bản tóm tắt nào khớp.")
                        .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if summarizer.isRunning {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Đang tóm tắt \(summarizer.runningCount) câu…").font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentStart.opacity(0.07)))
                        }
                        if let err = summarizer.lastError {
                            Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger)
                        }
                        ForEach(rows) { s in
                            StorySummaryCard(summary: s, expanded: expanded.contains(s.id),
                                             onToggle: { if expanded.contains(s.id) { expanded.remove(s.id) } else { expanded.insert(s.id) } },
                                             onDelete: { pendingDelete = s })
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog("Xoá bản tóm tắt “\(pendingDelete?.title ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Xoá", role: .destructive) {
                if let s = pendingDelete { HistoryStore.shared.deleteSummary(s.id) }
                pendingDelete = nil
            }
        }
    }
}

private struct StorySummaryCard: View {
    let summary: StorySummary
    let expanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var timeRange: String {
        let day = summary.from.formatted(date: .abbreviated, time: .omitted)
        return summary.from.hm == summary.to.hm ? "\(day) \(summary.from.hm)" : "\(day) \(summary.from.hm) – \(summary.to.hm)"
    }

    /// Câu thoại kèm bản dịch, dùng khi copy.
    private var dialogText: String {
        summary.lines.map { $0.target.isEmpty ? $0.source : "\($0.target)\n   \($0.source)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "book.pages").font(.system(size: 15)).foregroundStyle(Theme.accentGradient).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title).font(.system(size: 15.5, weight: .semibold))
                    Text("\(summary.lines.count) câu · \(timeRange) · \(BackendKind.label(raw: summary.backend)) · \(String(format: "%.1f", Double(summary.latencyMs) / 1000)) s")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Button { Clipboard.copy("\(summary.title)\n\n\(summary.summary)") } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy bản tóm tắt")
                    Button(action: onDelete) { Image(systemName: "trash") }.help("Xoá bản tóm tắt này")
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
            }
            Text(summary.summary)
                .font(.system(size: 14.5)).lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { withAnimation(.easeInOut(duration: 0.12)) { onToggle() } }) {
                Label(expanded ? "Ẩn câu thoại" : "Xem \(summary.lines.count) câu thoại", systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(summary.lines) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 24) {
                            Text(l.target.isEmpty ? AttributedString("—") : SpeakerColors.styled(l.target, size: 13.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(SpeakerColors.styled(l.source, size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button { Clipboard.copy("\(summary.title)\n\n\(summary.summary)") } label: { Label("Copy bản tóm tắt", systemImage: "doc.on.doc") }
            Button { Clipboard.copy("\(summary.title)\n\n\(summary.summary)\n\n---\n\(dialogText)") } label: {
                Label("Copy kèm câu thoại", systemImage: "doc.on.clipboard")
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Xoá", systemImage: "trash") }
        }
    }
}
