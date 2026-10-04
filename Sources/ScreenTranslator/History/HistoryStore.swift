import Foundation
import SQLite3
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct TranslationEntry: Identifiable, Equatable {
    let id: Int64
    let timestamp: Date
    let regionName: String
    let source: String
    let translated: String
    let backend: String
    let latencyMs: Int
    let kind: RegionKind
    let targetLang: String
    var profile: String = ""      // UUID của game lúc dịch; rỗng = dòng cũ trước khi có cột này
}

struct AnalysisLine: Codable, Equatable, Identifiable {
    var id: Int
    var source: String
    var target: String
}

/// Một khối chữ đã dịch trên ảnh chụp: toạ độ là tỉ lệ 0...1 của ảnh, gốc trên-trái.
struct ShotItem: Codable, Equatable, Identifiable {
    var id: Int
    var x, y, w, h: Double
    var lines: Int
    var source: String
    var target: String
}

struct ScreenAnalysis: Identifiable, Equatable {
    let id: Int64
    let timestamp: Date
    let regionName: String
    let summary: String
    let lines: [AnalysisLine]
    let backend: String
    let latencyMs: Int
    var profile: String = ""
    /// Vị trí từng khối chữ trên ảnh chụp (rỗng với mục cũ).
    var items: [ShotItem] = []
    var imageWidth = 0, imageHeight = 0
    /// Còn file ảnh hay không: chỉ `HistoryStore.maxShots` ảnh mới nhất được giữ, mục cũ hơn chỉ còn chữ.
    var hasImage = false
}

/// Lịch sử dịch + phân tích màn hình, SQLite thuần. Mỗi dòng gắn với một game (profile);
/// `entries` / `analyses` chỉ chứa dữ liệu của game đang chọn và tự nạp lại khi đổi game.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [TranslationEntry] = []     // mới nhất trước
    @Published private(set) var analyses: [ScreenAnalysis] = []      // mới nhất trước
    /// Game (UUID của profile) mà `entries` / `analyses` đang chứa.
    private(set) var scope = ""
    /// Số dòng có từ trước khi nhật ký được tách theo game (không gắn với game nào).
    @Published private(set) var legacyCount = 0
    private var scopeObserver: AnyCancellable?
    private var db: OpaquePointer?
    private let maxInMemory = 2000
    private let maxAnalyses = 300
    /// Số ảnh chụp "dịch màn hình" được giữ trên đĩa cho mỗi game.
    static let maxShots = 50
    nonisolated static let shotsDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenTranslator/shots", isDirectory: true)
    nonisolated static func shotURL(_ id: Int64) -> URL { shotsDir.appendingPathComponent("\(id).jpg") }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            Log.error("SQLite open failed: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_close(db); db = nil
            sqlite3_open(":memory:", &db)
        }
        exec("""
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, region TEXT NOT NULL,
            source TEXT NOT NULL, translated TEXT NOT NULL, backend TEXT NOT NULL, latency INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS history_ts ON history(ts);
        CREATE TABLE IF NOT EXISTS analyses(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, region TEXT NOT NULL,
            thumbnail BLOB, summary TEXT NOT NULL, lines TEXT NOT NULL, backend TEXT NOT NULL, latency INTEGER NOT NULL);
        PRAGMA journal_mode=WAL;
        """)
        // Bản cũ lưu ảnh chụp màn hình kèm mỗi lần dịch → xoá một lần cho nhẹ file.
        if !UserDefaults.standard.bool(forKey: "thumbnailsPurged") {
            exec("UPDATE analyses SET thumbnail = NULL; VACUUM;")
            UserDefaults.standard.set(true, forKey: "thumbnailsPurged")
        }
        if !columns("history").contains("kind") { exec("ALTER TABLE history ADD COLUMN kind TEXT NOT NULL DEFAULT 'subtitle'") }
        if !columns("history").contains("target") { exec("ALTER TABLE history ADD COLUMN target TEXT NOT NULL DEFAULT 'vi'") }
        if !columns("history").contains("profile") { exec("ALTER TABLE history ADD COLUMN profile TEXT NOT NULL DEFAULT ''") }
        if !columns("analyses").contains("profile") {
            exec("ALTER TABLE analyses ADD COLUMN profile TEXT NOT NULL DEFAULT ''")
            exec("ALTER TABLE analyses ADD COLUMN items TEXT NOT NULL DEFAULT '[]'")
            exec("ALTER TABLE analyses ADD COLUMN iw INTEGER NOT NULL DEFAULT 0")
            exec("ALTER TABLE analyses ADD COLUMN ih INTEGER NOT NULL DEFAULT 0")
        }
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
        scope = AppSettings.shared.activeProfile.id.uuidString
        entries = loadEntries(profile: scope)
        analyses = loadAnalyses(profile: scope)
        legacyCount = count("SELECT (SELECT COUNT(*) FROM history WHERE profile = '') + (SELECT COUNT(*) FROM analyses WHERE profile = '')")
        // Đổi game (ở bất kỳ đâu trong app) → nạp lại nhật ký của game mới.
        scopeObserver = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in Task { @MainActor in self?.followActiveProfile() } }
    }

    private func followActiveProfile() {
        let active = AppSettings.shared.activeProfile.id.uuidString
        guard active != scope else { return }
        scope = active
        entries = loadEntries(profile: active)
        analyses = loadAnalyses(profile: active)
    }

    private func count(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Dòng cũ không gắn với game nào (có từ trước khi nhật ký được tách theo game).
    func legacyEntries() -> [TranslationEntry] { loadEntries(profile: "") }
    func legacyAnalyses() -> [ScreenAnalysis] { loadAnalyses(profile: "") }
    func clearLegacy() {
        exec("DELETE FROM history WHERE profile = ''; DELETE FROM analyses WHERE profile = '';")
        legacyCount = 0
    }

    // MARK: helpers
    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            Log.error("SQLite: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }
    private func columns(_ table: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 1))) }
        return out
    }
    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: p)
    }

    // MARK: history
    private func loadEntries(profile: String) -> [TranslationEntry] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, region, source, translated, backend, latency, kind, target, profile FROM history WHERE profile = ? ORDER BY id DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(maxInMemory))
        var out: [TranslationEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        sqlite3_finalize(stmt)
        return out
    }

    private func row(_ stmt: OpaquePointer?) -> TranslationEntry {
        TranslationEntry(
            id: sqlite3_column_int64(stmt, 0),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            regionName: text(stmt, 2), source: text(stmt, 3), translated: text(stmt, 4),
            backend: text(stmt, 5), latencyMs: Int(sqlite3_column_int(stmt, 6)),
            kind: RegionKind(rawValue: text(stmt, 7)) ?? .subtitle, targetLang: text(stmt, 8), profile: text(stmt, 9))
    }

    func add(region: String, source: String, translated: String, backend: BackendKind, ms: Int,
             kind: RegionKind = .subtitle, target: String, profile: String) {
        let now = Date()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO history(ts, region, source, translated, backend, latency, kind, target, profile) VALUES(?,?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, region, -1, transient)
        sqlite3_bind_text(stmt, 3, source, -1, transient)
        sqlite3_bind_text(stmt, 4, translated, -1, transient)
        sqlite3_bind_text(stmt, 5, backend.rawValue, -1, transient)
        sqlite3_bind_int(stmt, 6, Int32(ms))
        sqlite3_bind_text(stmt, 7, kind.rawValue, -1, transient)
        sqlite3_bind_text(stmt, 8, target, -1, transient)
        sqlite3_bind_text(stmt, 9, profile, -1, transient)
        if sqlite3_step(stmt) != SQLITE_DONE { Log.error("SQLite insert: \(String(cString: sqlite3_errmsg(db)))") }
        sqlite3_finalize(stmt)
        let id = sqlite3_last_insert_rowid(db)
        guard profile == scope else { return }
        entries.insert(TranslationEntry(id: id, timestamp: now, regionName: region, source: source, translated: translated,
                                        backend: backend.rawValue, latencyMs: ms, kind: kind, targetLang: target, profile: profile), at: 0)
        if entries.count > maxInMemory { entries.removeLast(entries.count - maxInMemory) }
    }

    /// Xoá nhật ký phụ đề của game đang chọn.
    func clear() {
        exec("DELETE FROM history WHERE profile = '\(scope)';")
        entries.removeAll()
    }

    // MARK: analyses
    private func loadAnalyses(profile: String) -> [ScreenAnalysis] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, region, summary, lines, backend, latency, profile, items, iw, ih FROM analyses WHERE profile = ? ORDER BY id DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(maxAnalyses))
        var out: [ScreenAnalysis] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let lines = (try? JSONDecoder().decode([AnalysisLine].self, from: Data(text(stmt, 4).utf8))) ?? []
            let items = (try? JSONDecoder().decode([ShotItem].self, from: Data(text(stmt, 8).utf8))) ?? []
            out.append(ScreenAnalysis(id: id, timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                      regionName: text(stmt, 2), summary: text(stmt, 3), lines: lines,
                                      backend: text(stmt, 5), latencyMs: Int(sqlite3_column_int(stmt, 6)), profile: text(stmt, 7),
                                      items: items, imageWidth: Int(sqlite3_column_int(stmt, 9)), imageHeight: Int(sqlite3_column_int(stmt, 10)),
                                      hasImage: FileManager.default.fileExists(atPath: Self.shotURL(id).path)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// `image`: ảnh chụp màn hình game; được thu nhỏ + nén JPEG rồi lưu ra file, chỉ giữ `maxShots` ảnh mới nhất.
    @discardableResult
    func addAnalysis(region: String, image: CGImage?, items: [ShotItem], summary: String, lines: [AnalysisLine],
                     backend: BackendKind, ms: Int, profile: String) -> ScreenAnalysis {
        let now = Date()
        let linesJSON = String(data: (try? JSONEncoder().encode(lines)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let itemsJSON = String(data: (try? JSONEncoder().encode(items)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let small = image.flatMap { RegionPreviewProvider.downscale($0, maxWidth: 1600) ?? $0 }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO analyses(ts, region, summary, lines, backend, latency, profile, items, iw, ih) VALUES(?,?,?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, region, -1, transient)
            sqlite3_bind_text(stmt, 3, summary, -1, transient)
            sqlite3_bind_text(stmt, 4, linesJSON, -1, transient)
            sqlite3_bind_text(stmt, 5, backend.rawValue, -1, transient)
            sqlite3_bind_int(stmt, 6, Int32(ms))
            sqlite3_bind_text(stmt, 7, profile, -1, transient)
            sqlite3_bind_text(stmt, 8, itemsJSON, -1, transient)
            sqlite3_bind_int(stmt, 9, Int32(small?.width ?? 0))
            sqlite3_bind_int(stmt, 10, Int32(small?.height ?? 0))
            if sqlite3_step(stmt) != SQLITE_DONE { Log.error("SQLite insert analysis: \(String(cString: sqlite3_errmsg(db)))") }
            sqlite3_finalize(stmt)
        }
        let id = sqlite3_last_insert_rowid(db)
        let saved = small.map { Self.writeJPEG($0, to: Self.shotURL(id)) } ?? false
        let a = ScreenAnalysis(id: id, timestamp: now, regionName: region, summary: summary, lines: lines,
                               backend: backend.rawValue, latencyMs: ms, profile: profile, items: items,
                               imageWidth: small?.width ?? 0, imageHeight: small?.height ?? 0, hasImage: saved)
        if profile == scope {
            analyses.insert(a, at: 0)
            if analyses.count > maxAnalyses { analyses.removeLast(analyses.count - maxAnalyses) }
        }
        pruneShots(profile: profile)
        return a
    }

    private static func writeJPEG(_ img: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Mỗi game giữ `maxShots` ảnh mới nhất: xoá file ảnh của các mục cũ hơn, phần chữ vẫn còn trong nhật ký.
    private func pruneShots(profile: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM analyses WHERE profile = ? ORDER BY id DESC LIMIT -1 OFFSET ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(Self.maxShots))
        var drop: Set<Int64> = []
        while sqlite3_step(stmt) == SQLITE_ROW { drop.insert(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        for id in drop { try? FileManager.default.removeItem(at: Self.shotURL(id)) }
        for i in analyses.indices where drop.contains(analyses[i].id) && analyses[i].hasImage { analyses[i].hasImage = false }
    }

    /// Xoá lịch sử dịch màn hình (kèm ảnh) của game đang chọn.
    func clearAnalyses() {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM analyses WHERE profile = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, scope, -1, transient)
            while sqlite3_step(stmt) == SQLITE_ROW { try? FileManager.default.removeItem(at: Self.shotURL(sqlite3_column_int64(stmt, 0))) }
            sqlite3_finalize(stmt)
        }
        exec("DELETE FROM analyses WHERE profile = '\(scope)';")
        analyses.removeAll()
    }
}
