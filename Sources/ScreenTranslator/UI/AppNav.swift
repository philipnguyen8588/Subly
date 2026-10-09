import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case source, log, speakers, glossary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: return "Màn hình"
        case .log: return "Nhật ký"
        case .speakers: return "Nhân vật"
        case .glossary: return "Thuật ngữ"
        }
    }
    var icon: String {
        switch self {
        case .source: return "tv"
        case .log: return "text.bubble"
        case .speakers: return "person.2"
        case .glossary: return "character.book.closed"
        }
    }
}

/// Điều hướng dùng chung: tab đang mở, hộp tạo game mới, đổi profile.
@MainActor
final class AppNav: ObservableObject {
    static let shared = AppNav()
    @Published var tab: MainTab = .source
    @Published var showNewProfile = false

    func switchProfile(_ p: Profile) {
        let settings = AppSettings.shared
        guard p.id != settings.activeProfileID else { return }
        Pipeline.shared.stop()
        RegionEditor.shared.hideAll()
        ShotViewer.shared.close()
        settings.activeProfileID = p.id
        Pipeline.shared.router.resetContext()
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

    /// Đổi nguồn hình của game đang chọn.
    func setSource(_ s: ProfileSource) {
        let settings = AppSettings.shared
        guard settings.source != s else { return }
        Pipeline.shared.stop()
        ShotViewer.shared.close()
        settings.source = s
    }
}
