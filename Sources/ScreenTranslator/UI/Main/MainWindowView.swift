import SwiftUI
import AppKit

struct MainWindowView: View {
    @ObservedObject var nav = AppNav.shared

    var body: some View {
        Group {
            switch nav.screen {
            case .start: StartView()
            case .main: MainScreen()
            }
        }
        .background(Theme.windowBackground)
        .sheet(isPresented: $nav.showNewProfile) { NewProfileSheet() }
    }
}

/// Màn hình chơi: game đang chơi + nút Đổi game, hai nút chính, các tab, thanh trạng thái.
struct MainScreen: View {
    @ObservedObject var nav = AppNav.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var viewer = ShotViewer.shared
    @ObservedObject var reconnector = PS5Reconnector.shared
    @ObservedObject var store = HistoryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            TabBar(tab: $nav.tab, badges: [
                .subtitles: store.entries.isEmpty ? nil : String(store.entries.count),
                .screens: store.analyses.isEmpty ? nil : String(store.analyses.count),
            ], hidden: nav.browsing ? [.source] : []) {
                if nav.tab.isLog { LogToolbar(section: nav.tab) }
            }
            Divider()
            Group {
                switch nav.tab {
                case .source: SourceTabView()
                case .subtitles, .screens, .story: LogPane(section: nav.tab)
                case .search: SearchTabView()
                case .game: GameSetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if reconnector.active { ReconnectOverlay() } }
            StatusBar()
        }
        .overlay { if let id = viewer.currentID { ShotModal(id: id) } }
    }
}

/// Thêm game: chọn một hoặc nhiều game mẫu (kèm sẵn thuật ngữ, từ glossaries/*.csv đóng kèm app),
/// hoặc gõ tên để tạo game trống. Ô tên đồng thời là ô tìm trong danh sách game mẫu.
struct NewProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings = AppSettings.shared
    @State private var name = ""
    @State private var source: ProfileSource = .external
    @ObservedObject private var catalog = GameCatalog.shared
    private var samples: [GameCatalog.Game] { catalog.games }
    @State private var picked: Set<String> = []      // tên game mẫu đã tick
    @FocusState private var focused: Bool

    private var query: String { name.trimmingCharacters(in: .whitespaces) }
    private var filtered: [GameCatalog.Game] {
        query.isEmpty ? samples : samples.filter { $0.matches(query) }
    }
    private func isAdded(_ g: GameCatalog.Game) -> Bool {
        settings.profiles.contains { $0.name.lowercased() == g.name.lowercased() }
    }
    /// Tên gõ vào trùng đúng một game mẫu chưa có → thêm game mẫu đó (kèm thuật ngữ) thay vì tạo game trống.
    private var exactSample: GameCatalog.Game? {
        samples.first { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame && !isAdded($0) }
    }
    private var actionTitle: String {
        if !picked.isEmpty { return "Thêm \(picked.count) game" }
        if let g = exactSample { return "Thêm “\(g.name)”" }
        if !query.isEmpty { return "Tạo “\(query)”" }
        return "Tạo game trống"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Game mới", systemImage: "gamecontroller.fill").font(.title3.weight(.semibold))
            Text("Chọn game mẫu có sẵn thuật ngữ (chọn được nhiều game), hoặc gõ tên để tạo game của riêng bạn. Mỗi game giữ riêng nguồn hình, khung phụ đề, thuật ngữ và tên nhân vật.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Tìm game mẫu hoặc nhập tên game mới", text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(create)
            sampleList
            VStack(alignment: .leading, spacing: 8) {
                Text("Lấy hình từ đâu?").font(.callout.weight(.medium))
                ForEach(ProfileSource.allCases) { s in
                    Button { source = s } label: {
                        HStack(spacing: 10) {
                            Image(systemName: s.icon).font(.system(size: 18)).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.label).font(.callout.weight(.semibold))
                                Text(s == .external ? "Game, phim, trình duyệt… đang mở trên máy Mac này. Bạn vẽ khung quanh màn hình game."
                                                    : "App kết nối Remote Play để lấy hình PS5. Bạn chơi bằng tay cầm nối thẳng với máy.")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: source == s ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(source == s ? Theme.accentStart : .secondary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 9).fill(source == s ? Theme.accentStart.opacity(0.10) : Theme.cardFill))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(source == s ? Theme.accentStart.opacity(0.6) : Theme.cardStroke))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.appButton().keyboardShortcut(.cancelAction)
                Button(actionTitle, action: create).appButton(.primary, minWidth: 90).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            focused = true
            Task { await catalog.refresh() }
        }
    }

    private var sampleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("GAME MẪU").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                Text("\(filtered.count)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if !picked.isEmpty {
                    Button("Bỏ chọn (\(picked.count))") { picked.removeAll() }.appButton(.ghost)
                }
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered, id: \.name) { g in
                        SampleGameRow(game: g, added: isAdded(g), checked: picked.contains(g.name)) {
                            if picked.contains(g.name) { picked.remove(g.name) } else { picked.insert(g.name) }
                        }
                    }
                    if filtered.isEmpty {
                        Text(samples.isEmpty ? "Không tìm thấy game mẫu nào trong app."
                                             : "Không có game mẫu nào khớp “\(query)”. Bấm “\(actionTitle)” để tạo game mới với tên này.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
                .padding(4)
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.controlStroke))
        }
    }

    private func create() {
        if !picked.isEmpty {
            AppNav.shared.addSampleGames(samples.filter { picked.contains($0.name) }, source: source)
        } else if let g = exactSample {
            AppNav.shared.addSampleGames([g], source: source)
        } else {
            AppNav.shared.createProfile(name: name, source: source)
        }
        dismiss()
    }
}

/// Một dòng game mẫu: ô tick, tên game, số thuật ngữ. Game đã có trong danh sách thì mờ và không chọn được.
struct SampleGameRow: View {
    let game: GameCatalog.Game
    let added: Bool
    let checked: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: added ? "checkmark.circle" : (checked ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 15))
                    .foregroundStyle(checked ? Theme.accentStart : Color.secondary)
                    .frame(width: 20)
                Text(game.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(added ? "Đã có" : "\(game.entries.count) thuật ngữ")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(checked ? Theme.accentStart.opacity(0.12) : (hovering && !added ? Theme.cardFill : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .opacity(added ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(added ? "Game này đã có trong danh sách của bạn" : "Chọn để thêm game này kèm \(game.entries.count) thuật ngữ")
    }
}

// MARK: - Header

struct HeaderBar: View {
    @ObservedObject var nav = AppNav.shared
    @ObservedObject var pipeline = Pipeline.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var analyzer: ScreenAnalyzer = Pipeline.shared.analyzer
    @ObservedObject var reconnector = PS5Reconnector.shared

    var body: some View {
        HStack(spacing: 12) {
            Button { AppNav.shared.changeGame() } label: { Label("Đổi game", systemImage: "chevron.left") }
                .appButton()
                .help(nav.browsing ? "Quay về màn hình chọn game" : "Dừng dịch\(settings.source == .ps5 ? ", ngắt PS5" : "") và quay về màn hình chọn game")
            CurrentGameLabel()
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            if nav.browsing {
                // Chế độ chỉ xem: chưa có nguồn hình nên không dịch được, chỉ có nút quay lại màn Bắt đầu để kết nối.
                Button { nav.leaveToStart() } label: {
                    Label(settings.source == .ps5 ? "Quay lại để kết nối PS5" : "Quay lại để kết nối", systemImage: "link")
                }
                .appButton(.primary, minWidth: 180)
                .help("Về màn hình Bắt đầu để \(settings.source == .ps5 ? "kết nối PS5" : "chọn cửa sổ game") rồi bắt đầu dịch")
                .fixedSize()
            } else {
                HStack(spacing: 8) {
                    Button { pipeline.toggle() } label: {
                        Label(pipeline.isRunning ? "Dừng dịch" : "Bắt đầu dịch", systemImage: pipeline.isRunning ? "stop.fill" : "play.fill")
                    }
                    .appButton(pipeline.isRunning ? .danger : .primary, minWidth: 140)
                    .disabled(reconnector.active)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .help("Bắt đầu / dừng dịch phụ đề (\(settings.hotkeyToggle.display))")

                    Button { pipeline.analyzeScreen() } label: {
                        Label(analyzer.isRunning ? (analyzer.progress.isEmpty ? "Đang dịch…" : analyzer.progress) : "Dịch màn hình",
                              systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: 190)
                    }
                    .appButton(.tinted, minWidth: 140)
                    .disabled(analyzer.isRunning || reconnector.active)
                    .help("Chụp màn hình game, dịch toàn bộ chữ và mở ảnh với bản dịch đặt đè đúng vị trí (\(settings.hotkeyAnalyze.display))")
                }
                .fixedSize()
            }

            HStack(spacing: 6) {
                Toggle("", isOn: $settings.voiceEnabled)
                    .toggleStyle(IconToggleStyle(icon: settings.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", help: "Đọc bản dịch bằng giọng nói (\(settings.hotkeyVoice.display))"))
                Toggle("", isOn: $settings.overlayEnabled)
                    .toggleStyle(IconToggleStyle(icon: "captions.bubble", help: "Hiện phụ đề dịch trên màn hình (\(settings.hotkeyOverlay.display))"))
                Toggle("", isOn: $settings.storyEnabled)
                    .toggleStyle(IconToggleStyle(icon: settings.storyEnabled ? "text.book.closed.fill" : "text.book.closed",
                                                 help: "Tự viết cốt truyện game từ phụ đề khi đang dịch (xem ở tab Cốt truyện)"))
                Divider().frame(height: 22).padding(.horizontal, 2)
                Button { DisplayPower.shared.sleepDisplay() } label: { Image(systemName: "moon.fill") }
                    .appIconButton()
                    .help("Tắt màn hình để tiết kiệm điện (app vẫn dịch và đọc). Di chuột hoặc gõ phím để bật lại")
                Button { Self.openGuide() } label: { Image(systemName: "questionmark") }
                    .appIconButton()
                    .help("Hướng dẫn sử dụng app")
                Button { WindowManager.shared.showSettings() } label: { Image(systemName: "gearshape") }
                    .appIconButton()
                    .help("Cài đặt: ngôn ngữ, AI, voice, overlay, thuật ngữ, phím tắt")
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
    }

    /// Mở file hướng dẫn HTML đóng kèm app bằng trình duyệt mặc định.
    static func openGuide() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "guide") {
            NSWorkspace.shared.open(url)
        } else {
            // Bản chạy từ mã nguồn (chưa đóng bundle): mở file trong repo nếu có.
            let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/guide/index.html")
            if FileManager.default.fileExists(atPath: dev.path) { NSWorkspace.shared.open(dev) }
        }
    }
}

/// Dải hỗ trợ nổi bật dưới header: app miễn phí + liên hệ Telegram (link bấm được).
struct SupportBanner: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "gift.fill").font(.system(size: 12)).foregroundStyle(Theme.accentStart)
            Text(.init(AppInfo.supportMarkdown))
                .font(.callout.weight(.semibold)).tint(Theme.accentStart)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentStart.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.accentStart.opacity(0.25)).frame(height: 1) }
    }
}

struct TabBar<Trailing: View>: View {
    @Binding var tab: MainTab
    let badges: [MainTab: String?]
    var hidden: Set<MainTab> = []
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases.filter { !hidden.contains($0) }) { t in
                Button { tab = t } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .medium))
                        Text(t.title).font(.system(size: 13, weight: tab == t ? .semibold : .medium))
                        if let b = badges[t] ?? nil {
                            Text(b).font(.caption2.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .foregroundStyle(tab == t ? Color.white : Color.primary.opacity(0.75))
                    .background(
                        RoundedRectangle(cornerRadius: AppButtonStyle.radius, style: .continuous)
                            .fill(tab == t ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

/// Tên game đang chơi + nguồn hình và trạng thái của nó (thay cho bộ chọn game cũ).
struct CurrentGameLabel: View {
    @ObservedObject var nav = AppNav.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var stream = PS5Stream.shared
    @ObservedObject var mirror = ExternalMirror.shared
    @ObservedObject var reconnector = PS5Reconnector.shared

    private var status: (color: Color, text: String) {
        if nav.browsing { return (.secondary, "Chỉ xem · chưa kết nối \(settings.source == .ps5 ? "PS5" : "cửa sổ game")") }
        switch settings.source {
        case .ps5:
            if reconnector.active { return (.orange, "Đang kết nối lại PS5…") }
            let name = stream.host?.nickname ?? "PS5"
            switch stream.state {
            case .streaming: return (.green, "\(name) · \(Int(stream.videoSize.height))p · \(stream.fps) fps")
            case .failed: return (Theme.danger, "\(name) · \(stream.state.label)")
            case .idle: return (.secondary, "\(name) · chưa kết nối")
            default: return (.orange, "\(name) · \(stream.state.label)")
            }
        case .external:
            guard let area = settings.externalArea else { return (.secondary, "Chưa chọn cửa sổ game") }
            return (mirror.error == nil ? .green : Theme.danger, area.appName ?? "Vùng màn hình \(Int(area.width))×\(Int(area.height))")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: settings.source.icon).font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accentGradient).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.activeProfile.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                }
            }
        }
        .help("Game đang chơi: \(settings.activeProfile.name) (\(settings.source.label)). Bấm Đổi game để chọn game khác.")
    }
}

/// Thanh trạng thái cuối cửa sổ: engine dịch đang dùng, quota, phím tắt.
struct StatusBar: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var pipeline = Pipeline.shared
    @ObservedObject var router: TranslationRouter = Pipeline.shared.router

    private var statusColor: Color {
        switch router.state.level { case 0: return Theme.gemini; case 1: return Theme.apple; default: return Theme.danger }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(pipeline.isRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(pipeline.isRunning ? "Đang dịch" : "Đã dừng").fontWeight(.medium)
            Text("·").foregroundStyle(.tertiary)
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(router.state.label).lineLimit(1)
            if settings.engine == .auto, !settings.geminiAPIKeys.isEmpty {
                Text("\(router.usedToday)/\(settings.geminiRPD) hôm nay").foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text("\(settings.hotkeyToggle.display) bắt đầu/dừng · \(settings.hotkeyAnalyze.display) dịch màn hình")
                .foregroundStyle(.tertiary).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.cardFill)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Phong cách dịch và ghi chú cho người dịch của game đang chọn (đầu tab Thuật ngữ).
struct TranslationStyleBox: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phong cách dịch").font(.headline)
                Picker("", selection: $settings.translationStyle) {
                    ForEach(TranslationStyle.allCases) { s in
                        Text(s == .auto ? "\(s.label) (đang là: \(TranslationStyle.resolveAuto(settings.activeProfile.name).label))" : s.label).tag(s)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Text("Quyết định giọng văn và cách xưng hô khi dịch: hiện đại (tôi – cậu, tao – mày), kỳ ảo trung cổ (tôi – ngài, ta – ngươi, Sir → ngài), thần thoại (ta – ngươi, cha – con), cổ trang Á Đông (chúa công – thuộc hạ, sư phụ – đồ nhi, bần tăng).")
                .font(.caption).foregroundStyle(.secondary)
            Text("Ghi chú cho AI dịch (tuỳ chọn)").font(.callout.weight(.medium))
            TextEditor(text: $settings.translationNote)
                .font(.callout).frame(minHeight: 120, idealHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            Text("Ví dụ: “Clive và Jill xưng anh – em”, “Cid gọi Clive là cậu”. Gửi kèm mỗi câu dịch, nên viết ngắn.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 12)
    }
}

/// Nút "Cập nhật từ game mẫu" (đầu tab Thiết lập game): tải cấu hình mới nhất của game mẫu cùng tên trên server
/// (phong cách dịch, ghi chú cho AI, thuật ngữ…) và gộp vào game đang chọn sau khi người dùng đồng ý.
struct SampleUpdateButton: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var updating = false
    @State private var updateResult = ""

    var body: some View {
        HStack(spacing: 8) {
            if !updateResult.isEmpty {
                Text(updateResult).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: .trailing).help(updateResult)
            }
            Button { updateFromSample() } label: {
                Label(updating ? "Đang tải…" : "Cập nhật từ game mẫu", systemImage: "arrow.down.circle")
            }
            .appButton().disabled(updating)
            .help("Tải cấu hình mới nhất của game mẫu cùng tên trên server: phong cách dịch, ghi chú cho AI, thuật ngữ")
        }
    }

    /// Lấy danh sách game mẫu mới nhất trên server, tìm game mẫu cùng tên với game đang chọn, hỏi lại rồi gộp vào.
    private func updateFromSample() {
        updating = true; updateResult = ""
        Task {
            defer { updating = false }
            let catalog = GameCatalog.shared
            await catalog.refresh()
            let current = settings.activeProfile
            guard let sample = catalog.game(named: current.name) else {
                updateResult = "Không có game mẫu nào tên “\(current.name)” (đổi tên game cho trùng tên game mẫu để cập nhật được)."
                return
            }
            let (merged, changes) = sample.merged(into: current)
            guard !changes.isEmpty else { updateResult = "Đã giống game mẫu “\(sample.name)”, không có gì mới."; return }
            let a = NSAlert()
            a.messageText = "Cập nhật “\(current.name)” theo game mẫu?"
            a.informativeText = changes.map { "• " + $0 }.joined(separator: "\n")
                + "\n\nThuật ngữ và tên nhân vật bạn tự thêm vẫn được giữ."
            a.addButton(withTitle: "Cập nhật")
            a.addButton(withTitle: "Huỷ")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            // Game đang chọn có thể đã đổi trong lúc hỏi: chỉ ghi khi vẫn là game đó.
            guard settings.activeProfile.id == current.id else { return }
            settings.activeProfile = merged
            updateResult = "Đã cập nhật: " + changes.joined(separator: "; ")
            Log.info("Cập nhật game “\(current.name)” từ game mẫu: \(changes.joined(separator: "; "))")
        }
    }
}

// MARK: - Thiết lập game → Tên người nói

struct SpeakersTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.showsSpeakerNames) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Game này có hiện tên người nói").font(.title3.weight(.semibold))
                            Text("Phụ đề dạng “Atreus: câu thoại”. Tắt với game/phim chỉ hiện câu thoại, không có tên.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if settings.showsSpeakerNames {
                        Picker("Tên hiện ở đâu", selection: $settings.speakerAbove) {
                            Text("Cùng dòng: “Tên: câu thoại”").tag(false)
                            Text("Dòng riêng phía trên câu thoại").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        if settings.speakerAbove {
                            Text("Dòng đầu trong khung phụ đề, nếu ngắn (1–4 từ Viết Hoa, không dấu câu) hoặc là tên đã học, được coi là tên của câu bên dưới. Nhớ vẽ khung phụ đề bao cả dòng tên.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if settings.showsSpeakerNames {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Tự học tên từ câu có dạng “Tên: …” và lưu theo game “\(settings.activeProfile.name)”.", systemImage: "sparkles")
                            Label("Khi OCR đọc sai dấu hai chấm (“Angrboda, …”) vẫn nhận ra tên đã học và sửa lại.", systemImage: "wand.and.stars")
                            Label("Không đọc tên khi phát voice; Gemini giữ nguyên tên, không dịch.", systemImage: "speaker.slash")
                            Label("Mỗi nhân vật có một màu riêng; tên hiện theo màu đó ở phụ đề, overlay và nhật ký.", systemImage: "paintpalette")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .card(padding: 14)

                if settings.showsSpeakerNames {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Tên người nói đã học").font(.headline)
                            Text("\(settings.speakers.count)").font(.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                            Spacer()
                            TextField("Thêm tên…", text: $newName)
                                .textFieldStyle(.roundedBorder).frame(width: 180)
                                .onSubmit(add)
                            Button("Thêm", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty).appButton(.tinted)
                            if !settings.speakers.isEmpty {
                                Button("Xoá hết", role: .destructive) { settings.speakers = [] }.appButton()
                            }
                        }
                        if settings.speakers.isEmpty {
                            Text("Chưa có. Tên sẽ tự xuất hiện ở đây khi app gặp câu thoại có tên người nói.")
                                .font(.callout).foregroundStyle(.tertiary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                                ForEach(settings.speakers, id: \.self) { name in
                                    HStack(spacing: 6) {
                                        Circle().fill(SpeakerColors.color(for: name)).frame(width: 10, height: 10)
                                        Text(name).fontWeight(.semibold).foregroundStyle(SpeakerColors.color(for: name)).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Button { settings.speakers.removeAll { $0 == name } } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Xoá tên này")
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardFill))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke))
                                }
                            }
                        }
                    }
                    .card(padding: 14)
                }
            }
            .padding(16)
        }
    }

    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { settings.learnSpeaker(n) }
        newName = ""
    }
}
