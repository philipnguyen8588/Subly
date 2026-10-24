import SwiftUI
import AppKit

/// Tab "Bị bỏ qua": chữ OCR đọc được nhưng không dịch, không đọc (menu, mẩu lạc, cảm thán, chữ mờ…) của game đang chơi,
/// mới nhất ở trên. Dùng để xem lại bộ lọc có bỏ nhầm câu thoại không.
struct SkippedTabView: View {
    @ObservedObject var log = SkipLog.shared
    @ObservedObject var settings = AppSettings.shared
    @AppStorage("skippedKind") private var kindRaw = ""     // "" = tất cả loại
    @State private var query = ""
    @State private var confirmClear = false

    private var profile: String { settings.activeProfile.id.uuidString }
    private var mine: [SkipLog.Entry] { log.entries.filter { $0.profile == profile } }
    private var shown: [SkipLog.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return mine.reversed().filter { e in
            (kindRaw.isEmpty || e.kind.rawValue == kindRaw)
                && (q.isEmpty || e.text.localizedCaseInsensitiveContains(q) || e.reason.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        let all = mine
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $kindRaw) {
                    Text("Tất cả  \(all.count)").tag("")
                    ForEach(SkipLog.Kind.allCases) { k in
                        let n = all.filter { $0.kind == k }.count
                        Text(n == 0 ? k.title : "\(k.title)  \(n)").tag(k.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.large)
                Spacer(minLength: 8)
                SearchField(text: $query, prompt: "Tìm chữ bị bỏ qua").frame(minWidth: 120, maxWidth: 220)
                Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                    .appIconButton().disabled(all.isEmpty)
                    .help("Xoá danh sách bị bỏ qua của game này")
            }
            .padding(.horizontal, 14).frame(height: 52)
            Divider()
            let items = shown
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(all.isEmpty ? "Chưa có chữ nào bị bỏ qua" : "Không có mục nào khớp")
                        .font(.headline).foregroundStyle(.secondary)
                    Text("Chữ OCR đọc được nhưng không dịch (menu, mẩu chữ lạc, cảm thán, chữ mờ…) sẽ hiện ở đây.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { e in
                            SkippedRow(entry: e)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Xoá danh sách bị bỏ qua của game “\(settings.activeProfile.name)”?",
                            isPresented: $confirmClear) {
            Button("Xoá", role: .destructive) { log.clear(profile: profile) }
        }
    }
}

private struct SkippedRow: View {
    let entry: SkipLog.Entry

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm:ss"; return f
    }()

    private var color: Color {
        switch entry.kind {
        case .ui: return Theme.accentStart
        case .stray: return .orange
        case .interjection: return .pink
        case .simple: return Theme.accentEnd
        case .junk: return .secondary
        case .faint: return .purple
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text((Calendar.current.isDateInToday(entry.time) ? Self.timeFmt : Self.dayFmt).string(from: entry.time))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .leading)
            Text(entry.kind.title)
                .font(.caption.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.14)))
                .frame(width: 78, alignment: .leading)
                .help(entry.kind.help)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text).font(.system(size: 13)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.reason.isEmpty || !entry.region.isEmpty {
                    Text([entry.region, entry.reason].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Sao chép chữ") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
        }
    }
}
