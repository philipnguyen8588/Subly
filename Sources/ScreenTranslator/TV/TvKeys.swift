import Foundation
import Security

/// Khoá RSA + chứng chỉ cho việc ký app TV: đọc / ghi .p12 (cùng định dạng với bản Windows và Certificate Manager),
/// mã hoá DER tối thiểu để dựng CSR.
/// Security framework không đọc được CA đi kèm trong .p12 và không tạo được .p12 từ khoá trong bộ nhớ, nên phần .p12
/// đi qua /usr/bin/openssl (LibreSSL có sẵn trên mọi máy Mac; đọc được cả .p12 thuật toán cũ). Mật khẩu truyền qua
/// biến môi trường, không lộ trên dòng lệnh.
enum TvKeys {
    struct TvKeyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Khoá bí mật + chuỗi chứng chỉ DER (lá trước, CA sau).
    struct Identity {
        let key: SecKey
        let chain: [Data]
    }

    static func loadP12(_ url: URL, password: String) throws -> Identity {
        let pem = String(decoding: try openssl(["pkcs12", "-in", url.path, "-passin", "env:SUBLY_P12_PASS", "-nodes"], password: password), as: UTF8.self)
        guard let keyDer = pemBlocks(pem, "PRIVATE KEY").first ?? pemBlocks(pem, "RSA PRIVATE KEY").first else {
            throw TvKeyError(message: "Không có khoá bí mật trong \(url.lastPathComponent)")
        }
        let key = try rsaPrivateKey(keyDer)
        let certs = pemBlocks(pem, "CERTIFICATE")
        let pub = SecKeyCopyPublicKey(key).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
        guard let leaf = certs.first(where: { publicKey(ofCert: $0) == pub }) else {
            throw TvKeyError(message: "Không thấy chứng chỉ khớp khoá trong \(url.lastPathComponent)")
        }
        return Identity(key: key, chain: [leaf] + certs.filter { $0 != leaf })
    }

    /// Ghép khoá + chứng chỉ Samsung vừa ký (PEM hoặc DER) + CA trung gian thành .p12.
    static func writeP12(_ url: URL, key: SecKey, signed: Data, caFile: URL, password: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("subly-tv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        var err: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw TvKeyError(message: "Không xuất được khoá: \(err?.takeRetainedValue().localizedDescription ?? "")")
        }
        let k = tmp.appendingPathComponent("key.pem"), c = tmp.appendingPathComponent("cert.pem"), ca = tmp.appendingPathComponent("ca.pem")
        try Data(pem(der, "RSA PRIVATE KEY").utf8).write(to: k)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: k.path)
        try Data(pem(certDER(signed), "CERTIFICATE").utf8).write(to: c)
        try Data(pem(certDER(try Data(contentsOf: caFile)), "CERTIFICATE").utf8).write(to: ca)
        _ = try openssl(["pkcs12", "-export", "-inkey", k.path, "-in", c.path, "-certfile", ca.path,
                         "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-passout", "env:SUBLY_P12_PASS", "-out", url.path],
                        password: password)
    }

    static func newRSAKey() throws -> SecKey {
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &err) else {
            throw TvKeyError(message: "Không tạo được khoá RSA: \(err?.takeRetainedValue().localizedDescription ?? "")")
        }
        return k
    }

    static func sign(_ data: Data, key: SecKey, _ alg: SecKeyAlgorithm) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let s = SecKeyCreateSignature(key, alg, data as CFData, &err) as Data? else {
            throw TvKeyError(message: "Ký thất bại: \(err?.takeRetainedValue().localizedDescription ?? "")")
        }
        return s
    }

    // MARK: PEM / DER

    /// Chứng chỉ dạng PEM → DER; đã là DER thì giữ nguyên.
    static func certDER(_ data: Data) -> Data {
        pemBlocks(String(decoding: data, as: UTF8.self), "CERTIFICATE").first ?? data
    }

    static func pemBlocks(_ s: String, _ label: String) -> [Data] {
        let begin = "-----BEGIN \(label)-----", end = "-----END \(label)-----"
        var out: [Data] = []
        var rest = s[...]
        while let b = rest.range(of: begin), let e = rest.range(of: end, range: b.upperBound..<rest.endIndex) {
            let b64 = rest[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
            if let d = Data(base64Encoded: String(b64)) { out.append(d) }
            rest = rest[e.upperBound...]
        }
        return out
    }

    static func pem(_ der: Data, _ label: String) -> String {
        "-----BEGIN \(label)-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END \(label)-----\n"
    }

    /// Khoá RSA từ PKCS#8 (PrivateKeyInfo) hoặc PKCS#1 (RSAPrivateKey).
    static func rsaPrivateKey(_ der: Data) throws -> SecKey {
        var pkcs1 = der
        // PKCS#8: SEQUENCE { INTEGER 0, SEQUENCE { rsaEncryption, NULL }, OCTET STRING { RSAPrivateKey } }
        if let items = derChildren(der), items.count >= 3, items[1].tag == 0x30, items[2].tag == 0x04 { pkcs1 = items[2].content }
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &err) else {
            throw TvKeyError(message: "Khoá trong .p12 không đọc được: \(err?.takeRetainedValue().localizedDescription ?? "")")
        }
        return k
    }

    static func publicKey(ofCert der: Data) -> Data? {
        guard let c = SecCertificateCreateWithData(nil, der as CFData), let k = SecCertificateCopyKey(c) else { return nil }
        return SecKeyCopyExternalRepresentation(k, nil) as Data?
    }

    /// Các phần tử con của một SEQUENCE DER (đủ cho PKCS#8; không hỗ trợ độ dài không xác định).
    private static func derChildren(_ d: Data) -> [(tag: UInt8, content: Data)]? {
        let b = [UInt8](d)
        func item(_ i: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard i + 1 < b.count else { return nil }
            var len = Int(b[i + 1]), p = i + 2
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n > 0, n <= 4, p + n <= b.count else { return nil }
                len = b[p..<p + n].reduce(0) { $0 << 8 | Int($1) }
                p += n
            }
            guard p + len <= b.count else { return nil }
            return (b[i], p, p + len)
        }
        guard let top = item(0), top.tag == 0x30 else { return nil }
        var out: [(UInt8, Data)] = []
        var i = top.start
        while i < top.end, let it = item(i) { out.append((it.tag, Data(b[it.start..<it.end]))); i = it.end }
        return out
    }

    /// Mã hoá DER: tag + độ dài + nội dung.
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        let n = content.count
        var d = Data([tag])
        if n < 0x80 { d.append(UInt8(n)) }
        else if n < 0x100 { d.append(contentsOf: [0x81, UInt8(n)]) }
        else if n < 0x10000 { d.append(contentsOf: [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]) }
        else { d.append(contentsOf: [0x83, UInt8(n >> 16), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) }
        return d + content
    }

    static func seq(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }

    static func oid(_ s: String) -> Data {
        let parts = s.split(separator: ".").compactMap { UInt64($0) }
        var body = Data([UInt8(parts[0] * 40 + parts[1])])
        for v in parts.dropFirst(2) {
            var bytes = [UInt8(v & 0x7F)]
            var x = v >> 7
            while x > 0 { bytes.insert(UInt8(x & 0x7F) | 0x80, at: 0); x >>= 7 }
            body.append(contentsOf: bytes)
        }
        return tlv(0x06, body)
    }

    // MARK: openssl

    static func openssl(_ args: [String], password: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["SUBLY_P12_PASS"] = password
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        // Đọc trước khi chờ để ống không đầy.
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: e, as: UTF8.self)
            throw TvKeyError(message: msg.contains("MAC verify") || msg.contains("mac verify")
                ? "Sai mật khẩu chứng chỉ" : "openssl lỗi: " + msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return o
    }
}
