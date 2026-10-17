import SwiftUI
import AppKit

enum MainTab: String, CaseIterable, Identifiable {
    case source, story, subtitles, screens, search, game
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: return "Màn hình"
        case .subtitles: return "Phụ đề"
        case .screens: return "Dịch màn hình"
        case .story: return "Cốt truyện"
        case .search: return "Tìm kiếm"
        case .game: return "Thiết lập game"
        }
    }
    var icon: String {
        switch self {
        case .source: return "tv"
        case .subtitles: return "captions.bubble"
        case .screens: return "doc.text.magnifyingglass"
        case .story: return "text.book.closed"
        case .search: return "magnifyingglass"
        case .game: return "slider.horizontal.3"
        }
    }
    /// Tab nhật ký (có ô tìm, xuất, xoá ở bên phải thanh tab).
    var isLog: Bool { self == .subtitles || self == .screens || self == .story }
}

/// Hai màn hình của cửa sổ chính: Bắt đầu (chọn game + nguồn hình) và màn hình chơi.
enum AppScreen { case start, main }

/// Điều hướng dùng chung: màn hình đang hiện, tab, hộp tạo game mới, đổi / quản lý game, vào và rời phiên chơi.
@MainActor
final class AppNav: ObservableObject {
    static let shared = AppNav()
    @Published var screen: AppScreen = .start
    @Published var tab: MainTab = .source
    @Published var showNewProfile = false
    /// Trang đang mở trong cửa sổ Cài đặt (mở đúng trang khi báo thiếu cài đặt).
    @Published var settingsTab: SettingsView.Tab = .translate
    /// Thông báo hiện ở đầu màn Bắt đầu (ví dụ lý do vừa bị đưa về: mất kết nối PS5).
    @Published var notice: String?
    /// Đang kết nối PS5 từ màn Bắt đầu; có hình thì vào màn hình chính.
    @Published private(set) var entering = false
    /// Màn hình chính mở ở chế độ chỉ xem (nút "Xem" ở danh sách game): đọc cốt truyện, phụ đề, ảnh đã dịch
    /// mà không cần kết nối PS5 / chọn cửa sổ. Không có nút dịch, chỉ có nút quay lại để kết nối.
    @Published private(set) var browsing = false

    // MARK: vào / rời phiên

    /// Nút "Bắt đầu" / "Kết nối & bắt đầu" ở màn Bắt đầu.
    func enter() {
        let settings = AppSettings.shared
        guard screen == .start, !entering else { return }
        notice = nil
        switch settings.source {
        case .external:
            guard settings.externalArea != nil, settings.externalSubtitle != nil else {
                Pipeline.shared.showAlert("Chưa chọn cửa sổ game", "Chọn cửa sổ đang chạy game ở cột Nguồn hình (hoặc vẽ vùng thủ công) rồi bấm Bắt đầu.")
                return
            }
            guard Readiness.ensure() else { return }
            browsing = false
            screen = .main
            tab = .source
            Task { await Pipeline.shared.start() }
        case .ps5:
            guard PS5Stream.shared.host != nil else {
                Pipeline.shared.showAlert("Chưa thiết lập PS5", "Bấm “Thiết lập PS5” ở cột Nguồn hình để nhập máy từ chiaki-ng hoặc đăng ký bằng mã PIN.")
                return
            }
            guard Readiness.ensure() else { return }
            entering = true
            PS5Reconnector.shared.cancel()
            if PS5Stream.shared.isStreaming { enteredPS5() } else { PS5Coordinator.connect() }
        }
    }

    /// PS5 đã có hình sau khi bấm "Kết nối & bắt đầu".
    func enteredPS5() {
        guard entering else { return }
        entering = false
        browsing = false
        screen = .main
        tab = .source
        Task { await Pipeline.shared.start() }
    }

    /// Nút "Xem" ở danh sách game: vào màn hình chính của game đó mà không kết nối nguồn hình.
    func browse(_ p: Profile) {
        guard screen == .start else { return }
        if entering { cancelEnter() }
        if PS5Stream.shared.state != .idle { PS5Stream.shared.disconnect() }
        switchProfile(p)
        notice = nil
        browsing = true
        screen = .main
        if tab == .source || tab == .game { tab = .story }
        Log.info("Xem game '\(p.name)' (chưa kết nối)")
    }

    /// Kết nối PS5 từ màn Bắt đầu thất bại: ở lại màn Bắt đầu và hiện lý do.
    func enterFailed(_ reason: String) {
        guard entering else { return }
        entering = false
        notice = reason
    }

    /// Huỷ kết nối đang chạy ở màn Bắt đầu.
    func cancelEnter() {
        guard entering else { return }
        entering = false
        PS5Stream.shared.disconnect()
    }

    /// Rời màn hình chính: dừng dịch, ngắt PS5, đóng mọi thứ đang mở rồi về màn Bắt đầu.
    func leaveToStart(reason: String? = nil) {
        PS5Reconnector.shared.cancel()
        Pipeline.shared.stop()
        if PS5Stream.shared.state != .idle { PS5Stream.shared.disconnect() }
        RegionEditor.shared.hideAll()
        ShotViewer.shared.close()
        entering = false
        browsing = false
        screen = .start
        notice = reason
        if let reason { Log.info("Về màn hình Bắt đầu: \(reason)") }
    }

    /// Nút "Đổi game" ở màn hình chính (hỏi lại nếu đang dịch).
    func changeGame() {
        if browsing { leaveToStart(); return }
        if Pipeline.shared.isRunning || PS5Stream.shared.state.isBusy, !AppSettings.shared.suppressAlerts {
            let a = NSAlert()
            a.messageText = "Đổi game?"
            a.informativeText = AppSettings.shared.source == .ps5
                ? "App sẽ dừng dịch và ngắt kết nối PS5, rồi quay về màn hình chọn game."
                : "App sẽ dừng dịch rồi quay về màn hình chọn game."
            a.addButton(withTitle: "Đổi game")
            a.addButton(withTitle: "Huỷ")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        leaveToStart()
    }

    /// Phím tắt / nút Bắt đầu-Dừng: ở màn Bắt đầu thì đi qua bước kiểm tra và kết nối như bấm nút Bắt đầu.
    func toggleTranslation() {
        if screen == .start { enter(); return }
        if browsing { leaveToStart(); enter(); return }
        if Pipeline.shared.isRunning { Pipeline.shared.stop() } else { Task { await Pipeline.shared.start() } }
    }

    // MARK: game (profile)

    func switchProfile(_ p: Profile) {
        let settings = AppSettings.shared
        guard p.id != settings.activeProfileID else { return }
        Pipeline.shared.stop()
        RegionEditor.shared.hideAll()
        ShotViewer.shared.close()
        settings.activeProfileID = p.id
        Pipeline.shared.router.resetContext()
        notice = nil
        Log.info("Đổi sang game '\(p.name)' (\(p.source.label))")
    }

    func createProfile(name: String, source: ProfileSource) {
        let settings = AppSettings.shared
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = Profile(name: n.isEmpty ? "Game \(settings.profiles.count + 1)" : n, source: source)
        settings.profiles.append(p)
        switchProfile(p)
        tab = .source
    }

    /// Thêm các game mẫu đã chọn (kèm thuật ngữ đóng kèm app) rồi chuyển sang game đầu tiên.
    func addSampleGames(_ games: [GameCatalog.Game], source: ProfileSource) {
        let settings = AppSettings.shared
        let created = games.map { $0.makeProfile(source: source) }
        guard let first = created.first else { return }
        settings.profiles.append(contentsOf: created)
        Log.info("Thêm \(created.count) game mẫu: \(created.map(\.name).joined(separator: ", "))")
        switchProfile(first)
        tab = .source
    }

    func renameProfile(_ p: Profile) {
        let settings = AppSettings.shared
        guard let i = settings.profiles.firstIndex(where: { $0.id == p.id }) else { return }
        let name = RegionActions.askName(default: p.name, title: "Tên game", hint: "Ví dụ: God of War Ragnarök")
        settings.profiles[i].name = name
    }

    func duplicateProfile(_ p: Profile) {
        let settings = AppSettings.shared
        var c = p
        c.id = UUID(); c.name += " (bản sao)"
        c.regions = c.regions.map { var r = $0; r.id = UUID(); return r }
        settings.profiles.append(c)
        switchProfile(c)
    }

    func deleteProfile(_ p: Profile) {
        deleteProfiles([p.id])
    }

    /// Xoá nhiều game một lần (hỏi xác nhận). Luôn giữ lại ít nhất một game. Trả về true nếu đã xoá.
    @discardableResult
    func deleteProfiles(_ ids: Set<UUID>) -> Bool {
        let settings = AppSettings.shared
        let doomed = settings.profiles.filter { ids.contains($0.id) }
        guard !doomed.isEmpty, doomed.count < settings.profiles.count else { return false }
        if !settings.suppressAlerts {
            let a = NSAlert()
            if doomed.count == 1 {
                a.messageText = "Xoá game “\(doomed[0].name)”?"
                a.informativeText = "Khung phụ đề, thuật ngữ và tên nhân vật riêng của game này sẽ bị xoá. Nhật ký đã dịch vẫn giữ."
            } else {
                let shown = doomed.prefix(8).map { "• \($0.name)" }.joined(separator: "\n")
                let more = doomed.count > 8 ? "\n…và \(doomed.count - 8) game khác" : ""
                a.messageText = "Xoá \(doomed.count) game?"
                a.informativeText = "\(shown)\(more)\n\nKhung phụ đề, thuật ngữ và tên nhân vật riêng của các game này sẽ bị xoá. Nhật ký đã dịch vẫn giữ."
            }
            a.addButton(withTitle: "Xoá")
            a.addButton(withTitle: "Huỷ")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return false }
        }
        if let active = settings.activeProfileID, ids.contains(active),
           let other = settings.profiles.first(where: { !ids.contains($0.id) }) {
            switchProfile(other)
        }
        settings.profiles.removeAll { ids.contains($0.id) }
        Log.info("Xoá \(doomed.count) game: \(doomed.map(\.name).joined(separator: ", "))")
        return true
    }

    /// Đổi nguồn hình của game đang chọn.
    func setSource(_ s: ProfileSource) {
        let settings = AppSettings.shared
        guard settings.source != s else { return }
        if entering { cancelEnter() }
        Pipeline.shared.stop()
        ShotViewer.shared.close()
        settings.source = s
    }
}
