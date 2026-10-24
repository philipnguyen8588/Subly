import Foundation

/// Cài app Subtitle TV lên TV Samsung (Tizen) ngay từ app Mac, không cần Tizen Studio.
/// Port từ windows/ScreenTranslator/TV/TvInstaller.cs:
///   1. Kết nối TV (SdbClient, TV bật Developer Mode, Host PC IP = máy này), lấy DUID.
///   2. Tìm các bộ chứng chỉ có DUID này (~/Library/Application Support/ScreenTranslator/tv-certs, ~/SamsungCertificate).
///      Không có → đăng nhập Samsung, xin chứng chỉ vào tv-certs/Subly-Auto (SamsungCert).
///   3. Lấy mã nguồn app TV mới nhất trên server (TvAppSource; mất mạng thì bản đã tải / bản đóng kèm),
///      ký (WgtSigner) rồi cài. TV báo "Author certificate not match" (app đã cài bằng chứng chỉ tác giả khác) →
///      thử bộ kế; hết bộ → hỏi gỡ app cũ rồi cài lại.
/// Bộ chứng chỉ chép từ máy Windows sang dùng được nếu mật khẩu nằm trong password.txt (file *.pwd là DPAPI của
/// Windows, Mac không giải được).
enum TvInstaller {
    /// Thư mục tv/ trong bundle (Makefile chép app TV + CA vào); chạy từ mã nguồn thì dùng windows/tizen của repo.
    /// App TV trong đó chỉ là bản dự phòng: bản dùng để cài lấy từ server (TvAppSource).
    static var tvDir: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("tv", isDirectory: true),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("SubtitleTV/config.xml").path) { return r }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("windows/tizen", isDirectory: true)
    }
    static var bundledApp: URL { tvDir.appendingPathComponent("SubtitleTV", isDirectory: true) }
    static var caDir: URL { tvDir.appendingPathComponent("ca", isDirectory: true) }
    static var certRoot: URL { AppPaths.root.appendingPathComponent("tv-certs", isDirectory: true) }
    static var sharedCertRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("SamsungCertificate", isDirectory: true) }
    static let remote = "/home/owner/share/tmp/sdk_tools/tmp/SubtitleTV.wgt"

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// nil = đủ file để cài; khác nil = lý do không cài được (bản build thiếu file). Mã nguồn app TV kiểm tra lúc cài
    /// (có thể tải từ server).
    static func missingFiles() -> String? {
        FileManager.default.fileExists(atPath: caDir.appendingPathComponent("vd_tizen_dev_author_ca.cer").path) ? nil : "Bản Subly này thiếu CA của Samsung."
    }

    /// Cài + mở app trên TV. `confirmUninstall`: hỏi người dùng có gỡ app cũ không (gọi trên main).
    static func install(ip: String, log: @escaping (String) -> Void, confirmUninstall: @escaping @MainActor () -> Bool) async throws {
        if let miss = missingFiles() { throw InstallError(message: miss) }
        guard let appSrc = await TvAppSource.resolve(bundled: bundledApp, log: log) else {
            throw InstallError(message: "Không tải được app TV từ server và bản Subly này không kèm sẵn app TV. Kiểm tra mạng rồi thử lại.")
        }
        let (appId, pkgId) = try appIds(appSrc)

        log("Kết nối TV \(ip)…")
        let sdb: SdbClient
        do { sdb = try await blocking(nil) { try SdbClient(host: ip) } }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw InstallError(message: "Không kết nối được TV \(ip). Kiểm tra: TV bật Developer Mode (Apps → bấm 1 2 3 4 5), " +
                "Host PC IP là IP máy này, đã tắt rồi mở lại TV, TV và máy tính cùng mạng.\n" + error.localizedDescription)
        }
        defer { sdb.close() }
        let duid = try await blocking(sdb) { try sdb.shell("0 getduid", timeout: 20) }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard duid.range(of: "^[A-Z0-9]{8,}$", options: .regularExpression) != nil else {
            throw InstallError(message: "Không đọc được mã DUID của TV (nhận được: '\(duid)')")
        }
        log("Mã TV (DUID): " + duid)

        var sets = certSets().filter { $0.duids.contains(duid) }
        if !sets.isEmpty {
            log("TV đã có chứng chỉ (" + sets.map(\.name).joined(separator: ", ") + ") → không cần đăng nhập Samsung.")
        } else {
            log("TV này chưa có chứng chỉ → xin chứng chỉ Samsung (cần đăng nhập Samsung Account).")
            let dir = certRoot.appendingPathComponent("Subly-Auto", isDirectory: true)
            try await SamsungCert.request(dir: dir, newDuids: [duid], caDir: caDir, log: log)
            sets = certSets().filter { $0.dir.standardizedFileURL == dir.standardizedFileURL && $0.duids.contains(duid) }
            if sets.isEmpty { throw InstallError(message: "Đã xin chứng chỉ nhưng không đọc lại được.") }
        }

        let wgt = FileManager.default.temporaryDirectory.appendingPathComponent("SubtitleTV.wgt")
        defer { try? FileManager.default.removeItem(at: wgt) }
        func installWith(_ s: CertSet) async throws -> String {
            log("Ký app bằng chứng chỉ '\(s.name)' và cài lên TV…")
            try await blocking(nil) {
                try WgtSigner.sign(src: appSrc, out: wgt, authorP12: s.dir.appendingPathComponent("author.p12"), authorPassword: s.authorPassword,
                                   distributorP12: s.dir.appendingPathComponent("distributor.p12"), distributorPassword: s.distributorPassword)
            }
            let data = try Data(contentsOf: wgt)
            try await blocking(sdb) { try sdb.push(data, to: remote) }
            let res = try await blocking(sdb) { try sdb.shell("0 vd_appinstall \(pkgId) \(remote)", timeout: 180) }
            let line = res.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { $0.range(of: "install (failed|completed)", options: .regularExpression) != nil }) ?? res.trimmingCharacters(in: .whitespacesAndNewlines)
            log(line)
            return res
        }

        var done = false, authorMismatch = false
        for s in sets {
            let res = try await installWith(s)
            if res.contains("install completed") { done = true; break }
            if res.contains("Author certificate not match") { authorMismatch = true; continue }   // thử bộ kế
            break
        }
        if !done, authorMismatch, await confirmUninstall() {
            log("Gỡ app cũ trên TV…")
            _ = try await blocking(sdb) { try sdb.shell("0 vd_appuninstall \(pkgId)", timeout: 120) }
            done = try await installWith(sets[0]).contains("install completed")
        }
        if !done {
            throw InstallError(message: authorMismatch
                ? "TV đã có Subtitle TV cài bằng chứng chỉ khác nên không cài đè được (cần gỡ app cũ)."
                : "TV không nhận gói cài (xem dòng 'install failed' ở trên).")
        }
        _ = try await blocking(sdb) { try sdb.shell("0 was_kill \(appId)", timeout: 30) }
        _ = try await blocking(sdb) { try sdb.shell("0 execute \(appId)", timeout: 30) }
        log("Xong: Subtitle TV đã cài và mở trên TV.")
        Log.info("TV: đã cài Subtitle TV lên \(ip) (DUID \(duid))")
    }

    /// id app / gói từ config.xml (<tizen:application id="…" package="…">).
    static func appIds(_ appSrc: URL) throws -> (String, String) {
        let xml = try String(contentsOf: appSrc.appendingPathComponent("config.xml"), encoding: .utf8)
        func attr(_ name: String) -> String? {
            guard let tag = xml.range(of: #"<[A-Za-z]*:?application\b[^>]*>"#, options: .regularExpression),
                  let r = xml[tag].range(of: #"\b\#(name)="([^"]+)""#, options: .regularExpression) else { return nil }
            return String(xml[tag][r].dropFirst(name.count + 2).dropLast())
        }
        guard let id = attr("id"), let pkg = attr("package") else { throw InstallError(message: "config.xml của app TV thiếu id / package") }
        return (id, pkg)
    }

    /// Chạy việc chặn (socket / ký / zip) trên luồng nền; huỷ Task thì đóng kết nối TV để lệnh đang chờ dừng ngay.
    private static func blocking<T>(_ sdb: SdbClient?, _ work: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        do {
            let r: T = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try work() }) }
                }
            } onCancel: { sdb?.close() }
            try Task.checkCancellation()
            return r
        } catch {
            if Task.isCancelled { throw CancellationError() }   // lỗi do chính việc đóng kết nối khi huỷ
            throw error
        }
    }

    // MARK: Bộ chứng chỉ

    struct CertSet {
        let name: String
        let dir: URL
        let duids: Set<String>
        let authorPassword: String
        let distributorPassword: String
    }

    /// Bộ chứng chỉ dùng được: có author.p12 + distributor.p12 + mật khẩu đọc được. Bộ của app trước, rồi
    /// ~/SamsungCertificate (Certificate Manager / chép từ máy khác). SUBLY_TV_NO_SHARED_CERTS=1 bỏ qua bộ dùng chung.
    static func certSets() -> [CertSet] {
        let fm = FileManager.default
        var roots = [certRoot]
        if ProcessInfo.processInfo.environment["SUBLY_TV_NO_SHARED_CERTS"] == nil { roots.append(sharedCertRoot) }
        var out: [CertSet] = []
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard fm.fileExists(atPath: dir.appendingPathComponent("author.p12").path),
                      fm.fileExists(atPath: dir.appendingPathComponent("distributor.p12").path),
                      let a = password(dir, "author") else { continue }
                out.append(CertSet(name: dir.lastPathComponent, dir: dir, duids: duids(dir), authorPassword: a,
                                   distributorPassword: password(dir, "distributor") ?? a))
            }
        }
        return out
    }

    static func duids(_ dir: URL) -> Set<String> {
        var set = Set<String>()
        if let t = try? String(contentsOf: dir.appendingPathComponent("duids.txt"), encoding: .utf8) {
            for l in t.split(whereSeparator: \.isNewline) where !l.trimmingCharacters(in: .whitespaces).isEmpty { set.insert(l.trimmingCharacters(in: .whitespaces)) }
        }
        if let x = try? String(contentsOf: dir.appendingPathComponent("device-profile.xml"), encoding: .utf8),
           let re = try? NSRegularExpression(pattern: "<TestDevice>([^<]+)</TestDevice>") {
            for m in re.matches(in: x, range: NSRange(x.startIndex..., in: x)) {
                if let r = Range(m.range(at: 1), in: x) { set.insert(String(x[r])) }
            }
        }
        return set
    }

    /// <which>.password.txt hoặc password.txt.
    static func password(_ dir: URL, _ which: String) -> String? {
        for f in ["\(which).password.txt", "password.txt"] {
            if let s = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }
}
