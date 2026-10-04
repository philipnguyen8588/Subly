import Foundation

/// Lấy PSN Account ID bằng cách đăng nhập trang chính thức của Sony (cùng luồng với script psn-account-id.py của chiaki-ng):
/// mở trang đăng nhập → người dùng dán URL "redirect" → đổi mã lấy token → đọc user_id → 8 byte little-endian → base64.
enum PSNAccount {
    // Client ID/secret công khai của ứng dụng Remote Play, lấy từ mã nguồn chiaki-ng.
    private static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    private static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let tokenURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"

    static var loginURL: URL {
        URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn&response_type=code&client_id=\(clientID)&redirect_uri=\(redirect)&scope=psn:clientapp&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal&")!
    }

    enum PSNError: LocalizedError {
        case noCode, http(Int, String), missing(String)
        var errorDescription: String? {
            switch self {
            case .noCode: return "URL không có tham số code. Hãy copy đúng địa chỉ của trang có chữ “redirect” sau khi đăng nhập."
            case .http(let c, let s): return "Sony trả về lỗi \(c). Mã trong URL chỉ dùng được một lần và hết hạn nhanh: đăng nhập lại rồi dán URL mới. \(s.prefix(120))"
            case .missing(let k): return "Phản hồi thiếu trường \(k)."
            }
        }
    }

    /// Tách mã uỷ quyền từ URL redirect (hoặc nhận thẳng chuỗi mã).
    static func code(from pasted: String) -> String? {
        let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = URLComponents(string: t)?.queryItems?.first(where: { $0.name == "code" })?.value, !c.isEmpty { return c }
        if !t.isEmpty, !t.contains("/"), !t.contains(" "), !t.contains("=") { return t }   // người dùng dán riêng mã
        return nil
    }

    /// user_id (số thập phân) → 8 byte little-endian → base64, đúng định dạng chiaki dùng.
    static func encode(userID: UInt64) -> String {
        var v = userID.littleEndian
        return Data(bytes: &v, count: 8).base64EncodedString()
    }

    static func accountID(fromPasted pasted: String) async throws -> String {
        guard let code = code(from: pasted) else { throw PSNError.noCode }
        let basic = "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()

        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue(basic, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=authorization_code&code=\(code)&redirect_uri=\(redirect)&".utf8)
        req.timeoutInterval = 20
        let (d1, r1) = try await URLSession.shared.data(for: req)
        let c1 = (r1 as? HTTPURLResponse)?.statusCode ?? 0
        guard c1 == 200 else { throw PSNError.http(c1, String(data: d1, encoding: .utf8) ?? "") }
        guard let j1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any], let token = j1["access_token"] as? String else {
            throw PSNError.missing("access_token")
        }

        let quoted = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        var info = URLRequest(url: URL(string: tokenURL + "/" + quoted)!)
        info.setValue(basic, forHTTPHeaderField: "Authorization")
        info.timeoutInterval = 20
        let (d2, r2) = try await URLSession.shared.data(for: info)
        let c2 = (r2 as? HTTPURLResponse)?.statusCode ?? 0
        guard c2 == 200 else { throw PSNError.http(c2, String(data: d2, encoding: .utf8) ?? "") }
        guard let j2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any] else { throw PSNError.missing("user_id") }
        let raw = (j2["user_id"] as? String) ?? (j2["user_id"] as? NSNumber)?.stringValue ?? ""
        guard let id = UInt64(raw) else { throw PSNError.missing("user_id") }
        return encode(userID: id)
    }
}
