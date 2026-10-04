import Foundation

/// Thông tin máy PS5 đã đăng ký Remote Play. Lưu trong file quyền 0600 (chứa khoá đăng ký).
struct PS5Host: Codable, Equatable {
    var host: String            // địa chỉ IP
    var nickname: String
    var mac: Data               // 6 byte
    var registKey: Data         // 16 byte (ký tự hex, đệm \0)
    var rpKey: Data             // 16 byte ("morning")
    var accountID: Data         // 8 byte
    var ps5: Bool = true

    var macString: String { mac.map { String(format: "%02x", $0) }.joined(separator: ":") }
    var hostID: String { mac.map { String(format: "%02X", $0) }.joined() }
}

enum PS5Store {
    private static let name = "ps5host"

    static func load() -> PS5Host? {
        guard let s = SecretStore.get(name), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PS5Host.self, from: d)
    }

    static func save(_ h: PS5Host?) {
        guard let h, let d = try? JSONEncoder().encode(h), let s = String(data: d, encoding: .utf8) else {
            SecretStore.set("", name: name); return
        }
        SecretStore.set(s, name: name)
    }

    /// PSN Account ID dạng base64 (8 byte) như chiaki-ng hiển thị.
    static func accountID(fromBase64 s: String) -> Data? {
        guard let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == 8 else { return nil }
        return d
    }

    /// Đọc máy đã đăng ký trong chiaki-ng (nếu app đó đã cài và đã đăng ký PS5) để khỏi đăng ký lại.
    static func importFromChiaki() -> PS5Host? {
        let domain = "com.chiaki.Chiaki" as CFString
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain) }
        CFPreferencesAppSynchronize(domain)
        let count = (value("registered_hosts.size") as? Int) ?? 0
        guard count >= 1 else { return nil }
        let accountB64 = (value("settings.psn_account_id") as? String) ?? ""
        for i in 1...count {
            let p = "registered_hosts.\(i)."
            guard let rk = value(p + "rp_regist_key") as? Data, let key = value(p + "rp_key") as? Data,
                  let mac = value(p + "server_mac") as? Data, rk.count == 16, key.count == 16, mac.count == 6 else { continue }
            let target = (value(p + "target") as? Int) ?? 1_000_100
            let nick = (value(p + "server_nickname") as? String) ?? "PS5"
            return PS5Host(host: "", nickname: nick, mac: mac, registKey: rk, rpKey: key,
                           accountID: accountID(fromBase64: accountB64) ?? Data(count: 8), ps5: target >= 1_000_000)
        }
        return nil
    }
}
