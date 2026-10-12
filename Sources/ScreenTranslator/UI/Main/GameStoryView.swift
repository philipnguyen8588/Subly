import SwiftUI

/// Mục "Cốt truyện" của tab Nhật ký: cốt truyện của game đang chọn do app tự viết từ phụ đề: bài viết liền mạch,
/// dòng thời gian từng đoạn diễn biến và danh sách nhân vật.
struct GameStoryView: View {
    let search: String
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject var tracker = StoryTracker.shared
    @ObservedObject var settings = AppSettings.shared
    /// Đoạn diễn biến người dùng đã bấm mở / đóng (mặc định: ba đoạn mới nhất mở).
    @State private var toggled: Set<Int64> = []
    @State private var pendingDeletePart: StoryPart?
    @State private var pendingDeleteCharacter: StoryCharacter?
    @State private var confirmFromStart = false
    /// Mục đang thu gọn (bấm vào tiêu đề mục để mở / đóng); nhớ qua các lần mở app.
    @AppStorage("storyCollapsedNarrative") private var collapsedNarrative = false
    @AppStorage("storyCollapsedParts") private var collapsedParts = false
    @AppStorage("storyCollapsedCharacters") private var collapsedCharacters = false

    private var query: String { search.lowercased() }
    private var narrative: String { store.story?.narrative ?? "" }
    private var parts: [StoryPart] {
        guard !search.isEmpty else { return store.storyParts }
        return store.storyParts.filter { $0.title.lowercased().contains(query) || $0.summary.lowercased().contains(query) }
    }
    private var characters: [StoryCharacter] {
        let all = store.story?.characters ?? []
        guard !search.isEmpty else { return all }
        return all.filter { c in
            [c.name, c.status, c.role, c.personality, c.background, c.relations].contains { $0.lowercased().contains(query) }
        }
    }
    private var hasContent: Bool { !narrative.isEmpty || !store.storyParts.isEmpty || !(store.story?.characters ?? []).isEmpty }
    private var showNarrative: Bool { !narrative.isEmpty && (search.isEmpty || narrative.lowercased().contains(query)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                if !hasContent {
                    emptyState
                } else {
                    if showNarrative {
                        section("Cốt truyện đến hiện tại", icon: "text.book.closed", collapsed: $collapsedNarrative) {
                            Button { Clipboard.copy(narrative) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy")
                        } content: {
                            Text(narrative)
                                .font(.system(size: 14.5)).lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentStart.opacity(0.06)))
                        }
                    }
                    if !parts.isEmpty {
                        let allOpen = parts.indices.allSatisfy { partOpen(parts[$0], index: $0) }
                        section("Diễn biến  \(parts.count)", icon: "list.bullet.rectangle", collapsed: $collapsedParts) {
                            Button(allOpen ? "Thu gọn tất cả" : "Mở tất cả") {
                                withAnimation(.easeInOut(duration: 0.12)) { setAllParts(open: !allOpen) }
                            }
                            .buttonStyle(.borderless).font(.caption.weight(.medium))
                        } content: {
                            VStack(spacing: 10) {
                                ForEach(Array(parts.enumerated()), id: \.element.id) { i, p in
                                    StoryPartCard(part: p, expanded: partOpen(p, index: i) || !search.isEmpty,
                                                  onToggle: { if toggled.contains(p.id) { toggled.remove(p.id) } else { toggled.insert(p.id) } },
                                                  onDelete: { pendingDeletePart = p })
                                }
                            }
                        }
                    }
                    if !characters.isEmpty {
                        section("Nhân vật  \(characters.count)", icon: "person.2", collapsed: $collapsedCharacters) {
                            EmptyView()
                        } content: {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                                ForEach(characters) { c in
                                    StoryCharacterCard(character: c, onDelete: { pendingDeleteCharacter = c })
                                }
                            }
                        }
                    }
                    if !search.isEmpty, !showNarrative, characters.isEmpty, parts.isEmpty {
                        Text("Không có gì trong cốt truyện khớp “\(search)”.").font(.callout).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
            }
            .padding(14)
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
        .confirmationDialog("Viết lại cốt truyện từ đầu nhật ký (\(tracker.backlogLines) câu)? Cốt truyện đang có của game này sẽ bị thay.",
                            isPresented: $confirmFromStart) {
            Button("Tóm tắt từ đầu nhật ký") { tracker.summarizeFromStart() }
        }
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

    /// Một mục có tiêu đề bấm được để thu gọn / mở cả mục; `accessory` là nút riêng của mục, nằm bên phải tiêu đề.
    private func section<Accessory: View, Content: View>(_ title: String, icon: String, collapsed: Binding<Bool>,
                                                         @ViewBuilder accessory: () -> Accessory,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { withAnimation(.easeInOut(duration: 0.12)) { collapsed.wrappedValue.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                            .font(.caption2.weight(.bold)).frame(width: 10)
                        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed.wrappedValue ? "Mở mục này" : "Thu gọn mục này")
                if !collapsed.wrappedValue { accessory() }
            }
            if !collapsed.wrappedValue { content() }
        }
    }
}

private struct StoryPartCard: View {
    let part: StoryPart
    let expanded: Bool
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
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
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
         ("Lai lịch", character.background), ("Quan hệ", character.relations)]
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
