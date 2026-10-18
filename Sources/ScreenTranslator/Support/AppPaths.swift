import Foundation

/// Nơi app lưu dữ liệu: thư mục ~/Library/Application Support/ScreenTranslator và UserDefaults của app.
/// `--data-dir <thư mục>` (chỉ dùng khi test tự động) đổi cả hai sang chỗ riêng để không đụng dữ liệu thật đang dùng.
enum AppPaths {
    static let testDir: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }()

    static let root: URL = {
        let dir = testDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    static var shots: URL { root.appendingPathComponent("shots", isDirectory: true) }
    static var voices: URL { root.appendingPathComponent("voices", isDirectory: true) }

    /// Tên domain UserDefaults chứa cài đặt (bundle id; khi test là một suite riêng theo thư mục --data-dir).
    static let defaultsDomain: String = {
        let bid = Bundle.main.bundleIdentifier ?? "com.lipnguyen.ScreenTranslator"
        guard let t = testDir else { return bid }
        let tag = t.path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        return "\(bid).test\(tag.suffix(60))"
    }()

    static let defaults: UserDefaults = testDir == nil ? .standard : (UserDefaults(suiteName: defaultsDomain) ?? .standard)
}
