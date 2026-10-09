import SwiftUI
import AppKit

/// Tab Nhật ký: phụ đề đã dịch và lịch sử dịch màn hình, cùng một thanh công cụ.
struct LogTabView: View {
    enum Section: String, CaseIterable, Identifiable {
        case subtitles, screens, summaries
        var id: String { rawValue }
    }

    @ObservedObject var store = HistoryStore.shared
    @State private var section: Section = .subtitles
    @State private var search = ""
    @State private var confirmClear = false
    /// Đang xem các dòng cũ không gắn với game nào (có từ trước khi nhật ký được tách theo game).
    @State private var legacy = false
    @State private var legacyEntries: [TranslationEntry] = []
    @State private var legacyAnalyses: [ScreenAnalysis] = []
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var summarizer = StorySummarizer.shared

    private var entries: [TranslationEntry] { legacy ? legacyEntries : store.entries }
    private var analyses: [ScreenAnalysis] { legacy ? legacyAnalyses : store.analyses }
    private var clearTitle: String {
        switch section {
        case .summaries: return "Xoá mọi bản tóm tắt của game này"
        case _ where legacy: return "Xoá toàn bộ dòng cũ chưa gắn game"
        case .subtitles: return "Xoá nhật ký phụ đề của game này"
        case .screens: return "Xoá lịch sử dịch màn hình của game này"
        }
    }
    private var clearQuestion: String {
        switch section {
        case .summaries: return "Xoá mọi bản tóm tắt của game “\(settings.activeProfile.name)”?"
        case _ where legacy: return "Xoá toàn bộ dòng cũ chưa gắn game (cả phụ đề và dịch màn hình)?"
        case .subtitles: return "Xoá nhật ký phụ đề của \(scopeName)?"
        case .screens: return "Xoá lịch sử dịch màn hình và ảnh chụp của \(scopeName)?"
        }
    }
    private var scopeName: String { legacy ? "dòng cũ chưa gắn game" : "game “\(settings.activeProfile.name)”" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $section) {
                    Text("Phụ đề  \(entries.count)").tag(Section.subtitles)
                    Text("Dịch màn hình  \(analyses.count)").tag(Section.screens)
                    Text("Tóm tắt  \(store.summaries.count)").tag(Section.summaries)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if store.legacyCount > 0 {
                    Toggle(isOn: $legacy) { Text("Dòng cũ") }.toggleStyle(.button)
                        .help("Nhật ký có từ trước khi tách theo game (\(store.legacyCount) dòng, không gắn với game nào)")
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Tìm trong nhật ký", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 280)
                Spacer()
                if section != .summaries {
                Menu {
                    ForEach(Exporter.Format.allCases) { f in
                        Button(f.label) { Exporter.export(f, entries: entries, analyses: analyses) }
                    }
                } label: { Image(systemName: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize().help("Xuất nhật ký (TXT / SRT / JSON)")
                }
                Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(clearTitle)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            switch section {
            case .subtitles: SubtitleLogView(search: search, entries: entries)
            case .screens: ScreenLogView(search: search, analyses: analyses)
            case .summaries: StorySummaryView(search: search, summaries: store.summaries)
            }
        }
        .confirmationDialog(clearQuestion, isPresented: $confirmClear) {
            Button("Xoá", role: .destructive) {
                switch section {
                case .summaries: store.clearSummaries()
                case _ where legacy: store.clearLegacy(); legacy = false
                case .subtitles: store.clear()
                case .screens: store.clearAnalyses()
                }
            }
        }
        // Tóm tắt xong khi đang xem mục Phụ đề → chuyển sang mục Tóm tắt để đọc ngay.
        .onChange(of: summarizer.lastSavedID) { _, id in if id != nil, section == .subtitles { section = .summaries } }
        .onChange(of: legacy) { _, on in
            legacyEntries = on ? store.legacyEntries() : []
            legacyAnalyses = on ? store.legacyAnalyses() : []
        }
        .onChange(of: settings.activeProfileID) { _, _ in legacy = false }
    }
}

/// Cuộn kiểu chat: cũ ở trên, mới ở dưới; tự bám đáy trừ khi người dùng đã cuộn lên.
private struct ChatScroll<Content: View>: View {
    /// Hệ toạ độ của nội dung cuộn (không đổi khi cuộn), dùng để biết chuột đang ở dòng nào khi kéo chọn.
    static var space: String { "chat-content" }
    let newestID: AnyHashable?
    let resetKey: String
    /// Đổi giá trị → cuộn vừa đủ để dòng có id này hiện ra (kéo chọn chạm mép trên/dưới).
    var revealID: AnyHashable? = nil
    /// Vùng đang nhìn thấy, theo hệ toạ độ `space`.
    var onViewport: ((CGRect) -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var atBottom = true
    @State private var unseen = 0
    private let bottomID = "chat-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                    Color.clear.frame(height: 1).id(bottomID)
                        .onAppear { atBottom = true; unseen = 0 }
                        .onDisappear { atBottom = false }
                }
                .padding(.vertical, 6)
                .coordinateSpace(.named(Self.space))
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, r in onViewport?(r) }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: revealID) { _, id in if let id { proxy.scrollTo(id) } }
            .onChange(of: newestID) { _, _ in if atBottom { scroll(proxy, animated: true) } else { unseen += 1 } }
            .onChange(of: resetKey) { _, _ in scroll(proxy, animated: false) }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { scroll(proxy, animated: true) } label: {
                        Label(unseen > 0 ? "Mới nhất (\(unseen))" : "Mới nhất", systemImage: "arrow.down")
                    }
                    .buttonStyle(GradientButtonStyle(compact: true)).padding(12)
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        unseen = 0
        DispatchQueue.main.async {
            if animated { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) } }
            else { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
        for delay in [0.2, 0.5] {     // danh sách lazy ước lượng chiều cao chưa chuẩn ở nhịp đầu
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }
}

// MARK: - Phụ đề

struct SubtitleLogView: View {
    let search: String
    let entries: [TranslationEntry]
    @ObservedObject var summarizer = StorySummarizer.shared
    /// Các dòng đang chọn (để tóm tắt / copy). Chọn kiểu Finder + Ảnh trên iPhone:
    /// bấm = chọn một dòng, Shift-bấm = chọn từ dòng đã chọn đến dòng này, ⌘-bấm = thêm/bớt một dòng, kéo chuột = chọn liền một dải.
    @State private var selected: Set<Int64> = []
    @State private var anchor: Int64?
    @State private var drag: DragState?
    @State private var geo = RowGeometry()
    @State private var revealID: Int64?
    @State private var edgeScroll: Task<Void, Never>?

    private struct DragState {
        var start: Int64
        var base: Set<Int64>
        var adding: Bool
        var current: Int64
        var moved = false
        /// Bấm lại đúng dòng duy nhất đang chọn (không kéo) → bỏ chọn.
        var tappedSoleSelection = false
    }

    /// Vị trí các dòng và vùng đang nhìn thấy: đổi liên tục khi cuộn nên không để trong @State (tránh vẽ lại cả danh sách).
    private final class RowGeometry {
        var frames: [Int64: CGRect] = [:]
        var viewport: CGRect = .zero
    }

    /// Cũ ở trên, mới ở dưới.
    private var rows: [TranslationEntry] {
        var list = entries
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { $0.source.lowercased().contains(q) || $0.translated.lowercased().contains(q) }
        }
        return list.reversed()
    }

    private var selectedRows: [TranslationEntry] { rows.filter { selected.contains($0.id) } }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            Group {
                if rows.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.quaternary)
                        Text(entries.isEmpty ? "Các câu phụ đề đã dịch của game này sẽ hiện ở đây, mới nhất ở dưới cùng." : "Không có dòng nào khớp.")
                            .font(.callout).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 28) {
                            Text("BẢN DỊCH").frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Text("CÂU GỐC")
                                Spacer()
                                Text("Kéo chuột hoặc Shift-bấm để chọn nhiều câu rồi Tóm tắt")
                                    .tracking(0).font(.system(size: 10.5)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 6)
                        ChatScroll(newestID: entries.first?.id, resetKey: search, revealID: revealID,
                                   onViewport: { [geo] in geo.viewport = $0 }) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                                // Cách nhau > 45 giây coi như sang đoạn hội thoại khác → chèn mốc giờ.
                                if i == 0 || e.timestamp.timeIntervalSince(rows[i - 1].timestamp) > 45 {
                                    TimeMarker(date: e.timestamp).padding(.top, i == 0 ? 2 : 14).padding(.bottom, 6)
                                }
                                row(e)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            if !selectedRows.isEmpty || summarizer.isRunning || summarizer.lastError != nil {
                selectionBar
            }
            NowTranslatingPanel()
        }
        .onChange(of: search) { _, _ in clearSelection() }
        .onChange(of: entries.last?.id) { _, _ in clearSelection() }     // đổi game / xoá nhật ký
    }

    private func row(_ e: TranslationEntry) -> some View {
        let isSelected = selected.contains(e.id)
        let count = isSelected ? selected.count : 0
        return SubtitleLogRow(entry: e, selected: isSelected)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatScroll<EmptyView>.space)) } action: { [geo] in geo.frames[e.id] = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(ChatScroll<EmptyView>.space))
                    .onChanged { v in dragChanged(on: e.id, at: v.location) }
                    .onEnded { _ in dragEnded() }
            )
            .contextMenu {
                if count > 1 {
                    Button { summarize() } label: { Label("Tóm tắt \(count) câu đã chọn", systemImage: "text.badge.star") }
                        .disabled(summarizer.isRunning)
                    Button { copySelection(translated: true) } label: { Label("Copy bản dịch \(count) câu", systemImage: "character.bubble") }
                    Button { copySelection(translated: false) } label: { Label("Copy bản gốc \(count) câu", systemImage: "doc.on.doc") }
                    Divider()
                }
                let skipped = e.backend == BackendKind.skipped.rawValue
                Button { Clipboard.copy(e.source) } label: { Label("Copy bản gốc", systemImage: "doc.on.doc") }
                Button { Clipboard.copy(skipped ? e.source : e.translated) } label: { Label("Copy bản dịch", systemImage: "character.bubble") }
                Button { Clipboard.copy("\(e.source)\n\(skipped ? e.source : e.translated)") } label: { Label("Copy cả hai", systemImage: "doc.on.clipboard") }
                Divider()
                Button { selectConversation(around: e.id) } label: { Label("Chọn cả đoạn hội thoại này", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { selectToNewest(from: e.id) } label: { Label("Chọn từ câu này đến mới nhất", systemImage: "arrow.down.to.line") }
            }
    }

    // MARK: thanh chọn

    private var selectionBar: some View {
        let sel = selectedRows
        return HStack(spacing: 10) {
            if summarizer.isRunning {
                ProgressView().controlSize(.small)
                Text("Đang tóm tắt \(summarizer.runningCount) câu…").font(.callout)
            } else if let err = summarizer.lastError, sel.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
                Spacer()
                Button("Đóng") { summarizer.dismissError() }.buttonStyle(.borderless)
            }
            if !sel.isEmpty {
                if summarizer.isRunning { Divider().frame(height: 16) }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentStart)
                Text("Đã chọn \(sel.count) câu").font(.callout.weight(.semibold))
                if let f = sel.first, let l = sel.last {
                    Text(f.timestamp.hm == l.timestamp.hm ? f.timestamp.hm : "\(f.timestamp.hm) – \(l.timestamp.hm)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Menu {
                    Button("Copy bản dịch") { copySelection(translated: true) }
                    Button("Copy bản gốc") { copySelection(translated: false) }
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Bỏ chọn") { clearSelection() }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help("Bỏ chọn (Esc)")
                Button { summarize() } label: { Label("Tóm tắt", systemImage: "text.badge.star") }
                    .buttonStyle(GradientButtonStyle(compact: true))
                    .disabled(summarizer.isRunning)
                    .help("Tóm tắt nội dung các câu đã chọn; bản tóm tắt được lưu ở mục Tóm tắt")
            } else if summarizer.isRunning {
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func summarize() {
        let sel = selectedRows
        guard !sel.isEmpty else { return }
        summarizer.summarize(sel)
        clearSelection()
    }

    private func copySelection(translated: Bool) {
        let skipped = BackendKind.skipped.rawValue
        Clipboard.copy(selectedRows.map { translated && $0.backend != skipped ? $0.translated : $0.source }.joined(separator: "\n"))
    }

    private func clearSelection() {
        selected = []; anchor = nil
    }

    private func selectConversation(around id: Int64) {
        let rows = rows
        guard var lo = rows.firstIndex(where: { $0.id == id }) else { return }
        var hi = lo
        while lo > 0, rows[lo].timestamp.timeIntervalSince(rows[lo - 1].timestamp) <= 45 { lo -= 1 }
        while hi < rows.count - 1, rows[hi + 1].timestamp.timeIntervalSince(rows[hi].timestamp) <= 45 { hi += 1 }
        selected = Set(rows[lo...hi].map(\.id)); anchor = id
    }

    private func selectToNewest(from id: Int64) {
        let rows = rows
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        selected = Set(rows[i...].map(\.id)); anchor = id
    }

    // MARK: kéo chọn

    private func dragChanged(on id: Int64, at location: CGPoint) {
        let order = rows.map(\.id)
        guard var d = drag else {
            // Nhịp đầu của cú bấm: quyết định kiểu chọn theo phím đang giữ.
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift), let a = anchor, order.contains(a) {
                drag = DragState(start: a, base: flags.contains(.command) ? selected : [], adding: true, current: id)
            } else if flags.contains(.command) {
                drag = DragState(start: id, base: selected, adding: !selected.contains(id), current: id)
                anchor = id
            } else {
                drag = DragState(start: id, base: [], adding: true, current: id, tappedSoleSelection: selected == [id])
                anchor = id
            }
            apply(order)
            return
        }
        if let target = row(atY: location.y, order: order), target != d.current {
            d.current = target; d.moved = true; drag = d
            apply(order)
        }
        autoScroll(y: location.y)
    }

    private func dragEnded() {
        if let d = drag, d.tappedSoleSelection, !d.moved { clearSelection() }
        drag = nil
        edgeScroll?.cancel(); edgeScroll = nil
    }

    private func apply(_ order: [Int64]) {
        guard let d = drag, let i = order.firstIndex(of: d.start), let j = order.firstIndex(of: d.current) else { return }
        let range = Set(order[min(i, j)...max(i, j)])
        selected = d.adding ? d.base.union(range) : d.base.subtracting(range)
    }

    /// Dòng nằm dưới chuột; chuột ở khe giữa hai dòng (mốc giờ) thì lấy dòng gần nhất.
    private func row(atY y: CGFloat, order: [Int64]) -> Int64? {
        var best: (id: Int64, dist: CGFloat)?
        for id in order {
            guard let f = geo.frames[id] else { continue }
            if f.minY <= y, y < f.maxY { return id }
            let dist = min(abs(f.minY - y), abs(f.maxY - y))
            if best == nil || dist < best!.dist { best = (id, dist) }
        }
        return best?.id
    }

    /// Kéo chọn chạm mép trên/dưới vùng nhìn thấy → tự cuộn và chọn tiếp từng dòng, đến khi chuột rời mép hoặc thả ra.
    private func autoScroll(y: CGFloat) {
        let vp = geo.viewport
        let dir = vp.isEmpty ? 0 : (y < vp.minY + 30 ? -1 : (y > vp.maxY - 30 ? 1 : 0))
        guard dir != 0 else { edgeScroll?.cancel(); edgeScroll = nil; return }
        guard edgeScroll == nil else { return }
        edgeScroll = Task { @MainActor in
            while !Task.isCancelled, var d = drag {
                let order = rows.map(\.id)
                guard let j = order.firstIndex(of: d.current), order.indices.contains(j + dir) else { break }
                d.current = order[j + dir]; d.moved = true; drag = d
                apply(order)
                revealID = d.current
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }
}

/// Mốc giờ giữa các đoạn hội thoại: một đường kẻ mảnh với giờ ở giữa.
private struct TimeMarker: View {
    let date: Date
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            Text(date.hm)
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Color.primary.opacity(0.05), in: Capsule())
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
        }
        .padding(.horizontal, 28)
    }
}

private struct SubtitleLogRow: View {
    let entry: TranslationEntry
    var selected = false
    @State private var hovering = false

    var body: some View {
        // Câu quá đơn giản không được dịch: chỉ hiện câu gốc, mờ, ở cột câu gốc.
        let skipped = entry.backend == BackendKind.skipped.rawValue
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            Text(skipped ? AttributedString("—") : SpeakerColors.styled(entry.translated, size: 15))
                .lineSpacing(3).foregroundStyle(skipped ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(SpeakerColors.styled(entry.source, size: 14))
                .lineSpacing(3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accentStart.opacity(0.18) : (hovering ? Theme.accentStart.opacity(0.07) : .clear)))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Theme.accentStart).frame(width: 3).padding(.vertical, 5) }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 4) {
                    Text("\(entry.timestamp.hms) · \(BackendKind.label(raw: entry.backend)) · \(entry.latencyMs) ms")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Button { copy(entry.translated) } label: { Image(systemName: "doc.on.doc") }.help("Copy bản dịch")
                    Button { copy(entry.source) } label: { Image(systemName: "doc.on.doc.fill") }.help("Copy câu gốc")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                .padding(.trailing, 22).offset(y: -10)
            }
        }
        .onHover { hovering = $0 }
    }

    private func copy(_ s: String) { Clipboard.copy(s) }
}

/// Copy vào bộ nhớ tạm.
enum Clipboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

extension View {
    /// Menu chuột phải: copy bản gốc / bản dịch / cả hai.
    func copyMenu(source: String, translated: String) -> some View {
        contextMenu {
            Button { Clipboard.copy(source) } label: { Label("Copy bản gốc", systemImage: "doc.on.doc") }
            Button { Clipboard.copy(translated) } label: { Label("Copy bản dịch", systemImage: "character.bubble") }
            Divider()
            Button { Clipboard.copy("\(source)\n\(translated)") } label: { Label("Copy cả hai", systemImage: "doc.on.clipboard") }
        }
    }
}

extension ScreenAnalysis {
    /// Toàn bộ chữ gốc của một lần dịch màn hình, mỗi khối một dòng.
    var sourceText: String { lines.map(\.source).joined(separator: "\n") }
    /// Tóm tắt + bản dịch từng khối.
    var translatedText: String { ([summary, ""] + lines.map(\.target)).joined(separator: "\n") }
}

/// Khu vực cố định ở đáy tab Nhật ký: câu phụ đề đang được dịch lúc này.
struct NowTranslatingPanel: View {
    @ObservedObject var pipeline = Pipeline.shared
    @ObservedObject var router: TranslationRouter = Pipeline.shared.router

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(pipeline.isRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(pipeline.isRunning ? "ĐANG DỊCH" : "ĐÃ DỪNG")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                if let b = pipeline.lastBackend, !pipeline.lastTranslated.isEmpty {
                    Text("· \(b == .gemini ? (router.activeModel ?? "Gemini") : b.label) · \(pipeline.lastMs) ms")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer()
                if !pipeline.lastTranslated.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pipeline.lastTranslated, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).controlSize(.small).help("Copy bản dịch")
                }
            }
            if let e = router.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
            }
            if pipeline.lastTranslated.isEmpty {
                Text(pipeline.isRunning ? "Đang chờ phụ đề xuất hiện…" : "Bấm Bắt đầu để dịch phụ đề.")
                    .font(.system(size: 17)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                Text(SpeakerColors.styled(pipeline.lastTranslated, size: 22, weight: .semibold))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center).lineLimit(5)
                    .frame(maxWidth: .infinity)
                Text(pipeline.lastSource)
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 14)
        .frame(minHeight: 104, alignment: .top)
        .copyMenu(source: pipeline.lastSource, translated: pipeline.lastTranslated)
        .background(
            LinearGradient(colors: [Theme.accentStart.opacity(0.10), Theme.accentEnd.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
        )
        .overlay(alignment: .top) { Rectangle().fill(Theme.accentStart.opacity(0.25)).frame(height: 1) }
    }
}

// MARK: - Dịch màn hình

struct ScreenLogView: View {
    let search: String
    let analyses: [ScreenAnalysis]
    @ObservedObject var analyzer: ScreenAnalyzer = Pipeline.shared.analyzer
    @State private var expanded: Set<Int64> = []

    /// Mới nhất trước.
    private var rows: [ScreenAnalysis] {
        guard !search.isEmpty else { return analyses }
        let q = search.lowercased()
        return analyses.filter { a in a.summary.lowercased().contains(q) || a.lines.contains { $0.source.lowercased().contains(q) || $0.target.lowercased().contains(q) } }
    }

    var body: some View {
        let rows = rows
        let shots = rows.filter(\.hasImage), textOnly = rows.filter { !$0.hasImage }
        VStack(spacing: 0) {
            if let e = analyzer.lastError {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 6)
            }
            if rows.isEmpty {
                Spacer()
                Text(analyses.isEmpty ? "Mỗi lần bấm “Dịch màn hình” trong game này sẽ được lưu lại ở đây kèm ảnh chụp." : "Không có mục nào khớp.")
                    .font(.callout).foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !shots.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                                ForEach(shots) { a in ShotCard(analysis: a) }
                            }
                        }
                        if !textOnly.isEmpty {
                            Text(shots.isEmpty ? "CHỈ CÒN CHỮ" : "CŨ HƠN · CHỈ CÒN CHỮ (mỗi game giữ \(HistoryStore.maxShots) ảnh gần nhất)")
                                .font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary).padding(.top, 4)
                            ForEach(textOnly) { a in
                                ScreenLogCard(analysis: a, expanded: expanded.contains(a.id)) {
                                    if expanded.contains(a.id) { expanded.remove(a.id) } else { expanded.insert(a.id) }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Một lần chụp còn ảnh: bấm để mở lại ảnh đã dịch.
private struct ShotCard: View {
    let analysis: ScreenAnalysis
    @State private var hovering = false

    var body: some View {
        Button { ShotViewer.shared.show(analysis.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ShotThumb(id: analysis.id)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(analysis.summary).font(.system(size: 12.5)).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(analysis.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(analysis.items.count) khối chữ")
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.07 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovering ? Theme.accentStart.opacity(0.5) : Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .copyMenu(source: analysis.sourceText, translated: analysis.translatedText)
        .help("Mở lại ảnh đã dịch · chuột phải để copy")
    }
}

private struct ScreenLogCard: View {
    let analysis: ScreenAnalysis
    let expanded: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 12).padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(analysis.summary).font(.system(size: 14.5)).lineSpacing(2).lineLimit(expanded ? nil : 2)
                    Text("\(analysis.timestamp.hms) · \(analysis.lines.count) khối chữ · \(BackendKind.label(raw: analysis.backend)) · \(String(format: "%.1f", Double(analysis.latencyMs) / 1000)) s")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 4)
                if hovering {
                    Button {
                        let txt = "\(analysis.summary)\n\n" + analysis.lines.map { "\($0.source)\n→ \($0.target)" }.joined(separator: "\n\n")
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(txt, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy toàn bộ")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.12)) { onToggle() } }

            if expanded, !analysis.lines.isEmpty {
                Divider().padding(.leading, 20)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(analysis.lines) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 24) {
                            Text(l.target).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(l.source).font(.system(size: 13.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        .onHover { hovering = $0 }
        .copyMenu(source: analysis.sourceText, translated: analysis.translatedText)
    }
}
