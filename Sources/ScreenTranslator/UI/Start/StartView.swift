import SwiftUI
import AppKit

/// Màn hình Bắt đầu: chọn game (cột phải), chọn nguồn hình + kiểm tra cài đặt dịch (cột trái), rồi bấm Bắt đầu.
struct StartView: View {
    @ObservedObject var nav = AppNav.shared

    var body: some View {
        VStack(spacing: 0) {
            StartHeader()
            if let n = nav.notice {
                NoticeBanner(text: n) { nav.notice = nil }
            }
            HStack(alignment: .top, spacing: 16) {
                SourcePanel()
                    .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
                GameListPanel()
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            SupportBanner()
        }
    }
}

// MARK: - Thanh đầu

struct StartHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            AppLogo()
            Spacer()
            Button { WindowManager.shared.showTvInstall() } label: { Label("Cài app lên TV", systemImage: "tv") }
                .appButton(.tinted)
                .help("Cài app Subtitle TV lên TV Samsung: hiện phụ đề dịch đè lên game ngay trên TV")
            Button { HeaderBar.openGuide() } label: { Image(systemName: "questionmark") }
                .appIconButton().help("Hướng dẫn sử dụng app")
            Button { WindowManager.shared.showSettings() } label: { Image(systemName: "gearshape") }
                .appIconButton().help("Cài đặt: dịch, AI, voice, overlay, phím tắt…")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct AppLogo: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "captions.bubble.fill").font(.system(size: 20)).foregroundStyle(Theme.accentGradient)
            VStack(alignment: .leading, spacing: 0) {
                Text("Subly").font(.system(size: 16, weight: .bold))
                Text(AppInfo.versionLabel).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

struct NoticeBanner: View {
    let text: String
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { onClose() } label: { Image(systemName: "xmark") }.appIconButton(.ghost)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Theme.danger.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.danger.opacity(0.25)).frame(height: 1) }
    }
}

// MARK: - Cột trái: nguồn hình

struct SourcePanel: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var nav = AppNav.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Nguồn hình", icon: "rectangle.on.rectangle")
            HStack(spacing: 10) {
                ForEach(ProfileSource.allCases) { s in
                    SourceTile(source: s, selected: settings.source == s) { nav.setSource(s) }
                }
            }
            Group {
                switch settings.source {
                case .external: WindowListView()
                case .ps5: PS5Panel()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            EngineCard()
            StartCTA()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 0)
    }
}

/// Một ô chọn nguồn hình lớn (App trên máy / PS5 qua Chiaki).
struct SourceTile: View {
    let source: ProfileSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: source.icon).font(.system(size: 20, weight: .medium)).frame(width: 26)
                Text(source.shortLabel).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accentStart : Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Theme.accentStart : Color.primary)
            .background(RoundedRectangle(cornerRadius: AppButtonStyle.radius, style: .continuous)
                .fill(selected ? Theme.accentStart.opacity(0.10) : Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: AppButtonStyle.radius, style: .continuous)
                .strokeBorder(selected ? Theme.accentStart.opacity(0.7) : Theme.controlStroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source == .external ? "Game, phim, trình duyệt… đang mở trên máy này" : "Nhận hình PS5 qua Remote Play (Chiaki) ngay trong app")
    }
}

// MARK: App trên máy: danh sách cửa sổ

/// Danh sách cửa sổ đang mở để chọn làm màn hình game. Dùng ở màn Bắt đầu và ở nút "Đổi cửa sổ" của màn hình chính.
struct WindowListView: View {
    @ObservedObject var settings = AppSettings.shared
    var onPicked: (() -> Void)? = nil
    @State private var windows: [WindowFinder.ListedWindow] = []
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    private var area: Region? { settings.externalArea }
    private func isCurrent(_ w: WindowFinder.ListedWindow) -> Bool {
        guard let area else { return false }
        if let wid = area.windowID, windows.contains(where: { $0.id == wid }) { return wid == w.id }
        return area.appBundleID == w.app.bundleID && windows.first { $0.app.bundleID == w.app.bundleID }?.id == w.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Chọn cửa sổ đang chạy game").font(.callout.weight(.semibold))
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .appIconButton().help("Làm mới danh sách cửa sổ")
                Button { onPicked?(); RegionActions.pickGameArea() } label: { Image(systemName: "viewfinder") }
                    .appIconButton().help("Vẽ vùng thủ công: kéo chuột quanh khu vực hình của game trên màn hình")
            }
            if !hasPermission {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cần quyền Ghi màn hình để chụp cửa sổ game và đọc tên cửa sổ.").font(.caption)
                        Button("Cấp quyền…") {
                            if !CGRequestScreenCaptureAccess() {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                            hasPermission = CGPreflightScreenCaptureAccess()
                        }
                        .appButton(.tinted)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            if let area, !windows.contains(where: isCurrent) {
                currentAreaRow(area)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(windows) { w in
                        WindowRow(window: w, selected: isCurrent(w)) {
                            RegionActions.useWindow(w)
                            onPicked?()
                        }
                    }
                    if windows.isEmpty {
                        Text("Không thấy cửa sổ nào. Mở game hoặc phim trên máy này rồi bấm Làm mới.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// Vùng đang lưu nhưng không thấy trong danh sách (cửa sổ đã đóng / thu nhỏ, hoặc vùng vẽ thủ công).
    private func currentAreaRow(_ area: Region) -> some View {
        HStack(spacing: 10) {
            Image(systemName: area.followsWindow ? "macwindow.badge.plus" : "viewfinder")
                .font(.system(size: 16)).foregroundStyle(Theme.accentStart).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(area.appName ?? "Vùng vẽ thủ công").font(.callout.weight(.semibold)).lineLimit(1)
                Text(area.followsWindow ? "Đang dùng · cửa sổ hiện không thấy trên màn hình" : "Đang dùng · \(Int(area.width))×\(Int(area.height))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentStart)
        }
        .padding(.horizontal, 10).frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accentStart.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accentStart.opacity(0.6)))
    }

    private func refresh() {
        hasPermission = CGPreflightScreenCaptureAccess()
        windows = WindowFinder.visibleWindows()
    }
}

struct WindowRow: View {
    let window: WindowFinder.ListedWindow
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                } else {
                    Image(systemName: "macwindow").font(.system(size: 18)).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.app.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(window.title.isEmpty ? "\(Int(window.bounds.width))×\(Int(window.bounds.height))"
                                              : "\(window.title) · \(Int(window.bounds.width))×\(Int(window.bounds.height))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentStart) }
            }
            .padding(.horizontal, 10).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.accentStart.opacity(0.10) : (hovering ? Theme.controlFill : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Theme.accentStart.opacity(0.6) : Theme.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: PS5

struct PS5Panel: View {
    @ObservedObject var stream = PS5Stream.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var showSetup = false
    @State private var showConfig = false
    @State private var pin = ""

    private var statusColor: Color {
        switch stream.state {
        case .streaming: return .green
        case .failed: return Theme.danger
        case .idle: return .secondary
        default: return .orange
        }
    }

    var body: some View {
        Group {
            if let host = stream.host {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "playstation.logo").font(.system(size: 22)).foregroundStyle(Theme.accentGradient).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.nickname).font(.headline)
                                Text("\(host.ps5 ? "PS5" : "PS4") · \(host.host.isEmpty ? "tự dò theo MAC" : host.host)")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            Button { showConfig.toggle() } label: { Image(systemName: "info") }
                                .appIconButton().help("Xem cấu hình Remote Play (IP, MAC, account, khoá đăng ký)")
                                .popover(isPresented: $showConfig, arrowEdge: .bottom) { PS5ConfigView(host: host) }
                        }
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 8, height: 8)
                            Text(stream.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if case .needsPin = stream.state {
                            HStack {
                                SecureField("Mã PIN đăng nhập PS5", text: $pin).textFieldStyle(.roundedBorder)
                                Button("Gửi") { stream.sendPin(pin); pin = "" }.disabled(pin.isEmpty).appButton(.primary)
                            }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                            GridRow {
                                Text("Chất lượng").font(.callout).foregroundStyle(.secondary)
                                Picker("", selection: $settings.ps5Resolution) {
                                    Text("1080p").tag(4); Text("720p").tag(3)
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                            GridRow {
                                Text("Khung hình").font(.callout).foregroundStyle(.secondary)
                                Picker("", selection: $settings.ps5FPS) {
                                    Text("30 fps").tag(30); Text("60 fps").tag(60)
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                        }
                        .controlSize(.large)
                        .disabled(stream.state.isBusy)
                        Toggle(isOn: $settings.ps5AutoReconnect) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tự kết nối lại khi mất kết nối").font(.callout.weight(.medium))
                                Text("Thử lại tối đa \(settings.ps5ReconnectAttempts) lần, màn hình chính hiện trạng thái trong lúc chờ. Tắt = quay về màn hình này.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        Button(role: .destructive) { stream.disconnect(); stream.setHost(nil) } label: {
                            Label("Quên máy này", systemImage: "trash")
                        }
                        .appButton(.ghost).disabled(stream.state.isBusy)
                    }
                    .padding(.trailing, 4)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "playstation.logo").font(.system(size: 34)).foregroundStyle(Theme.accentGradient)
                    Text("Chưa có máy PS5").font(.headline)
                    Text("Nhập máy đã đăng ký trong chiaki-ng, hoặc đăng ký mới bằng mã PIN trên PS5.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { showSetup = true } label: { Label("Thiết lập PS5", systemImage: "plus") }
                        .appButton(.tinted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
        .sheet(isPresented: $showSetup) {
            PS5SetupView(onClose: { showSetup = false }).frame(width: 680, height: 620)
        }
    }
}

// MARK: Engine dịch

/// AI của ba việc (dịch phụ đề, dịch màn hình, tóm tắt & cốt truyện): engine · model và đã sẵn sàng chưa.
/// Nút "Kiểm tra" thử mọi việc chưa kiểm tra; nút cài đặt mở Cài đặt → Dịch.
struct EngineCard: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var apple: AppleTranslationBackend = Pipeline.shared.apple
    @State private var testing = false
    @State private var testError: String?

    var body: some View {
        let issues = Readiness.allTasks.map { ($0, Readiness.issue($0)) }
        let blocking = issues.contains { $0.1 != nil && Readiness.isRequired($0.0) }
        let canTest = issues.contains { $0.1?.tab == .translate }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("AI DỊCH").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if canTest {
                    Button(testing ? "Đang kiểm tra…" : "Kiểm tra") { test() }
                        .appButton(.tinted, minWidth: 96).disabled(testing)
                }
                Button { WindowManager.shared.showSettings(tab: issues.first { $0.1 != nil }?.1?.tab ?? .translate) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .appIconButton().help("Cài đặt dịch: chọn AI, model, key")
            }
            ForEach(issues, id: \.0) { task, issue in
                TaskStatusRow(task: task, issue: issue)
            }
            if let testError {
                Text(testError).font(.caption).foregroundStyle(Theme.danger).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(blocking ? Color.orange.opacity(0.08) : Theme.controlFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(blocking ? Color.orange.opacity(0.35) : Theme.controlStroke))
    }

    private func test() {
        testing = true; testError = nil
        Task {
            testError = await Readiness.testAll().map { "Lỗi – \($0)" }
            testing = false
        }
    }
}

/// Một dòng trong thẻ AI dịch: biểu tượng việc, tên việc, engine · model, trạng thái.
struct TaskStatusRow: View {
    let task: AITask
    let issue: Readiness.Issue?

    var body: some View {
        let e = Readiness.engine(task)
        let required = Readiness.isRequired(task)
        HStack(spacing: 10) {
            Image(systemName: Readiness.taskIcon(task)).font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accentStart).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(Readiness.taskTitle(task)).font(.caption).foregroundStyle(.secondary)
                Text(e.offline ? "\(e.name) · offline" : "\(e.name) · \(e.model.isEmpty ? "chưa chọn model" : e.model)")
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let issue {
                Image(systemName: required ? "exclamationmark.triangle.fill" : "minus.circle")
                    .foregroundStyle(required ? Color.orange : Color.secondary)
                    .help(required ? issue.detail : "\(issue.detail) (Không bắt buộc khi chưa bật tự viết cốt truyện.)")
                Text(issue.title).font(.caption.weight(.medium)).foregroundStyle(required ? Color.orange : Color.secondary).lineLimit(1)
            } else {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Sẵn sàng").font(.caption.weight(.medium)).foregroundStyle(.green)
            }
        }
    }
}

// MARK: Nút bắt đầu

struct StartCTA: View {
    @ObservedObject var nav = AppNav.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var stream = PS5Stream.shared

    var body: some View {
        VStack(spacing: 6) {
            if nav.entering {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stream.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button { nav.cancelEnter() } label: { Label("Huỷ kết nối", systemImage: "xmark") }
                    .appButton(.secondary, size: .large, fill: true)
            } else {
                Button { nav.enter() } label: {
                    Label(settings.source == .ps5 ? "Kết nối & bắt đầu" : "Bắt đầu", systemImage: "play.fill")
                }
                .appButton(.primary, size: .large, fill: true)
                .keyboardShortcut(.defaultAction)
                .help("Vào màn hình chơi của “\(settings.activeProfile.name)” và bắt đầu dịch phụ đề (\(settings.hotkeyToggle.display))")
            }
        }
    }
}

// MARK: - Cột phải: danh sách game

struct GameListPanel: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var nav = AppNav.shared
    @State private var search = ""
    @State private var selecting = false             // chế độ chọn nhiều game để xoá
    @State private var selection: Set<UUID> = []

    private var games: [Profile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? settings.profiles : settings.profiles.filter { $0.name.lowercased().contains(q) }
    }
    private var allShownSelected: Bool { !games.isEmpty && games.allSatisfy { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionHeader("Chọn game", icon: "gamecontroller")
                    .fixedSize()
                Text("\(settings.profiles.count)").font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                if !selecting {
                    Button { selection = []; selecting = true } label: { Label("Chọn", systemImage: "checklist") }
                        .appButton(.ghost).disabled(settings.profiles.count <= 1)
                        .help("Chọn nhiều game cùng lúc để xoá")
                    Button { nav.showNewProfile = true } label: {
                        Label("Game mới", systemImage: "plus.circle.fill").font(.system(size: 13, weight: .bold))
                    }
                    .appButton(.primary, minWidth: 120)
                        .help("Thêm game mẫu có sẵn thuật ngữ, hoặc tạo game của riêng bạn")
                }
            }
            SearchField(text: $search, prompt: "Tìm game")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(games) { p in
                            GameCard(profile: p, selected: p.id == settings.activeProfileID,
                                     checked: selecting ? selection.contains(p.id) : nil) {
                                if selection.contains(p.id) { selection.remove(p.id) } else { selection.insert(p.id) }
                            }
                            .id(p.id)
                        }
                        if games.isEmpty {
                            Text(search.isEmpty ? "Chưa có game nào." : "Không có game nào khớp “\(search)”.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .onAppear { if let id = settings.activeProfileID { proxy.scrollTo(id, anchor: .center) } }
            }
            if selecting { selectionBar }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 0)
        .onChange(of: settings.profiles.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }

    /// Thanh dưới danh sách khi đang chọn nhiều game: chọn tất cả, xoá, xong.
    private var selectionBar: some View {
        let keepsOne = selection.count < settings.profiles.count
        return HStack(spacing: 8) {
            Button(allShownSelected ? "Bỏ chọn tất cả" : "Chọn tất cả") {
                if allShownSelected { selection.subtract(games.map(\.id)) } else { selection.formUnion(games.map(\.id)) }
            }
            .appButton(.ghost)
            Text(keepsOne ? "Đã chọn \(selection.count)" : "Phải giữ lại ít nhất 1 game")
                .font(.caption).foregroundStyle(keepsOne ? Color.secondary : Theme.danger).monospacedDigit()
            Spacer()
            Button(role: .destructive) {
                if nav.deleteProfiles(selection) { selection = []; selecting = false }
            } label: {
                Label(selection.isEmpty ? "Xoá" : "Xoá \(selection.count) game", systemImage: "trash")
            }
            .appButton(.danger).disabled(selection.isEmpty || !keepsOne)
            Button("Xong") { selection = []; selecting = false }
                .appButton().keyboardShortcut(.cancelAction)
        }
    }
}

struct GameCard: View {
    let profile: Profile
    let selected: Bool
    /// nil = bình thường; true/false = đang ở chế độ chọn nhiều (bấm thẻ để tick/bỏ tick).
    var checked: Bool? = nil
    var onToggle: () -> Void = {}
    @ObservedObject var settings = AppSettings.shared
    @State private var hovering = false

    private var detail: String {
        var parts = [profile.source.shortLabel]
        if !profile.glossary.isEmpty { parts.append("\(profile.glossary.count) thuật ngữ") }
        if !profile.speakers.isEmpty { parts.append("\(profile.speakers.count) nhân vật") }
        return parts.joined(separator: " · ")
    }

    private var highlighted: Bool { checked ?? selected }

    var body: some View {
        HStack(spacing: 12) {
            if let checked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18)).foregroundStyle(checked ? Theme.accentStart : Color.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.controlFill))
                Image(systemName: profile.source.icon).font(.system(size: 18, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if checked == nil {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accentStart)
                }
                Button { AppNav.shared.browse(profile) } label: { Label("Xem", systemImage: "eye") }
                    .appButton(.ghost)
                    .help("Vào xem cốt truyện, phụ đề và ảnh đã dịch của game này mà không cần kết nối")
                Menu {
                    Button("Đổi tên…") { AppNav.shared.renameProfile(profile) }
                    Button("Nhân bản") { AppNav.shared.duplicateProfile(profile) }
                    Divider()
                    Button("Xoá…", role: .destructive) { AppNav.shared.deleteProfile(profile) }
                        .disabled(settings.profiles.count <= 1)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 32, height: 32)
                .help("Đổi tên, nhân bản, xoá game")
            } else if selected {
                Text("Đang chọn").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(highlighted ? Theme.accentStart.opacity(0.10) : (hovering ? Theme.controlFill : Theme.cardFill)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(highlighted ? Theme.accentStart.opacity(0.7) : Theme.cardStroke, lineWidth: highlighted ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if checked != nil { onToggle() } else { AppNav.shared.switchProfile(profile) } }
        .onHover { hovering = $0 }
        .contextMenu {
            if checked == nil {
                Button("Xem cốt truyện, phụ đề…") { AppNav.shared.browse(profile) }
                Divider()
                Button("Đổi tên…") { AppNav.shared.renameProfile(profile) }
                Button("Nhân bản") { AppNav.shared.duplicateProfile(profile) }
                Button("Xoá…", role: .destructive) { AppNav.shared.deleteProfile(profile) }
                    .disabled(settings.profiles.count <= 1)
            }
        }
    }
}
