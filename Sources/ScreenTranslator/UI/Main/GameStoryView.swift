import SwiftUI

/// Mục "Cốt truyện" của tab Nhật ký: cốt truyện của game đang chọn do app tự viết từ phụ đề: bài viết liền mạch,
/// dòng thời gian từng đoạn diễn biến, danh sách nhân vật và bách khoa (địa danh, thế lực, khái niệm lấy từ màn hình
/// nhật ký đã dịch). Thanh ngang ở trên cùng nhảy nhanh tới từng mục.
struct GameStoryView: View {
    let search: String
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject var tracker = StoryTracker.shared
    @ObservedObject var settings = AppSettings.shared
    /// Đoạn diễn biến người dùng đã bấm mở / đóng (mặc định: ba đoạn mới nhất mở).
    @State private var toggled: Set<Int64> = []
    @State private var pendingDeletePart: StoryPart?
    @State private var pendingDeleteCharacter: StoryCharacter?
    @State private var pendingDeleteLore: StoryLore?
    /// Loại mục bách khoa đang lọc ("" = tất cả).
    @State private var loreKind = ""
    /// ↑/↓ cuộn mượt; ←/→ chọn đoạn diễn biến, Enter / Space mở hoặc thu gọn đoạn đang chọn.
    @State private var selectedPart: Int64?
    @State private var scroller = KeyScroller()
    @State private var keyID = UUID()
    @State private var confirmFromStart = false
    /// Mục đang xem (chọn ở thanh trên cùng); mặc định là Diễn biến.
    @AppStorage("storyShownSection") private var shown = Anchor.parts.rawValue
    private var shownAnchor: Anchor { Anchor(rawValue: shown) ?? .parts }
    /// Thứ tự danh sách nhân vật: true = ai vừa xuất hiện gần đây đứng trước, false = theo thứ tự gặp trong game.
    @AppStorage("storyCharactersRecentFirst") private var recentFirst = true

    /// Các mục của trang (thanh trên cùng chọn mục để xem).
    private enum Anchor: String { case narrative, parts, characters, lore }
    private static let topID = "story-top"

    private var query: String { search.lowercased() }
    private var narrative: String { store.story?.narrative ?? "" }
    private var parts: [StoryPart] {
        guard !search.isEmpty else { return store.storyParts }
        return store.storyParts.filter { $0.title.lowercased().contains(query) || $0.summary.lowercased().contains(query) }
    }
    private var characters: [StoryCharacter] {
        // Danh sách lưu theo thứ tự gặp lần đầu. "Vừa xuất hiện": xếp theo lần xuất hiện gần nhất; nhân vật của dữ liệu cũ
        // (chưa ghi nhận thời điểm) thì ai được thêm sau đứng trước.
        var all = store.story?.characters ?? []
        if recentFirst {
            all = all.enumerated().sorted { a, b in
                a.element.seen != b.element.seen ? a.element.seen > b.element.seen : a.offset > b.offset
            }.map(\.element)
        }
        guard !search.isEmpty else { return all }
        return all.filter { c in
            [c.name, c.status, c.role, c.personality, c.background, c.relations, c.journal].contains { $0.lowercased().contains(query) }
        }
    }
    /// Mục bách khoa khớp ô tìm (chưa lọc theo loại).
    private var loreMatches: [StoryLore] {
        let all = store.story?.lore ?? []
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) }
    }
    private var lore: [StoryLore] { loreKind.isEmpty ? loreMatches : loreMatches.filter { $0.kind == loreKind } }
    private var hasContent: Bool {
        !narrative.isEmpty || !store.storyParts.isEmpty || !(store.story?.characters ?? []).isEmpty || !(store.story?.lore ?? []).isEmpty
    }
    private var showNarrative: Bool { !narrative.isEmpty && (search.isEmpty || narrative.lowercased().contains(query)) }

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            if hasContent { jumpBar(proxy) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Color.clear.frame(height: 0).id(Self.topID)
                statusCard
                if !hasContent {
                    emptyState
                } else {
                    // Chỉ dựng mục đang chọn ở thanh trên: dựng cả bốn mục một lúc làm trang dài và cuộn giật.
                    switch shownAnchor {
                    case .narrative:
                        if showNarrative {
                            header("Cốt truyện đến hiện tại", icon: "text.book.closed") {
                                Button { Clipboard.copy(narrative) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless).help("Copy")
                            }
                            Text(narrative)
                                .font(.system(size: 14.5)).lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentStart.opacity(0.06)))
                        } else {
                            sectionEmpty(narrative.isEmpty ? "Chưa có bài tóm lược." : "Bài tóm lược không có chữ nào khớp “\(search)”.")
                        }
                    case .parts:
                        if parts.isEmpty {
                            sectionEmpty(search.isEmpty ? "Chưa có đoạn diễn biến nào." : "Không có đoạn diễn biến nào khớp “\(search)”.")
                        } else {
                            let allOpen = parts.indices.allSatisfy { partOpen(parts[$0], index: $0) }
                            header("Diễn biến  \(parts.count)", icon: "list.bullet.rectangle") {
                                Button(allOpen ? "Thu gọn tất cả" : "Mở tất cả") {
                                    withAnimation(.easeInOut(duration: 0.12)) { setAllParts(open: !allOpen) }
                                }
                                .buttonStyle(.borderless).font(.caption.weight(.medium))
                            }
                            LazyVStack(spacing: 10) {
                                ForEach(Array(parts.enumerated()), id: \.element.id) { i, p in
                                    StoryPartCard(part: p, expanded: partOpen(p, index: i) || !search.isEmpty, selected: selectedPart == p.id,
                                                  onToggle: { if toggled.contains(p.id) { toggled.remove(p.id) } else { toggled.insert(p.id) } },
                                                  onDelete: { pendingDeletePart = p })
                                }
                            }
                        }
                    case .characters:
                        if characters.isEmpty {
                            sectionEmpty(search.isEmpty ? "Chưa có nhân vật nào." : "Không có nhân vật nào khớp “\(search)”.")
                        } else {
                            header("Nhân vật  \(characters.count)", icon: "person.2") {
                                Picker("", selection: $recentFirst) {
                                    Text("Vừa xuất hiện").tag(true)
                                    Text("Theo mạch truyện").tag(false)
                                }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                                .help("Vừa xuất hiện: ai mới góp mặt trong diễn biến gần đây đứng đầu. Theo mạch truyện: xếp theo thứ tự gặp lần đầu trong game.")
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                                ForEach(characters) { c in
                                    StoryCharacterCard(character: c, onDelete: { pendingDeleteCharacter = c })
                                }
                            }
                        }
                    case .lore:
                        if loreMatches.isEmpty {
                            loreEmptyState
                        } else {
                            header("Bách khoa  \(loreMatches.count)", icon: "books.vertical") {
                                Picker("", selection: $loreKind) {
                                    Text("Tất cả").tag("")
                                    ForEach(StoryLore.kinds, id: \.id) { k in
                                        let n = loreMatches.filter { $0.kind == k.id }.count
                                        if n > 0 { Text("\(k.label) \(n)").tag(k.id) }
                                    }
                                }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                                ForEach(lore) { l in
                                    StoryLoreCard(lore: l, onDelete: { pendingDeleteLore = l })
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .keyScroll($scroller)
        .logKeys(keyID) { key in
            switch key {
            case .left, .right:
                guard shownAnchor == .parts else { return false }
                selectedPart = stepSelection(parts.map(\.id), current: selectedPart, by: key == .left ? -1 : 1)
                if let s = selectedPart { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(s, anchor: nil) } }
                return true
            case .toggle:
                guard shownAnchor == .parts, let s = selectedPart else { return false }
                withAnimation(.easeInOut(duration: 0.12)) { if toggled.contains(s) { toggled.remove(s) } else { toggled.insert(s) } }
                return true
            default:
                return scroller.scroll(key)
            }
        }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { tracker.refreshPending() }
        .onChange(of: settings.activeProfileID) { _, _ in tracker.refreshPending() }
        .confirmationDialog("Xoá đoạn “\(pendingDeletePart?.title ?? "")” khỏi dòng diễn biến?",
                            isPresented: Binding(get: { pendingDeletePart != nil }, set: { if !$0 { pendingDeletePart = nil } })) {
            Button("Xoá", role: .destructive) {
                if let p = pendingDeletePart { store.deleteStoryPart(p.id) }
                pendingDeletePart = nil
            }
        }
        .confirmationDialog("Xoá nhân vật “\(pendingDeleteCharacter?.name ?? "")” khỏi cốt truyện?",
                            isPresented: Binding(get: { pendingDeleteCharacter != nil }, set: { if !$0 { pendingDeleteCharacter = nil } })) {
            Button("Xoá", role: .destructive) {
                if let c = pendingDeleteCharacter { store.deleteStoryCharacter(name: c.name) }
                pendingDeleteCharacter = nil
            }
        }
        .confirmationDialog("Xoá mục “\(pendingDeleteLore?.name ?? "")” khỏi bách khoa?",
                            isPresented: Binding(get: { pendingDeleteLore != nil }, set: { if !$0 { pendingDeleteLore = nil } })) {
            Button("Xoá", role: .destructive) {
                if let l = pendingDeleteLore { store.deleteStoryLore(name: l.name) }
                pendingDeleteLore = nil
            }
        }
        .confirmationDialog("Viết lại cốt truyện từ đầu nhật ký (\(tracker.backlogLines) câu)? Cốt truyện đang có của game này sẽ bị thay.",
                            isPresented: $confirmFromStart) {
            Button("Tóm tắt từ đầu nhật ký") { tracker.summarizeFromStart() }
        }
    }

    /// Thanh ngang ghim ở đầu trang: bấm để xem riêng mục đó (số bên cạnh là số mục, hoặc số mục khớp khi đang tìm).
    private func jumpBar(_ proxy: ScrollViewProxy) -> some View {
        let items: [(Anchor, String, String, Int?)] = [
            (.narrative, "Tóm lược", "text.book.closed", nil),
            (.parts, "Diễn biến", "list.bullet.rectangle", parts.count),
            (.characters, "Nhân vật", "person.2", characters.count),
            (.lore, "Bách khoa", "books.vertical", loreMatches.count),
        ]
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { anchor, title, icon, count in
                    let on = shownAnchor == anchor
                    Button {
                        shown = anchor.rawValue
                        selectedPart = nil
                        proxy.scrollTo(Self.topID, anchor: .top)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: icon).font(.caption)
                            Text(title).font(.system(size: 12.5, weight: on ? .semibold : .medium))
                            if let n = count { Text("\(n)").font(.caption).foregroundStyle(on ? .primary : .tertiary).monospacedDigit() }
                        }
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
                        .overlay(Capsule().stroke(Color.primary.opacity(on ? 0 : 0.08)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Xem mục \(title)")
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
        }
    }

    /// Tiêu đề của mục đang xem, nút riêng của mục ở bên phải.
    private func header<Accessory: View>(_ title: String, icon: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            accessory()
        }
    }

    private func sectionEmpty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 30)
    }

    /// Bách khoa còn trống: giải thích cách có mục, và cho đọc lại các màn hình đã dịch trước đây (chưa được đưa vào).
    private var loreEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 28)).foregroundStyle(.quaternary)
            Text(search.isEmpty
                 ? "Bách khoa ghi lại địa danh, thế lực, đội quân và khái niệm của thế giới game.\nMỗi khi bạn Dịch màn hình nhật ký hay bách khoa trong game, app sẽ tự thêm mục vào đây ở lần cập nhật cốt truyện kế tiếp."
                 : "Không có mục bách khoa nào khớp “\(search)”.")
                .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            if search.isEmpty, !store.analyses.isEmpty {
                Button("Đọc lại \(store.analyses.count) màn hình đã dịch của game này") { tracker.rescanScreens() }
                    .buttonStyle(.borderedProminent).disabled(tracker.isRunning)
                Text("Các màn hình dịch trước đây chưa được tách ra bách khoa. App sẽ đọc lại chúng (khoảng 15 màn hình mỗi lượt) để thêm địa danh, thế lực và hồ sơ nhân vật; phần diễn biến không đổi.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    private var statusText: String {
        if tracker.isRunning { return "Đang cập nhật cốt truyện từ \(tracker.runningLines) câu mới…" }
        var bits: [String] = []
        if let s = store.story, s.updated.timeIntervalSince1970 > 0 {
            bits.append("Cập nhật lúc \(s.updated.hm) \(s.updated.formatted(.dateTime.day().month(.twoDigits)))")
            if let last = store.storyParts.first {
                bits.append("đã tóm tắt đến câu lúc \(last.to.hm) \(last.to.formatted(.dateTime.day().month(.twoDigits)))")
            }
            if !s.backend.isEmpty { bits.append(BackendKind.label(raw: s.backend)) }
        } else {
            bits.append("Game này chưa được tóm tắt lần nào")
        }
        if tracker.pendingLines > 0 { bits.append("\(tracker.pendingLines) câu mới chưa đưa vào") }
        return bits.joined(separator: " · ")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if tracker.isRunning { ProgressView().controlSize(.small) }
                else { Image(systemName: settings.storyEnabled ? "text.book.closed.fill" : "text.book.closed").foregroundStyle(Theme.accentGradient) }
                Text(statusText).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !settings.storyEnabled {
                    Button("Bật tự động") { settings.storyEnabled = true }
                        .help("Tự cập nhật cốt truyện khoảng \(settings.storyIntervalMin) phút một lần khi đang dịch, và sau khi dừng")
                }
                if store.story != nil {
                    Button("Cập nhật ngay") { tracker.updateNow() }
                        .disabled(tracker.isRunning || tracker.pendingLines + tracker.pendingScreens == 0)
                        .help("Đưa các câu mới vào cốt truyện ngay bây giờ")
                }
            }
            if let err = tracker.lastError {
                HStack(spacing: 6) {
                    Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger)
                    Button { tracker.dismissError() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            } else if let note = tracker.notice {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.book.closed").font(.system(size: 30)).foregroundStyle(.quaternary)
            Text(settings.storyEnabled
                 ? "App sẽ tự viết cốt truyện của game này từ các câu phụ đề dịch được kể từ bây giờ:\nkhoảng \(settings.storyIntervalMin) phút một lần khi đang dịch, và một lần sau khi dừng."
                 : "Bật nút cốt truyện trên thanh đầu cửa sổ (hoặc “Bật tự động” ở trên) để app tự viết cốt truyện,\ndanh sách nhân vật và diễn biến của game này từ phụ đề.")
                .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            if tracker.backlogLines > 0 {
                Button("Tóm tắt từ đầu nhật ký đến giờ (\(tracker.backlogLines) câu)") { tracker.summarizeFromStart() }
                    .buttonStyle(.borderedProminent).disabled(tracker.isRunning)
                Text("Nhật ký của game này đã có \(tracker.backlogLines) câu. Mỗi lượt đưa tối đa 150 câu vào cốt truyện, chạy nối tiếp cho tới hết.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    /// Ba đoạn mới nhất mở sẵn, các đoạn cũ thu gọn; `toggled` ghi những đoạn người dùng đã đổi so với mặc định đó.
    private func partOpen(_ p: StoryPart, index: Int) -> Bool { (index < 3) != toggled.contains(p.id) }

    private func setAllParts(open: Bool) {
        let all = store.storyParts
        toggled = Set(all.indices.filter { ($0 < 3) != open }.map { all[$0].id })
    }
}

private struct StoryPartCard: View {
    let part: StoryPart
    let expanded: Bool
    var selected = false
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var timeRange: String {
        let day = part.from.formatted(date: .abbreviated, time: .omitted)
        return part.from.hm == part.to.hm ? "\(day) \(part.from.hm)" : "\(day) \(part.from.hm) – \(part.to.hm)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                // Bấm vào mũi tên, tiêu đề hay khoảng trống cùng hàng đều mở / đóng đoạn.
                Button(action: { withAnimation(.easeInOut(duration: 0.12)) { onToggle() } }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accentStart).frame(width: 12).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(part.title).font(.system(size: 14.5, weight: .semibold)).multilineTextAlignment(.leading)
                            Text("\(part.lineCount) câu · \(timeRange) · \(BackendKind.label(raw: part.backend))")
                                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Thu gọn đoạn này" : "Mở đoạn này")
                HStack(spacing: 6) {
                    Button { Clipboard.copy("\(part.title)\n\n\(part.summary)") } label: { Image(systemName: "doc.on.doc") }.help("Copy đoạn này")
                    Button(action: onDelete) { Image(systemName: "trash") }.help("Xoá đoạn này")
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
            }
            if expanded {
                Text(part.summary)
                    .font(.system(size: 14)).lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accentStart : Color.primary.opacity(0.07), lineWidth: selected ? 2 : 1))
        .onHover { hovering = $0 }
        .contextMenu {
            Button { Clipboard.copy("\(part.title)\n\n\(part.summary)") } label: { Label("Copy đoạn này", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Xoá đoạn này", systemImage: "trash") }
        }
    }
}

private struct StoryCharacterCard: View {
    let character: StoryCharacter
    let onDelete: () -> Void
    @State private var hovering = false

    private var rows: [(String, String)] {
        [("Hiện tại", character.status), ("Vai trò", character.role), ("Tính cách", character.personality),
         ("Lai lịch", character.background), ("Quan hệ", character.relations), ("Từ nhật ký", character.journal)]
            .filter { !$0.1.isEmpty }
    }
    private var copyText: String { ([character.name] + rows.map { "\($0.0): \($0.1)" }).joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(character.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(SpeakerColors.color(for: character.name))
                Spacer(minLength: 4)
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Xoá nhân vật này")
                    .opacity(hovering ? 1 : 0)
            }
            if rows.isEmpty {
                Text("Chưa biết gì thêm").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(rows, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(value).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button { Clipboard.copy(copyText) } label: { Label("Copy", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Xoá nhân vật này", systemImage: "trash") }
        }
    }
}

/// Một mục bách khoa: tên, loại (địa danh / thế lực / khái niệm) và mô tả lấy từ màn hình nhật ký của game.
private struct StoryLoreCard: View {
    let lore: StoryLore
    let onDelete: () -> Void
    @State private var hovering = false

    private var icon: String {
        switch lore.kind {
        case "place": return "mappin.and.ellipse"
        case "faction": return "shield"
        case "concept": return "sparkles"
        default: return "book.closed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(Theme.accentStart)
                Text(lore.name).font(.system(size: 14.5, weight: .semibold))
                Text(lore.kindLabel).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                Spacer(minLength: 4)
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Xoá mục này")
                    .opacity(hovering ? 1 : 0)
            }
            Text(lore.description).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button { Clipboard.copy("\(lore.name)\n\(lore.description)") } label: { Label("Copy", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Xoá mục này", systemImage: "trash") }
        }
    }
}
