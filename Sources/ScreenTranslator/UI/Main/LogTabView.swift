import SwiftUI
import AppKit

/// Tab Nhật ký: phụ đề đã dịch và lịch sử dịch màn hình, cùng một thanh công cụ.
struct LogTabView: View {
    enum Section: String, CaseIterable, Identifiable {
        case subtitles, screens
        var id: String { rawValue }
        var label: String { self == .subtitles ? "Phụ đề" : "Dịch màn hình" }
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

    private var entries: [TranslationEntry] { legacy ? legacyEntries : store.entries }
    private var analyses: [ScreenAnalysis] { legacy ? legacyAnalyses : store.analyses }
    private var scopeName: String { legacy ? "dòng cũ chưa gắn game" : "game “\(settings.activeProfile.name)”" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $section) {
                    Text("Phụ đề  \(entries.count)").tag(Section.subtitles)
                    Text("Dịch màn hình  \(analyses.count)").tag(Section.screens)
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
                Menu {
                    ForEach(Exporter.Format.allCases) { f in
                        Button(f.label) { Exporter.export(f, entries: entries, analyses: analyses) }
                    }
                } label: { Image(systemName: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize().help("Xuất nhật ký (TXT / SRT / JSON)")
                Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(legacy ? "Xoá toàn bộ dòng cũ chưa gắn game" : (section == .subtitles ? "Xoá nhật ký phụ đề của game này" : "Xoá lịch sử dịch màn hình của game này"))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            switch section {
            case .subtitles: SubtitleLogView(search: search, entries: entries)
            case .screens: ScreenLogView(search: search, analyses: analyses)
            }
        }
        .confirmationDialog(legacy ? "Xoá toàn bộ dòng cũ chưa gắn game (cả phụ đề và dịch màn hình)?"
                            : (section == .subtitles ? "Xoá nhật ký phụ đề của \(scopeName)?" : "Xoá lịch sử dịch màn hình và ảnh chụp của \(scopeName)?"),
                            isPresented: $confirmClear) {
            Button("Xoá", role: .destructive) {
                if legacy { store.clearLegacy(); legacy = false }
                else if section == .subtitles { store.clear() } else { store.clearAnalyses() }
            }
        }
        .onChange(of: legacy) { _, on in
            legacyEntries = on ? store.legacyEntries() : []
            legacyAnalyses = on ? store.legacyAnalyses() : []
        }
        .onChange(of: settings.activeProfileID) { _, _ in legacy = false }
    }
}

/// Cuộn kiểu chat: cũ ở trên, mới ở dưới; tự bám đáy trừ khi người dùng đã cuộn lên.
private struct ChatScroll<Content: View>: View {
    let newestID: AnyHashable?
    let resetKey: String
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
            }
            .defaultScrollAnchor(.bottom)
            .onAppear { scroll(proxy, animated: false) }
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

    private var rows: [TranslationEntry] {
        var list = entries
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { $0.source.lowercased().contains(q) || $0.translated.lowercased().contains(q) }
        }
        return list.reversed()
    }

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
                            Text("CÂU GỐC").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 6)
                        ChatScroll(newestID: entries.first?.id, resetKey: search) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                                // Cách nhau > 45 giây coi như sang đoạn hội thoại khác → chèn mốc giờ.
                                if i == 0 || e.timestamp.timeIntervalSince(rows[i - 1].timestamp) > 45 {
                                    TimeMarker(date: e.timestamp).padding(.top, i == 0 ? 2 : 14).padding(.bottom, 6)
                                }
                                SubtitleLogRow(entry: e)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            NowTranslatingPanel()
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
    @State private var hovering = false

    var body: some View {
        // Câu quá đơn giản không được dịch: chỉ hiện câu gốc, mờ, ở cột câu gốc.
        let skipped = entry.backend == BackendKind.skipped.rawValue
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            Text(skipped ? AttributedString("—") : SpeakerColors.styled(entry.translated, size: 15))
                .lineSpacing(3).foregroundStyle(skipped ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(SpeakerColors.styled(entry.source, size: 14))
                .lineSpacing(3).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.accentStart.opacity(0.07) : .clear))
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

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
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
                    .multilineTextAlignment(.center).textSelection(.enabled).lineLimit(5)
                    .frame(maxWidth: .infinity)
                Text(pipeline.lastSource)
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled).lineLimit(3)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 14)
        .frame(minHeight: 104, alignment: .top)
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
        .help("Mở lại ảnh đã dịch")
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
                    Text(analysis.summary).font(.system(size: 14.5)).lineSpacing(2).lineLimit(expanded ? nil : 2).textSelection(.enabled)
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
                            Text(l.target).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Text(l.source).font(.system(size: 13.5)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
    }
}
