import SwiftUI

/// Tab "Tìm kiếm": một ô tìm cho cả phụ đề, cốt truyện và dịch màn hình của game đang chọn.
/// Mỗi khu vực mặc định chỉ hiện vài kết quả đầu; bấm để xem tất cả. Bấm một kết quả để mở chi tiết ngay tại chỗ.
struct SearchTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var ui = SearchUI.shared
    @FocusState private var focused: Bool

    typealias Area = SearchUI.Area
    static let preview = 3
    static let maxShown = 200

    private var active: Bool { ui.results.query.count >= HistorySearch.minLength }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !active {
                        hint
                    } else {
                        Text(summaryLine).font(.callout).foregroundStyle(.secondary)
                        section(.story, title: "Cốt truyện", icon: "text.book.closed", items: ui.results.story, capped: false) {
                            StoryHitRow(hit: $0, query: ui.results.query)
                        }
                        section(.subtitles, title: "Phụ đề", icon: "captions.bubble", items: ui.results.subtitles, capped: ui.results.subtitlesCapped) {
                            SubtitleHitRow(entry: $0, query: ui.results.query)
                        }
                        section(.screens, title: "Dịch màn hình", icon: "doc.text.magnifyingglass", items: ui.results.screens, capped: ui.results.screensCapped) {
                            ScreenHitRow(analysis: $0, query: ui.results.query)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { focused = true; if !ui.query.isEmpty { search() } }
        .onChange(of: ui.query) { _, _ in search() }
        .onChange(of: settings.activeProfileID) { _, _ in search() }
    }

    /// Ô tìm chỉ đưa chữ vào `query` sau 0,7 s ngừng gõ (hoặc khi Enter), rồi tìm ngay.
    private var searchField: some View {
        SearchField(text: $ui.query, prompt: "Tìm trong cốt truyện, phụ đề và ảnh đã dịch của “\(settings.activeProfile.name)”",
                    size: 16, height: 44, focus: $focused)
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(.quaternary)
            Text(ui.query.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Gõ tên nhân vật, địa danh, câu thoại… để tìm trong phụ đề, cốt truyện và ảnh đã dịch của game này."
                 : "Gõ ít nhất \(HistorySearch.minLength) ký tự.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var summaryLine: String {
        if ui.results.isEmpty { return "Không tìm thấy “\(ui.results.query)” trong game này." }
        func n(_ c: Int, _ capped: Bool) -> String { capped ? "\(c)+" : "\(c)" }
        return "Tìm thấy \(ui.results.story.count) mục cốt truyện · \(n(ui.results.subtitles.count, ui.results.subtitlesCapped)) phụ đề · \(n(ui.results.screens.count, ui.results.screensCapped)) màn hình"
    }

    /// Một khu vực kết quả: tiêu đề + số lượng; thu gọn thì hiện `preview` dòng đầu, mở thì hiện tối đa `maxShown` dòng.
    private func section<Item: Identifiable, Row: View>(_ area: Area, title: String, icon: String, items: [Item], capped: Bool,
                                                         @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        let isOpen = ui.open.contains(area)
        let shown = Array(items.prefix(isOpen ? Self.maxShown : Self.preview))
        let more = items.count - shown.count
        return VStack(alignment: .leading, spacing: 6) {
            Button { toggle(area) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary).frame(width: 14)
                    Image(systemName: icon).foregroundStyle(Theme.accentStart)
                    Text(title).font(.headline)
                    Text(capped ? "\(items.count)+" : "\(items.count)").font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Spacer()
                    if !items.isEmpty, items.count > Self.preview {
                        Text(isOpen ? "Thu gọn" : "Xem tất cả").font(.caption.weight(.medium)).foregroundStyle(Theme.accentStart)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(items.count <= Self.preview)
            if items.isEmpty {
                Text("Không có").font(.callout).foregroundStyle(.tertiary).padding(.leading, 22)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { row($0) }
                }
                if more > 0 || (isOpen && capped) {
                    Button { toggle(area) } label: {
                        Text(isOpen ? "Còn \(more > 0 ? "\(more)" : "nhiều") kết quả nữa, gõ cụ thể hơn để thu hẹp."
                                    : "Xem tất cả \(capped ? "\(items.count)+" : "\(items.count)") kết quả")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(isOpen ? Color.secondary : Theme.accentStart)
                    .disabled(isOpen).padding(.leading, 22)
                }
            }
        }
        .card(padding: 12)
        .opacity(items.isEmpty ? 0.6 : 1)
    }

    private func toggle(_ area: Area) {
        if ui.open.contains(area) { ui.open.remove(area) } else { ui.open.insert(area) }
    }

    private func search() {
        let r = HistorySearch.run(ui.query)
        if r.query != ui.results.query { ui.open = [] }
        ui.results = r
    }
}

/// Trạng thái của tab Tìm kiếm, giữ lại khi chuyển sang tab khác rồi quay về.
@MainActor
final class SearchUI: ObservableObject {
    static let shared = SearchUI()
    enum Area: Hashable { case subtitles, story, screens }
    @Published var query = ""
    @Published var results = HistorySearch.Results()
    @Published var open: Set<Area> = []
}

// MARK: - Tô từ khoá

enum SearchHighlight {
    /// Tô nền mọi chỗ khớp `query` (không phân biệt hoa thường) trong `text`.
    static func mark(_ text: AttributedString, _ query: String) -> AttributedString {
        guard !query.isEmpty else { return text }
        var out = text
        var from = out.startIndex
        while from < out.endIndex, let r = out[from...].range(of: query, options: .caseInsensitive) {
            out[r].backgroundColor = Color.yellow.opacity(0.45)
            out[r].foregroundColor = .primary
            from = r.upperBound
        }
        return out
    }

    /// Chỉ tô nền chỗ khớp, giữ nguyên font / màu do `.font()` / `.foregroundStyle()` của Text quyết định.
    static func plain(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        guard !query.isEmpty else { return out }
        var from = out.startIndex
        while from < out.endIndex, let r = out[from...].range(of: query, options: .caseInsensitive) {
            out[r].backgroundColor = Color.yellow.opacity(0.45)
            from = r.upperBound
        }
        return out
    }

    static func mark(_ text: String, _ query: String, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var a = AttributedString(text)
        a.font = .system(size: size, weight: weight)
        return mark(a, query)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd/MM HH:mm"
        return f.string(from: d)
    }
}

/// Từ khoá đang tìm ở tab Cốt truyện: các thẻ bên trong đọc để tô nền chỗ khớp.
private struct StorySearchKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var storySearch: String {
        get { self[StorySearchKey.self] }
        set { self[StorySearchKey.self] = newValue }
    }
}

/// Khung chung của một dòng kết quả: nền khi rê chuột, bấm để mở / đóng.
private struct HitRowFrame<Content: View>: View {
    let open: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(open ? Theme.accentStart.opacity(0.08) : (hovering ? Theme.controlFill : Color.clear)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
    }
}

// MARK: - Phụ đề

private struct SubtitleHitRow: View {
    let entry: TranslationEntry
    let query: String
    @State private var context: [TranslationEntry]?

    var body: some View {
        HitRowFrame(open: context != nil, action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                if let context {
                    ForEach(context) { e in
                        line(e, strong: e.id == entry.id).opacity(e.id == entry.id ? 1 : 0.6)
                    }
                } else {
                    line(entry, strong: true)
                }
            }
        }
        .copyMenu(source: entry.source, translated: entry.translated)
        .help(context == nil ? "Bấm để xem các câu trước và sau" : "Bấm để thu gọn")
    }

    private func line(_ e: TranslationEntry, strong: Bool) -> some View {
        let skipped = e.backend == BackendKind.skipped.rawValue
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(SearchHighlight.date(e.timestamp)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit().frame(width: 72, alignment: .leading)
            Text(skipped ? AttributedString("—") : SearchHighlight.mark(SpeakerColors.styled(e.translated, size: 14, weight: strong ? .medium : .regular), query))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(SearchHighlight.mark(SpeakerColors.styled(e.source, size: 13), query))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggle() {
        if context != nil { context = nil; return }
        let around = HistoryStore.shared.entriesAround(id: entry.id, profile: entry.profile, radius: 3)
        context = around.isEmpty ? [entry] : around
    }
}

// MARK: - Cốt truyện

private struct StoryHitRow: View {
    let hit: StorySearchHit
    let query: String
    @State private var open = false

    var body: some View {
        HitRowFrame(open: open, action: { open.toggle() }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(hit.kind.label, systemImage: hit.kind.icon).font(.caption.weight(.semibold)).foregroundStyle(Theme.accentStart)
                    Text(SearchHighlight.mark(hit.title, query, size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let d = hit.date { Text(SearchHighlight.date(d)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
                }
                if !hit.body.isEmpty {
                    Text(SearchHighlight.mark(open ? hit.body : HistorySearch.snippet(hit.body, query), query, size: 13))
                        .foregroundStyle(.secondary).lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contextMenu {
            Button { Clipboard.copy("\(hit.title)\n\(hit.body)") } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        .help(open ? "Bấm để thu gọn" : "Bấm để đọc toàn bộ")
    }
}

// MARK: - Dịch màn hình

private struct ScreenHitRow: View {
    let analysis: ScreenAnalysis
    let query: String
    @State private var open = false

    private var matched: [AnalysisLine] {
        analysis.lines.filter { HistorySearch.matches($0.source, query) || HistorySearch.matches($0.target, query) }
    }

    var body: some View {
        let matched = matched
        HitRowFrame(open: open, action: tap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: analysis.hasImage ? "photo" : "text.alignleft").foregroundStyle(Theme.accentStart)
                    Text(SearchHighlight.date(analysis.timestamp)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if !analysis.summary.isEmpty {
                        Text(SearchHighlight.mark(HistorySearch.snippet(analysis.summary, query, width: 110), query, size: 13))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(analysis.hasImage ? "Mở ảnh" : "\(analysis.lines.count) dòng").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(open ? analysis.lines : Array(matched.prefix(2))) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(SearchHighlight.mark(l.target, query, size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(SearchHighlight.mark(l.source, query, size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 22)
                }
            }
        }
        .copyMenu(source: analysis.sourceText, translated: analysis.translatedText)
        .help(analysis.hasImage ? "Bấm để mở ảnh đã dịch" : (open ? "Bấm để thu gọn" : "Bấm để xem mọi dòng chữ"))
    }

    private func tap() {
        if analysis.hasImage { ShotViewer.shared.show(analysis.id) } else { open.toggle() }
    }
}
