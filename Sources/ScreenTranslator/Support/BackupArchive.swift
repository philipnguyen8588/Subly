import AppKit

/// Thông tin đầu file sao lưu (manifest.json). Cùng định dạng với bản Windows để khôi phục chéo được.
struct BackupManifest: Codable {
    var format: Int
    var platform: String          // "mac" | "win"
    var appVersion: String
    var machine: String           // mã máy (HostIdentity.hash)
    var machineName: String
    var created: Double           // unix giây
    var profiles: Int
    var historyRows: Int
    var shots: Int
    /// Khoá cài đặt lưu dạng giá trị thường (cờ, @AppStorage) thay vì JSON — chỉ bản Mac ghi.
    var plainKeys: [String]?
}

/// Đóng gói / khôi phục toàn bộ dữ liệu app (cài đặt, game, lịch sử, cốt truyện, ảnh, key) thành một file zip.
///
/// Zip gồm: manifest.json, settings.json ({khoá: giá trị JSON}), secrets/<tên>.txt, history.sqlite, shots/*.jpg.
/// Không gồm: khoá thiết bị, vé, token tài khoản, giọng đọc (tải lại được), log, cache game mẫu.
/// Khôi phục: tải zip → giải nén vào restore-staging/ → khởi động lại app → lúc mở app (trước mọi thứ khác) thay dữ liệu.
enum BackupArchive {
    static let format = 1

    /// Key được sao lưu (chữ thường, không mã hoá — người dùng đã chọn vậy). device-key/session/account-token không bao giờ đi theo.
    static let secretNames = ["gemini-api-key", "openai-api-key", "anthropic-api-key", "custom-api-key", "ai-share-token", "ps5host"]

    /// Khoá cài đặt riêng của máy: không sao lưu, khi khôi phục thì giữ giá trị của máy đang dùng.
    static func isMachineKey(_ k: String) -> Bool {
        let prefixes = ["NS", "Apple", "com.apple.", "WebKit", "rpd."]
        return prefixes.contains(where: k.hasPrefix) || ["runtimeHighWater", "accountUser", "mainWindowFrame"].contains(k)
    }

    /// Khoá cùng tên nhưng khác nghĩa giữa Mac và Windows (mã phím, giọng hệ điều hành, tỉ lệ chụp):
    /// khôi phục từ hệ điều hành khác thì giữ giá trị của máy này.
    static let platformKeys: Set<String> = ["hotkeyToggle", "hotkeyAnalyze", "hotkeyVoice", "hotkeyOverlay",
                                            "voiceIdentifier", "voiceEngine", "captureScale", "screenCaptureScale",
                                            "winCaptureScale", "winScreenCaptureScale", "winVoiceRate"]

    /// Khoá app đọc bằng bool/string/integer (cờ chuyển đổi một lần, @AppStorage) — khi khôi phục ghi lại dạng thường.
    static let knownPlainKeys: Set<String> = ["voiceRateBumped", "dedupLowered", "voiceEnhancedMigrated", "localVoiceStable",
                                              "readAllMigrated", "gemini3Migrated", "engineMigrated", "summaryEngineMigrated",
                                              "thumbnailsPurged", "storyShownSection", "storyCharactersRecentFirst", "gameSetupPart"]

    static var stagingDir: URL { AppPaths.root.appendingPathComponent("restore-staging", isDirectory: true) }
    static var stagedMarker: URL { stagingDir.appendingPathComponent(".ready") }
    static var previousDir: URL { AppPaths.root.appendingPathComponent("before-restore", isDirectory: true) }
    private static var doneNote: URL { AppPaths.file("restore-done.json") }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: sao lưu

    /// Cài đặt hiện tại dạng {khoá: giá trị JSON} + danh sách khoá lưu dạng thường.
    static func currentSettings() -> (values: [String: Any], plain: [String]) {
        let domain = AppPaths.defaults.persistentDomain(forName: AppPaths.defaultsDomain) ?? [:]
        var values: [String: Any] = [:], plain: [String] = []
        for (k, v) in domain where !isMachineKey(k) {
            if let d = v as? Data {
                if let j = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { values[k] = j }
            } else if v is NSNumber || v is String {
                values[k] = v
                plain.append(k)
            }
        }
        return (values, plain.sorted())
    }

    /// Tạo file zip sao lưu trong thư mục tạm. Trả về đường dẫn zip (người gọi xoá sau khi tải lên).
    @MainActor static func export() async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("subly-backup-\(UUID().uuidString)", isDirectory: true)
        let content = work.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: content.appendingPathComponent("secrets"), withIntermediateDirectories: true)

        let rows = try HistoryStore.shared.snapshot(to: content.appendingPathComponent("history.sqlite"))
        let (values, plain) = currentSettings()
        let profileCount = AppSettings.shared.profiles.count
        let machine = BackupClient.machineID, name = HostIdentity.name

        // Phần còn lại (copy ảnh, nén) chạy nền để giao diện không khựng.
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var shots = 0
            let shotsOut = content.appendingPathComponent("shots", isDirectory: true)
            try fm.createDirectory(at: shotsOut, withIntermediateDirectories: true)
            for f in (try? fm.contentsOfDirectory(at: AppPaths.shots, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jpg" {
                try? fm.copyItem(at: f, to: shotsOut.appendingPathComponent(f.lastPathComponent))
                shots += 1
            }
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                .write(to: content.appendingPathComponent("settings.json"))
            for s in secretNames {
                if let v = SecretStore.get(s), !v.isEmpty {
                    try Data(v.utf8).write(to: content.appendingPathComponent("secrets/\(s).txt"))
                }
            }
            let manifest = BackupManifest(format: format, platform: "mac", appVersion: AppInfo.version, machine: machine,
                                          machineName: name, created: Date().timeIntervalSince1970, profiles: profileCount,
                                          historyRows: rows, shots: shots, plainKeys: plain)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(manifest).write(to: content.appendingPathComponent("manifest.json"))

            let zip = work.appendingPathComponent("subly-backup.zip")
            try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noacl", content.path, zip.path])
            try? fm.removeItem(at: content)
            return zip
        }.value
    }

    // MARK: khôi phục

    /// Giải nén bản sao lưu đã tải về vào restore-staging/ và kiểm tra; lần mở app tới sẽ áp dụng.
    static func stage(zip: URL) throws -> BackupManifest {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", "--norsrc", zip.path, stagingDir.path])
            try validateStaging()
            guard let data = try? Data(contentsOf: stagingDir.appendingPathComponent("manifest.json")),
                  let m = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
                throw Failure(message: "File sao lưu thiếu manifest.json")
            }
            guard m.format <= format else { throw Failure(message: "Bản sao lưu được tạo bởi phiên bản app mới hơn, hãy cập nhật app") }
            guard fm.fileExists(atPath: stagingDir.appendingPathComponent("settings.json").path) else {
                throw Failure(message: "File sao lưu thiếu settings.json")
            }
            try Data().write(to: stagedMarker)
            return m
        } catch {
            try? fm.removeItem(at: stagingDir)
            throw error
        }
    }

    /// Chỉ nhận đúng các file biết trước (không symlink, không đường dẫn lạ).
    private static func validateStaging() throws {
        let fm = FileManager.default
        let base = stagingDir.resolvingSymlinksInPath().path + "/"
        guard let walker = fm.enumerator(at: stagingDir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return }
        for case let u as URL in walker {
            let vals = try u.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let rel = String(u.resolvingSymlinksInPath().path.dropFirst(base.count))
            if vals.isSymbolicLink == true { throw Failure(message: "File sao lưu không hợp lệ (symlink)") }
            if vals.isDirectory == true {
                guard ["secrets", "shots"].contains(rel) else { throw Failure(message: "File sao lưu không hợp lệ (\(rel))") }
                continue
            }
            let ok = ["manifest.json", "settings.json", "history.sqlite"].contains(rel)
                || (rel.hasPrefix("secrets/") && rel.hasSuffix(".txt") && !rel.dropFirst(8).contains("/"))
                || (rel.hasPrefix("shots/") && rel.hasSuffix(".jpg") && !rel.dropFirst(6).contains("/"))
            if !ok { throw Failure(message: "File sao lưu không hợp lệ (\(rel))") }
        }
    }

    /// Gọi đầu tiên khi mở app (trước khi đọc cài đặt hay mở DB): có bản đã giải nén chờ sẵn thì thay dữ liệu bằng nó.
    static func applyStagedIfAny() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedMarker.path) else { return }
        defer { try? fm.removeItem(at: stagingDir) }
        guard let data = try? Data(contentsOf: stagingDir.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(BackupManifest.self, from: data),
              let sdata = try? Data(contentsOf: stagingDir.appendingPathComponent("settings.json")),
              var restored = (try? JSONSerialization.jsonObject(with: sdata)) as? [String: Any] else {
            Log.error("Khôi phục: bản giải nén hỏng, bỏ qua")
            return
        }
        let cross = m.platform != "mac"
        Log.info("Khôi phục dữ liệu từ \(m.machineName) (\(m.platform), \(Date(timeIntervalSince1970: m.created)))")

        // 1. Cất dữ liệu hiện tại vào before-restore/ (chỉ giữ một bản) để còn đường lui.
        try? fm.removeItem(at: previousDir)
        try? fm.createDirectory(at: previousDir.appendingPathComponent("secrets"), withIntermediateDirectories: true)
        let current = currentSettings()
        if let d = try? JSONSerialization.data(withJSONObject: current.values, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: previousDir.appendingPathComponent("settings.json"))
        }
        for s in secretNames { if let v = SecretStore.get(s) { try? Data(v.utf8).write(to: previousDir.appendingPathComponent("secrets/\(s).txt")) } }
        for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm", "shots"] {
            let src = AppPaths.file(name)
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: previousDir.appendingPathComponent(name)) }
        }

        // 2. Lịch sử + ảnh.
        let db = stagingDir.appendingPathComponent("history.sqlite")
        if fm.fileExists(atPath: db.path) { try? fm.moveItem(at: db, to: AppPaths.file("history.sqlite")) }
        let shots = stagingDir.appendingPathComponent("shots")
        if fm.fileExists(atPath: shots.path) { try? fm.moveItem(at: shots, to: AppPaths.shots) }

        // 3. Cài đặt: giữ khoá riêng của máy (và khoá khác nghĩa nếu khác hệ điều hành), còn lại thay bằng bản sao lưu.
        let old = AppPaths.defaults.persistentDomain(forName: AppPaths.defaultsDomain) ?? [:]
        var domain: [String: Any] = old.filter { isMachineKey($0.key) || (cross && platformKeys.contains($0.key)) }
        if cross, let profiles = restored["profiles"] as? [[String: Any]] {
            // Vùng chụp màn hình / cửa sổ app của máy kia không dùng được ở đây; vùng PS5 (toạ độ tỉ lệ) thì giữ.
            restored["profiles"] = profiles.map { p -> [String: Any] in
                var p = p
                if let regions = p["regions"] as? [[String: Any]] {
                    p["regions"] = regions.filter { ($0["embedded"] as? Bool) == true }
                }
                return p
            }
        }
        let plain = knownPlainKeys.union(m.plainKeys ?? [])
        for (k, v) in restored where !isMachineKey(k) && !(cross && platformKeys.contains(k)) {
            if v is NSNull { continue }
            if plain.contains(k), v is NSNumber || v is String {
                domain[k] = v
            } else if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) {
                domain[k] = d
            }
        }
        AppPaths.defaults.setPersistentDomain(domain, forName: AppPaths.defaultsDomain)
        AppPaths.defaults.synchronize()

        // 4. Key: thay hết bằng bản sao lưu (key không có trong bản sao lưu thì xoá).
        for s in secretNames {
            let f = stagingDir.appendingPathComponent("secrets/\(s).txt")
            let v = (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            SecretStore.set(v, name: s)
        }

        let note: [String: Any] = ["name": m.machineName, "platform": m.platform, "created": m.created]
        if let d = try? JSONSerialization.data(withJSONObject: note) { try? d.write(to: doneNote) }
        Log.info("Khôi phục xong: \(m.profiles) game, \(m.historyRows) dòng phụ đề, \(m.shots) ảnh")
    }

    /// Sau khi mở app: báo đã khôi phục xong (nếu vừa khôi phục).
    @MainActor static func announceIfRestored() {
        guard let d = try? Data(contentsOf: doneNote),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        try? FileManager.default.removeItem(at: doneNote)
        let name = o["name"] as? String ?? "?"
        let when = Date(timeIntervalSince1970: o["created"] as? Double ?? 0).formatted(date: .abbreviated, time: .shortened)
        let msg = "Đã khôi phục dữ liệu từ \(name) (sao lưu lúc \(when))."
        Log.info(msg)
        guard !AppSettings.shared.suppressAlerts, !CommandLine.arguments.contains("--hidden") else { return }
        let alert = NSAlert()
        alert.messageText = "Khôi phục xong"
        alert.informativeText = msg + "\n\nDữ liệu cũ của máy này được cất ở thư mục before-restore trong thư mục dữ liệu của app."
        alert.runModal()
    }

    // MARK: khởi động lại

    /// Chờ bản app cũ thoát hẳn (cờ `--after-pid`, do relaunch() truyền) để kiểm tra "chỉ một bản" không chặn bản mới.
    static func waitForPreviousInstance() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--after-pid"), i + 1 < args.count, let pid = pid_t(args[i + 1]) else { return }
        let deadline = Date().addingTimeInterval(15)
        while kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
    }

    /// Mở lại app (bản mới chờ bản này thoát) rồi thoát. Cờ test được truyền tiếp để bản mới vẫn ở chế độ test.
    @MainActor static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        var args = ["-n", Bundle.main.bundlePath, "--args", "--after-pid", "\(pid)"]
        let cur = CommandLine.arguments
        for flag in ["--multi", "--mute", "--quiet", "--hidden", "--no-web"] where cur.contains(flag) { args.append(flag) }
        for opt in ["--data-dir", "--server", "--machine-id", "--web-port", "--quit-after"] {
            if let i = cur.firstIndex(of: opt), i + 1 < cur.count { args += [opt, cur[i + 1]] }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        do { try p.run() } catch { Log.error("Không mở lại được app: \(error.localizedDescription)") }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(message: "Nén / giải nén lỗi: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
