import Foundation

/// Mã nguồn app Subtitle TV để ký và cài lên TV: bản mới nhất trên server (GET /v1/tv/app, zip chưa ký, có ETag nên
/// không đổi thì không tải lại), lưu ở Application Support/tv-app. Không tải được thì dùng bản đã tải lần trước, rồi tới
/// bản đóng kèm app. Cập nhật app TV chỉ cần nạp zip mới lên server (server/tvapp.go), không cần build lại Subly.
/// SUBLY_TV_BUNDLED_APP=1: luôn dùng bản đóng kèm (thử bản đang sửa trong repo trước khi nạp lên server).
enum TvAppSource {
    static var cacheDir: URL { AppPaths.root.appendingPathComponent("tv-app", isDirectory: true) }
    static var cachedApp: URL { cacheDir.appendingPathComponent("SubtitleTV", isDirectory: true) }
    private static var etagFile: URL { cacheDir.appendingPathComponent("etag") }

    struct SourceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Thư mục mã nguồn app TV sẽ cài; nil = không có bản nào (không tải được và bản build không kèm sẵn).
    static func resolve(bundled: URL, log: (String) -> Void) async -> URL? {
        let fm = FileManager.default
        let hasCache = fm.fileExists(atPath: cachedApp.appendingPathComponent("config.xml").path)
        let hasBundled = fm.fileExists(atPath: bundled.appendingPathComponent("config.xml").path)
        if ProcessInfo.processInfo.environment["SUBLY_TV_BUNDLED_APP"] != nil {
            log("App TV: dùng bản đóng kèm Subly (SUBLY_TV_BUNDLED_APP)" + version(bundled))
            return hasBundled ? bundled : nil
        }
        if let server = RuntimeConfig.server, let url = URL(string: server + "/v1/tv/app") {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 30
                req.cachePolicy = .reloadIgnoringLocalCacheData   // ETag tự quản lý (URLCache sẽ biến 304 thành 200)
                if hasCache, let tag = try? String(contentsOf: etagFile, encoding: .utf8) { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 304:
                    log("App TV: bản mới nhất trên server (đã tải trước đó)" + version(cachedApp))
                    return cachedApp
                case 200:
                    try store(data, etag: (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
                    log("App TV: đã tải bản mới nhất từ server" + version(cachedApp))
                    Log.info("TV: đã tải app TV từ server" + version(cachedApp))
                    return cachedApp
                case 404:
                    log("App TV: server chưa có app TV → dùng bản đóng kèm Subly" + version(bundled))
                    return hasBundled ? bundled : nil
                default:
                    throw SourceError(message: "server trả HTTP \(code)")
                }
            } catch {
                Log.warn("TV: không tải được app TV từ server: \(error.localizedDescription)")
                log("Không tải được app TV từ server (\(error.localizedDescription)).")
            }
        }
        if hasCache {
            log("App TV: dùng bản đã tải từ server lần trước" + version(cachedApp))
            return cachedApp
        }
        if hasBundled { log("App TV: dùng bản đóng kèm Subly" + version(bundled)) }
        return hasBundled ? bundled : nil
    }

    /// Giải nén zip tải về vào thư mục tạm, kiểm tra xong mới thay bản cũ (lỗi giữa chừng thì bản cũ vẫn còn).
    private static func store(_ zip: Data, etag: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let tmpZip = cacheDir.appendingPathComponent("download.zip")
        let stage = cacheDir.appendingPathComponent("new-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmpZip); try? fm.removeItem(at: stage) }
        try zip.write(to: tmpZip)
        try extract(tmpZip, to: stage)
        try? fm.removeItem(at: cachedApp)
        try fm.moveItem(at: stage, to: cachedApp)
        if let etag { try? etag.write(to: etagFile, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: etagFile) }
    }

    /// Giải nén app TV: chỉ nhận tên file an toàn (không ../, không đường dẫn tuyệt đối, không symlink), phải có config.xml.
    static func extract(_ zip: URL, to dir: URL) throws {
        let names = try run("/usr/bin/zipinfo", ["-1", zip.path]).split(whereSeparator: \.isNewline).map(String.init)
        for n in names where !n.hasSuffix("/") {
            if n.hasPrefix("/") || n.contains("\\") || n.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                throw SourceError(message: "zip app TV có tên file không hợp lệ: \(n)")
            }
        }
        _ = try run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", dir.path])
        let fm = FileManager.default
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw SourceError(message: "zip app TV chứa symlink: \(u.lastPathComponent)")
            }
        }
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.xml").path) else {
            throw SourceError(message: "zip app TV không có config.xml ở thư mục gốc")
        }
    }

    private static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SourceError(message: "\((exe as NSString).lastPathComponent) lỗi \(p.terminationStatus) (zip app TV hỏng?)") }
        return String(decoding: data, as: UTF8.self)
    }

    /// " (version 1.0.0)" theo config.xml, rỗng nếu không đọc được.
    static func version(_ app: URL) -> String {
        guard let xml = try? String(contentsOf: app.appendingPathComponent("config.xml"), encoding: .utf8),
              let tag = xml.range(of: #"<widget\b[^>]*>"#, options: .regularExpression),
              let r = xml[tag].range(of: #"\bversion="([^"]+)""#, options: .regularExpression) else { return "" }
        return " (version \(xml[tag][r].dropFirst(9).dropLast()))"
    }
}
