import Foundation

/// Lưu bí mật (API key) trong file quyền 0600 ở Application Support.
/// Không dùng Keychain vì app ký ad-hoc đổi chữ ký mỗi lần build → Keychain hỏi quyền liên tục.
enum SecretStore {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }

    private static func url(_ name: String) -> URL { dir.appendingPathComponent("\(name).secret") }

    static func get(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func set(_ value: String, name: String) -> Bool {
        let u = url(name)
        if value.isEmpty {
            try? FileManager.default.removeItem(at: u)
            return true
        }
        do {
            try value.data(using: .utf8)!.write(to: u, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
            return true
        } catch {
            Log.error("SecretStore write failed: \(error.localizedDescription)")
            return false
        }
    }
}
