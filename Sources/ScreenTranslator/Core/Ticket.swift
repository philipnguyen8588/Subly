import Foundation
import CryptoKit

/// Vé do server ký: "v1|hash|pub|iat|exp" + chữ ký Ed25519, dạng base64url(payload).base64url(sig).
/// App giữ vé để chạy được khi tạm mất mạng. Chống chỉnh đồng hồ lùi bằng mốc thời gian lớn nhất từng thấy.
struct Ticket {
    let raw: String
    let hash: String
    let pub: String
    let iat: Date
    let exp: Date

    private static let name = "session"
    private static let clockKey = "runtimeHighWater"

    static func current() -> Ticket? {
        guard let raw = SecretStore.get(name) else { return nil }
        return parse(raw)
    }

    static func save(_ raw: String) { SecretStore.set(raw, name: name) }
    static func clear() { SecretStore.set("", name: name) }

    static func parse(_ raw: String) -> Ticket? {
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let payload = Data(base64URL: parts[0]), let sig = Data(base64URL: parts[1]),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: RuntimeConfig.verifier),
              key.isValidSignature(sig, for: payload) else { return nil }
        let f = String(decoding: payload, as: UTF8.self).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, f[0] == "v1", let iat = Double(f[3]), let exp = Double(f[4]) else { return nil }
        return Ticket(raw: raw, hash: f[1], pub: f[2], iat: Date(timeIntervalSince1970: iat), exp: Date(timeIntervalSince1970: exp))
    }

    /// Vé thật sự dùng được: chữ ký đúng (đã kiểm ở parse), đúng máy này, đúng khoá máy này, còn hạn,
    /// và đồng hồ không bị vặn lùi so với mốc đã thấy.
    var looksValid: Bool {
        guard hash == HostIdentity.hash, pub == HostKey.publicKeyB64 else { return false }
        let now = Date()
        if now >= exp { return false }
        // Mốc thời gian lớn nhất từng thấy (lưu ở UserDefaults). now lùi quá 10 phút → nghi vặn đồng hồ, coi vé không hợp lệ.
        let hw = UserDefaults.standard.double(forKey: Self.clockKey)
        if hw > 0, now.timeIntervalSince1970 < hw - 600 { return false }
        if now.timeIntervalSince1970 > hw { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.clockKey) }
        return true
    }
}
