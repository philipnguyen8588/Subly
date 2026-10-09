import Foundation

/// Gọi server để lấy vé. Tên trường ngắn và trung tính (khớp server/api.go).
enum SessionClient {
    enum Result {
        case ticket(String)   // máy đã được duyệt
        case denied           // server trả lời nhưng không cấp vé (chờ duyệt / thu hồi / sai chữ ký…)
        case unreachable      // không gọi được server
    }

    static func fetchTicket() async -> Result {
        guard let url = URL(string: RuntimeConfig.endpoint) else { return .unreachable }
        let ts = Int(Date().timeIntervalSince1970)
        let hash = HostIdentity.hash, pub = HostKey.publicKeyB64
        let sig = HostKey.sign("s1|\(hash)|\(pub)|\(ts)")
        let body: [String: Any] = [
            "h": hash, "k": pub, "n": HostIdentity.name, "e": AppSettings.shared.userEmail,
            "u": HostIdentity.user, "m": HostIdentity.model,
            "p": "mac", "o": HostIdentity.osVersion, "v": AppInfo.version, "ts": ts, "s": sig,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .denied }
            if (obj["c"] as? Int) == 0, let t = obj["t"] as? String, !t.isEmpty { return .ticket(t) }
            return .denied
        } catch {
            return .unreachable
        }
    }
}

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
    /// Nhãn phiên bản hiện ở header / cài đặt, ví dụ "v0.1.0 (1)".
    static var versionLabel: String { "v\(version) (\(build))" }

    // Hỗ trợ: app miễn phí, liên hệ Telegram.
    static let telegramGroup = "subly_ps"
    static let telegramOwner = "lipnguyen"
    static let supportLine = "Đây là app miễn phí. Cần hỗ trợ cài đặt, liên hệ Telegram @\(telegramGroup) hoặc @\(telegramOwner)."
    /// Dạng Markdown có link bấm được (mở t.me).
    static let supportMarkdown =
        "Đây là app **miễn phí**. Cần hỗ trợ cài đặt, liên hệ Telegram [@\(telegramGroup)](https://t.me/\(telegramGroup)) hoặc [@\(telegramOwner)](https://t.me/\(telegramOwner))."
}
