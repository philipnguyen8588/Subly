import SwiftUI

struct MainWindowView: View {
    @ObservedObject var nav = AppNav.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var viewer = ShotViewer.shared

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            TabBar(tab: $nav.tab, badges: [
                .speakers: settings.showsSpeakerNames && !settings.speakers.isEmpty ? "\(settings.speakers.count)" : nil,
            ])
            Divider()
            Group {
                switch nav.tab {
                case .source: SourceTabView()
                case .log: LogTabView()
                case .speakers: SpeakersTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBackground)
        .overlay { if let id = viewer.currentID { ShotModal(id: id) } }
        .sheet(isPresented: $nav.showNewProfile) { NewProfileSheet() }
    }
}

/// Tạo game mới: tên game + nguồn hình.
struct NewProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source: ProfileSource = .external
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Game mới", systemImage: "gamecontroller.fill").font(.title3.weight(.semibold))
            Text("Mỗi game giữ riêng nguồn hình, khung phụ đề, thuật ngữ và tên nhân vật.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Tên game (ví dụ: God of War Ragnarök)", text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(create)
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
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Tạo", action: create).buttonStyle(GradientButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private func create() {
        AppNav.shared.createProfile(name: name, source: source)
        dismiss()
    }
}

// MARK: - Header

struct HeaderBar: View {
    @ObservedObject var pipeline = Pipeline.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var router: TranslationRouter = Pipeline.shared.router
    @ObservedObject var analyzer: ScreenAnalyzer = Pipeline.shared.analyzer

    private var statusColor: Color {
        switch router.state.level { case 0: return Theme.gemini; case 1: return Theme.apple; default: return Theme.danger }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble.fill").font(.system(size: 17)).foregroundStyle(Theme.accentGradient)
                Text("ScreenTranslator").font(.headline)
            }
            .padding(.leading, 70)   // chừa chỗ nút đèn giao thông

            Button { pipeline.toggle() } label: {
                Label(pipeline.isRunning ? "Dừng" : "Bắt đầu", systemImage: pipeline.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 84)
            }
            .buttonStyle(GradientButtonStyle(tint: pipeline.isRunning
                ? LinearGradient(colors: [Theme.danger, Theme.danger.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                : Theme.accentGradient, compact: true))
            .keyboardShortcut("s", modifiers: [.command, .option])
            .help("Bắt đầu/Dừng dịch phụ đề (\(settings.hotkeyToggle.display))")

            Button { pipeline.analyzeScreen() } label: {
                Label(analyzer.isRunning ? (analyzer.progress.isEmpty ? "Đang dịch…" : analyzer.progress) : "Dịch màn hình",
                      systemImage: "doc.text.magnifyingglass").lineLimit(1)
            }
            .buttonStyle(.bordered).disabled(analyzer.isRunning)
            .help("Chụp màn hình game, dịch toàn bộ chữ và mở ảnh với bản dịch đặt đè đúng vị trí (\(settings.hotkeyAnalyze.display))")

            StatusPill(color: statusColor, text: router.state.label,
                       detail: settings.geminiAPIKey.isEmpty ? nil : "\(router.usedToday)/\(settings.rpd)")
                .lineLimit(1)

            Spacer(minLength: 8)

            ProfilePicker()
            Toggle("", isOn: $settings.voiceEnabled)
                .toggleStyle(IconToggleStyle(icon: settings.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", help: "Đọc bản dịch bằng giọng nói (\(settings.hotkeyVoice.display))"))
            Toggle("", isOn: $settings.overlayEnabled)
                .toggleStyle(IconToggleStyle(icon: "captions.bubble", help: "Hiện phụ đề dịch trên màn hình (\(settings.hotkeyOverlay.display))"))
            Button { DisplayPower.shared.sleepDisplay() } label: {
                Image(systemName: "moon.fill").font(.system(size: 13, weight: .medium)).frame(width: 30, height: 26)
            }
            .buttonStyle(.bordered)
            .help("Tắt màn hình để tiết kiệm điện (app vẫn dịch và đọc). Di chuột hoặc gõ phím để bật lại")
            Button { WindowManager.shared.showSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 26)
            }
            .buttonStyle(.bordered)
            .help("Cài đặt: ngôn ngữ, Gemini, voice, overlay, thuật ngữ, phím tắt")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

struct TabBar: View {
    @Binding var tab: MainTab
    let badges: [MainTab: String?]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 12, weight: .medium))
                        Text(t.title).font(.callout.weight(tab == t ? .semibold : .regular))
                        if let b = badges[t] ?? nil {
                            Text(b).font(.caption2.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(tab == t ? Color.white : Color.primary.opacity(0.75))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tab == t ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

struct ProfilePicker: View {
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Menu {
            ForEach(settings.profiles) { p in
                Button { AppNav.shared.switchProfile(p) } label: {
                    Label(p.name, systemImage: p.id == settings.activeProfileID ? "checkmark" : p.source.icon)
                }
            }
            Divider()
            Button { AppNav.shared.showNewProfile = true } label: { Label("Game mới…", systemImage: "plus") }
            Button("Đổi tên, xoá game…") { WindowManager.shared.showSettings() }
        } label: {
            Label(settings.activeProfile.name, systemImage: "gamecontroller").lineLimit(1)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Game đang dịch. Mỗi game có nguồn hình, khung phụ đề, thuật ngữ và tên nhân vật riêng")
    }
}

// MARK: - Tab: Nhân vật

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
                            Text("Nhân vật đã học").font(.headline)
                            Text("\(settings.speakers.count)").font(.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                            Spacer()
                            TextField("Thêm tên…", text: $newName)
                                .textFieldStyle(.roundedBorder).frame(width: 180)
                                .onSubmit(add)
                            Button("Thêm", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            if !settings.speakers.isEmpty {
                                Button("Xoá hết", role: .destructive) { settings.speakers = [] }
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
