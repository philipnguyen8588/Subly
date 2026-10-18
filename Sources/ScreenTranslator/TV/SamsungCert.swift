import AppKit
import Foundation
import Network

/// Xin chứng chỉ Samsung (author + distributor có DUID của TV) mà không cần Certificate Manager.
/// Port từ windows/ScreenTranslator/TV/SamsungCert.cs (cách làm theo tool mã nguồn mở Apps2Samsung, MIT):
///   1. Mở trang đăng nhập Samsung Account trên trình duyệt; người dùng tự đăng nhập.
///   2. Samsung POST token về http://localhost:4794/signin/callback (máy này nghe cổng đó).
///   3. Tạo khoá RSA + CSR, gửi svdca.samsungqbe.com ký; CSR distributor ghi DUID của các TV.
///   4. Ghép author.p12 / distributor.p12 (kèm CA trung gian) để ký app.
/// Thư mục chứng chỉ cộng dồn DUID (tối đa 10); lần sau chỉ xin lại distributor, author giữ nguyên khoá → app đã cài
/// trên TV cũ vẫn cập nhật được. Định dạng thư mục giống hệt bản Windows (chép qua lại giữa hai máy được).
enum SamsungCert {
    static let signIn = "https://account.samsung.com/accounts/be1dce529476c1a6d407c4c7578c31bd/signInGate"
    static let clientId = "v285zxnl3h"   // client id của Tizen Studio
    static let state = "accountcheckdogeneratedstatetext"
    static let port: UInt16 = 4794        // Samsung chỉ chấp nhận redirect về đúng cổng này
    static let maxDuids = 10
    /// Đổi được khi kiểm thử với máy chủ giả (biến môi trường SUBLY_TV_CERT_API).
    static var api: String { ProcessInfo.processInfo.environment["SUBLY_TV_CERT_API"] ?? "https://svdca.samsungqbe.com/apis" }

    struct Auth { let accessToken, userId, email: String }

    /// Xin (hoặc xin lại) chứng chỉ vào `dir` cho các DUID (cộng với DUID đã có trong dir). `caDir`: CA của Samsung.
    static func request(dir: URL, newDuids: [String], caDir: URL, log: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func p(_ n: String) -> URL { dir.appendingPathComponent(n) }
        var duids = ((try? String(contentsOf: p("duids.txt"), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for d in newDuids where !duids.contains(d) { duids.append(d) }
        if duids.count > maxDuids { duids = Array(duids.suffix(maxDuids)) }

        let auth = try await login(log: log)

        let key: SecKey, password: String
        if fm.fileExists(atPath: p("author.p12").path), let pw = try? String(contentsOf: p("password.txt"), encoding: .utf8) {
            password = pw.trimmingCharacters(in: .whitespacesAndNewlines)
            key = try TvKeys.loadP12(p("author.p12"), password: password).key
            log("Dùng lại chứng chỉ tác giả có sẵn, chỉ xin lại chứng chỉ phân phối.")
        } else {
            var raw = [UInt8](repeating: 0, count: 18)
            _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
            password = Data(raw).base64EncodedString().replacingOccurrences(of: "+", with: "x").replacingOccurrences(of: "/", with: "y")
            key = try TvKeys.newRSAKey()
            log("Xin chứng chỉ tác giả…")
            let author = try await post("v3/authors", auth, try csr(key, cn: "Subly", email: nil, san: nil), "author.csr", nil)
            try author.write(to: p("signed_author.cer"))
            try TvKeys.writeP12(p("author.p12"), key: key, signed: author, caFile: caDir.appendingPathComponent("vd_tizen_dev_author_ca.cer"), password: password)
            try password.write(to: p("password.txt"), atomically: true, encoding: .utf8)
        }

        log("Xin chứng chỉ phân phối cho TV: " + duids.joined(separator: ", "))
        let req = try csr(key, cn: "TizenSDK", email: auth.email, san: ["URN:tizen:packageid="] + duids.map { "URN:tizen:deviceid=" + $0 })
        let extra = [("privilege_level", "public"), ("developer_type", "Individual")]
        try await post("v1/distributors", auth, req, "distributor.csr", extra).write(to: p("device-profile.xml"))
        let dist = try await post("v3/distributors", auth, req, "distributor.csr", extra)
        try dist.write(to: p("signed_distributor.cer"))
        try TvKeys.writeP12(p("distributor.p12"), key: key, signed: dist, caFile: caDir.appendingPathComponent("vd_tizen_dev_public2.crt"), password: password)
        try (duids.joined(separator: "\n") + "\n").write(to: p("duids.txt"), atomically: true, encoding: .utf8)
        log("Đã có chứng chỉ Samsung cho TV này.")
    }

    // MARK: 1–2. Đăng nhập Samsung Account

    private final class LoginWaiter: @unchecked Sendable {
        let lock = NSLock()
        var cont: CheckedContinuation<Auth, Error>?
        var listener: NWListener?
        func finish(_ r: Result<Auth, Error>) {
            lock.lock()
            let c = cont; cont = nil
            let l = listener; listener = nil
            lock.unlock()
            l?.cancel()
            c?.resume(with: r)
        }
    }

    static func login(log: @escaping (String) -> Void) async throws -> Auth {
        let waiter = LoginWaiter()
        let queue = DispatchQueue(label: "subly.tv.login")
        let listener: NWListener
        do { listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) }
        catch { throw TvKeys.TvKeyError(message: "Không mở được cổng \(port) để nhận đăng nhập Samsung (Certificate Manager / Tizen Studio đang mở?): \(error.localizedDescription)") }
        waiter.listener = listener

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Auth, Error>) in
                waiter.cont = c
                listener.stateUpdateHandler = { st in
                    switch st {
                    case .failed(let e):
                        waiter.finish(.failure(TvKeys.TvKeyError(message: "Không mở được cổng \(port) để nhận đăng nhập Samsung (Certificate Manager / Tizen Studio đang mở?): \(e.localizedDescription)")))
                    case .ready:
                        let redirect = "http://localhost:\(port)/signin/callback".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                        let url = "\(signIn)?locale=&clientId=\(clientId)&redirect_uri=\(redirect)&state=\(state)&tokenType=TOKEN"
                        log("Đang mở trang đăng nhập Samsung Account trên trình duyệt — đăng nhập để tiếp tục…")
                        if ProcessInfo.processInfo.environment["SUBLY_TV_CERT_NOBROWSER"] == nil, let u = URL(string: url) {
                            DispatchQueue.main.async { if !NSWorkspace.shared.open(u) { log("Không tự mở được trình duyệt. Mở link này: " + url) } }
                        }
                    default: break
                    }
                }
                listener.newConnectionHandler = { conn in
                    // Chỉ nhận từ chính máy này.
                    guard isLoopback(conn.endpoint) else { conn.cancel(); return }
                    conn.start(queue: queue)
                    readRequest(conn, Data()) { method, path, body in
                        let auth = method == "POST" && path.hasPrefix("/signin/callback") ? parseCallback(body) : nil
                        let msg = auth != nil ? "✅ Đã đăng nhập Samsung. Đóng trang này và quay lại Subly." : "Phản hồi đăng nhập không hợp lệ."
                        let html = Data("<html><meta charset=\"utf-8\"><body style=\"font:20px -apple-system,sans-serif;padding:40px\">\(msg)</body></html>".utf8)
                        let head = "HTTP/1.1 \(auth != nil ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nConnection: close\r\n\r\n"
                        conn.send(content: Data(head.utf8) + html, completion: .contentProcessed { _ in conn.cancel() })
                        guard let auth else { return }
                        if auth.email.isEmpty {
                            waiter.finish(.failure(TvKeys.TvKeyError(message: "Tài khoản Samsung không trả về email; chứng chỉ phân phối cần email.")))
                        } else {
                            log("Đã đăng nhập Samsung: " + auth.email)
                            waiter.finish(.success(auth))
                        }
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 600) {
                    waiter.finish(.failure(TvKeys.TvKeyError(message: "Hết thời gian chờ đăng nhập Samsung (10 phút).")))
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    private static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let h, _) = e else { return false }
        switch h {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        default: return false
        }
    }

    /// Đọc một yêu cầu HTTP (dòng đầu + header + thân theo Content-Length).
    private static func readRequest(_ conn: NWConnection, _ buf: Data, _ done: @escaping (String, String, Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            var buf = buf
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines.first?.split(separator: " ").map(String.init) ?? []
                let len = lines.dropFirst().compactMap { l -> Int? in
                    let kv = l.split(separator: ":", maxSplits: 1)
                    return kv.count == 2 && kv[0].lowercased() == "content-length" ? Int(kv[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let body = buf[r.upperBound...]
                if body.count >= len || complete || error != nil {
                    done(parts.first ?? "", parts.count > 1 ? parts[1] : "", Data(body.prefix(len)))
                    return
                }
            } else if complete || error != nil || buf.count > 1 << 20 {
                conn.cancel(); return
            }
            readRequest(conn, buf, done)
        }
    }

    /// Thân form-urlencoded: state=…&code=<JSON có access_token, userId, inputEmailID>.
    private static func parseCallback(_ body: Data) -> Auth? {
        var form: [String: String] = [:]
        for kv in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let p = kv.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
            if p.count == 2 { form[p[0]] = p[1] }
        }
        guard form["state"] == state, let code = form["code"],
              let j = try? JSONSerialization.jsonObject(with: Data(code.utf8)) as? [String: Any],
              let token = j["access_token"] as? String, !token.isEmpty else { return nil }
        return Auth(accessToken: token, userId: j["userId"] as? String ?? "", email: j["inputEmailID"] as? String ?? "")
    }

    // MARK: 3. CSR + gửi Samsung ký

    /// CSR PKCS#10 (SHA256withRSA). Tên: CN (+ emailAddress) cùng thứ tự với bản Windows; SAN tự mã hoá để giữ
    /// nguyên "URN:" viết hoa.
    static func csr(_ key: SecKey, cn: String, email: String?, san: [String]?) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(key), let pubDer = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw TvKeys.TvKeyError(message: "Không đọc được khoá công khai")
        }
        func rdn(_ oid: String, _ tag: UInt8, _ v: String) -> Data { TvKeys.tlv(0x31, TvKeys.seq(TvKeys.oid(oid), TvKeys.tlv(tag, Data(v.utf8)))) }
        var name = rdn("2.5.4.3", 0x13, cn)                                           // PrintableString
        if let email { name += rdn("1.2.840.113549.1.9.1", 0x16, email) }             // IA5String
        let rsaAlg = TvKeys.seq(TvKeys.oid("1.2.840.113549.1.1.1"), Data([0x05, 0x00]))
        let spki = TvKeys.seq(rsaAlg, TvKeys.tlv(0x03, Data([0]) + pubDer))
        var attrs = Data()
        if let san {
            let general = san.map { TvKeys.tlv(0x86, Data($0.utf8)) }.reduce(Data(), +)   // [6] uniformResourceIdentifier
            let ext = TvKeys.seq(TvKeys.oid("2.5.29.17"), TvKeys.tlv(0x04, TvKeys.tlv(0x30, general)))
            attrs = TvKeys.seq(TvKeys.oid("1.2.840.113549.1.9.14"), TvKeys.tlv(0x31, TvKeys.seq(ext)))   // extensionRequest
        }
        let info = TvKeys.seq(TvKeys.tlv(0x02, Data([0])), TvKeys.tlv(0x30, name), spki, TvKeys.tlv(0xA0, attrs))
        let sig = try TvKeys.sign(info, key: key, .rsaSignatureMessagePKCS1v15SHA256)
        let der = TvKeys.seq(info, TvKeys.seq(TvKeys.oid("1.2.840.113549.1.1.11"), Data([0x05, 0x00])), TvKeys.tlv(0x03, Data([0]) + sig))
        return Data(TvKeys.pem(der, "CERTIFICATE REQUEST").utf8)
    }

    static func post(_ path: String, _ auth: Auth, _ csr: Data, _ fileName: String, _ extra: [(String, String)]?) async throws -> Data {
        let boundary = "subly-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\(name)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(value)\r\n".utf8)
        }
        field("access_token", auth.accessToken)
        field("user_id", auth.userId)
        for (k, v) in extra ?? [] { field(k, v) }
        field("platform", "VD")
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=csr; filename=\(fileName)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += csr
        body += Data("\r\n--\(boundary)--\r\n".utf8)

        var req = URLRequest(url: URL(string: "\(api)/\(path)")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\"\(boundary)\"", forHTTPHeaderField: "Content-Type")
        let (data, res) = try await URLSession.shared.upload(for: req, from: body)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TvKeys.TvKeyError(message: "Samsung từ chối (\(path)): HTTP \(code) \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }
}
