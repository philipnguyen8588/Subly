import CryptoKit
import Foundation

/// Đóng gói + ký app Tizen (.wgt) không cần Tizen Studio: author-signature.xml và signature1.xml theo chuẩn
/// W3C XML Digital Signatures for Widgets, giống hệt `tizen package` (RSA-SHA512, SHA-512 từng file).
/// Port từ windows/ScreenTranslator/TV/WgtSigner.cs (gói ký ra đã được TV Samsung thật chấp nhận) — giữ đúng từng byte
/// của XML vì chữ ký tính trên dạng chuẩn hoá (c14n) viết tay bên dưới.
enum WgtSigner {
    static let ns = "http://www.w3.org/2000/09/xmldsig#"

    /// Ký thư mục mã nguồn app `src` thành file `out`.
    static func sign(src: URL, out: URL, authorP12: URL, authorPassword: String, distributorP12: URL, distributorPassword: String) throws {
        let fm = FileManager.default
        let base = src.standardizedFileURL.path
        var files: [String] = []
        if let e = fm.enumerator(atPath: base) {
            for case let rel as String in e {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: base + "/" + rel, isDirectory: &isDir), !isDir.boolValue else { continue }
                let name = (rel as NSString).lastPathComponent
                if rel.range(of: #"^(author-signature|signature\d*)\.xml$"#, options: .regularExpression) != nil { continue }
                if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) || name.hasSuffix(".wgt") { continue }
                files.append(rel)
            }
        }
        files.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }   // thứ tự byte, như StringComparer.Ordinal
        guard files.contains("config.xml") else { throw TvKeys.TvKeyError(message: "Không thấy config.xml của app TV") }

        let a = try TvKeys.loadP12(authorP12, password: authorPassword)
        let d = try TvKeys.loadP12(distributorP12, password: distributorPassword)
        let contents = try files.map { ($0, try Data(contentsOf: src.appendingPathComponent($0))) }
        let author = Data(try signatureXml(id: "AuthorSignature", role: "author", refs: contents, a).utf8)
        let dist = Data(try signatureXml(id: "DistributorSignature", role: "distributor", refs: [("author-signature.xml", author)] + contents, d).utf8)

        // Gói zip: 2 file chữ ký trước rồi tới mã nguồn (cùng thứ tự với bản Windows). /usr/bin/zip giữ đúng thứ tự.
        let stage = fm.temporaryDirectory.appendingPathComponent("subly-wgt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try author.write(to: stage.appendingPathComponent("author-signature.xml"))
        try dist.write(to: stage.appendingPathComponent("signature1.xml"))
        for (f, data) in contents {
            let dst = stage.appendingPathComponent(f)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dst)
        }
        try? fm.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = stage
        p.arguments = ["-q", "-X", "-D", "-9", out.path, "author-signature.xml", "signature1.xml"] + files
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TvKeys.TvKeyError(message: "Nén gói .wgt thất bại (zip \(p.terminationStatus))") }
    }

    /// Base64 xuống dòng mỗi 76 ký tự bằng "\n" (giống bản Windows / tizen CLI).
    static func b64(_ d: Data) -> String { d.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) }

    static func sha512(_ d: Data) -> Data { Data(SHA512.hash(data: d)) }

    /// Như Uri.EscapeDataString của .NET: chỉ giữ A-Z a-z 0-9 - _ . ~
    static func escape(_ s: String) -> String {
        let keep = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: keep) ?? s
    }

    static func signatureXml(id: String, role: String, refs: [(String, Data)], _ ident: TvKeys.Identity) throws -> String {
        var sb = ""
        for (uri, data) in refs {
            let escaped = uri.split(separator: "/", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: "/")
            sb += "<Reference URI=\"\(escaped)\">\n<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n<DigestValue>\(b64(sha512(data)))</DigestValue>\n</Reference>\n"
        }
        let obj = "<Object Id=\"prop\"><SignatureProperties xmlns:dsp=\"http://www.w3.org/2009/xmldsig-properties\">" +
            "<SignatureProperty Id=\"profile\" Target=\"#\(id)\"><dsp:Profile URI=\"http://www.w3.org/ns/widgets-digsig#profile\"></dsp:Profile></SignatureProperty>" +
            "<SignatureProperty Id=\"role\" Target=\"#\(id)\"><dsp:Role URI=\"http://www.w3.org/ns/widgets-digsig#role-\(role)\"></dsp:Role></SignatureProperty>" +
            "<SignatureProperty Id=\"identifier\" Target=\"#\(id)\"><dsp:Identifier></dsp:Identifier></SignatureProperty></SignatureProperties></Object>"
        // Dạng chuẩn hoá của #prop: Object kế thừa xmlns mặc định của <Signature>.
        let propDigest = b64(sha512(Data(obj.replacingOccurrences(of: "<Object Id=\"prop\">", with: "<Object xmlns=\"\(ns)\" Id=\"prop\">").utf8)))
        let signedInfo = "<SignedInfo>\n<CanonicalizationMethod Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\"></CanonicalizationMethod>\n" +
            "<SignatureMethod Algorithm=\"http://www.w3.org/2001/04/xmldsig-more#rsa-sha512\"></SignatureMethod>\n" + sb +
            "<Reference URI=\"#prop\">\n<Transforms>\n<Transform Algorithm=\"http://www.w3.org/2006/12/xml-c14n11\"></Transform>\n</Transforms>\n" +
            "<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n<DigestValue>\(propDigest)</DigestValue>\n</Reference>\n</SignedInfo>"
        // SignedInfo chuẩn hoá (exc-c14n): thêm xmlns mặc định lên chính nó.
        let c14n = Data(signedInfo.replacingOccurrences(of: "<SignedInfo>", with: "<SignedInfo xmlns=\"\(ns)\">").utf8)
        let sig = b64(try TvKeys.sign(c14n, key: ident.key, .rsaSignatureMessagePKCS1v15SHA512))
        let certs = ident.chain.map { "<X509Certificate>\n\(b64($0))\n</X509Certificate>\n" }.joined()
        return "<Signature xmlns=\"\(ns)\" Id=\"\(id)\">\n\(signedInfo)\n<SignatureValue>\(sig)</SignatureValue>\n<KeyInfo>\n<X509Data>\n\(certs)</X509Data>\n</KeyInfo>\n\(obj)\n</Signature>"
    }
}
