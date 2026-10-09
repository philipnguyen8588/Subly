import Foundation
import CryptoKit

/// Cặp khoá Ed25519 riêng của máy, tạo lần đầu và lưu bằng SecretStore (file 0600). Dùng để ký yêu cầu gửi server:
/// server ghi nhận public key ở lần đầu (TOFU) nên không máy nào mạo nhận được mã phần cứng của máy khác.
enum HostKey {
    private static let name = "device-key"

    private static let key: Curve25519.Signing.PrivateKey = {
        if let raw = SecretStore.get(name), let data = Data(base64URL: raw),
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return k
        }
        let k = Curve25519.Signing.PrivateKey()
        SecretStore.set(k.rawRepresentation.base64URL, name: name)
        return k
    }()

    static var publicKeyB64: String { key.publicKey.rawRepresentation.base64URL }

    static func sign(_ message: String) -> String {
        ((try? key.signature(for: Data(message.utf8)))?.base64URL) ?? ""
    }
}
