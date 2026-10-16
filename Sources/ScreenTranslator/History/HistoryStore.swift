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

/// Một lần người dùng chọn nhiều câu phụ đề trong nhật ký và bấm "Tóm tắt". Giữ kèm các câu đã chọn để đọc lại được
/// cả khi nhật ký phụ đề đã bị xoá.
struct StorySummary: Identifiable, Equatable {
    let id: Int64
    let timestamp: Date
    var profile: String
    let title: String
    let summary: String
    let lines: [AnalysisLine]
    /// Thời điểm câu đầu và câu cuối của đoạn được tóm tắt.
    let from: Date
    let to: Date
    let backend: String
    let latencyMs: Int
}

/// Một nhân vật trong mục "Cốt truyện": do model viết và bổ sung dần qua mỗi lần cập nhật.
/// Tên khoá JSON giống hệt bản Windows vì hai bản dùng chung file history.sqlite.
struct StoryCharacter: Codable, Equatable, Identifiable {
    var name: String
    var role = ""
    var personality = ""
    var background = ""
    var relations = ""
    /// Tình trạng hiện tại (đang ở đâu, còn sống / bị bắt / bị thương, đang làm gì): viết lại mỗi khi có thay đổi.
    var status = ""
    /// Hồ sơ nhân vật chép từ màn hình nhật ký / bách khoa của game mà người chơi đã mở và dịch.
    var journal = ""
    /// Thời điểm (giây Unix) của những câu phụ đề gần nhất có nhân vật này; 0 = chưa ghi nhận (dữ liệu cũ).
    var seen: Double = 0
    var id: String { name }

    init(name: String, role: String = "", personality: String = "", background: String = "", relations: String = "", status: String = "",
         journal: String = "") {
        self.name = name; self.role = role; self.personality = personality; self.background = background
        self.relations = relations; self.status = status; self.journal = journal
    }
    enum CodingKeys: String, CodingKey { case name, role, personality, background, relations, status, journal, seen }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
        relations = try c.decodeIfPresent(String.self, forKey: .relations) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        journal = try c.decodeIfPresent(String.self, forKey: .journal) ?? ""
        seen = try c.decodeIfPresent(Double.self, forKey: .seen) ?? 0
    }
}

/// Một mục "Bách khoa" của cốt truyện: địa danh, thế lực / đội quân, khái niệm của thế giới game, lấy từ các màn hình
/// nhật ký / bách khoa người chơi đã dịch. Tên khoá JSON giống hệt bản Windows.
struct StoryLore: Codable, Equatable, Identifiable {
    var name: String
    /// "place" (địa danh), "faction" (thế lực, đội quân, tổ chức), "concept" (khái niệm, sự kiện, vật phẩm) hoặc "other".
    var kind = "other"
    var description = ""
    var id: String { name }

    static let kinds: [(id: String, label: String)] = [("place", "Địa danh"), ("faction", "Thế lực"), ("concept", "Khái niệm"), ("other", "Khác")]
    var kindLabel: String { Self.kinds.first { $0.id == kind }?.label ?? "Khác" }

    init(name: String, kind: String = "other", description: String = "") {
        self.name = name; self.kind = kind; self.description = description
    }
    enum CodingKeys: String, CodingKey { case name, kind, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

/// Cốt truyện của một game: bài viết liền mạch + danh sách nhân vật, kèm con trỏ tới dòng nhật ký cuối đã đưa vào.
struct GameStory: Equatable {
    var profile: String
    var narrative: String
    var characters: [StoryCharacter]
    var lore: [StoryLore] = []
    var lastEntryID: Int64
    var lastAnalysisID: Int64
    var updated: Date
    var backend: String
}

/// Một đoạn diễn biến trong dòng thời gian của cốt truyện (mỗi lần cập nhật thêm một đoạn).
struct StoryPart: Identifiable, Equatable {
    var id: Int64
    let timestamp: Date
    var profile: String
    let title: String
    let summary: String
    let from: Date
    let to: Date
    let entryFrom: Int64
    let entryTo: Int64
    let lineCount: Int
    let backend: String
    let latencyMs: Int
}

/// Lịch sử dịch + phân tích màn hình, SQLite thuần. Mỗi dòng gắn với một game (profile);
/// `entries` / `analyses` chỉ chứa dữ liệu của game đang chọn và tự nạp lại khi đổi game.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [TranslationEntry] = []     // mới nhất trước
    @Published private(set) var analyses: [ScreenAnalysis] = []      // mới nhất trước
    @Published private(set) var summaries: [StorySummary] = []       // mới nhất trước
    @Published private(set) var story: GameStory?
    @Published private(set) var storyParts: [StoryPart] = []         // mới nhất trước
    /// Game (UUID của profile) mà `entries` / `analyses` đang chứa.
    private(set) var scope = ""
    /// Số dòng có từ trước khi nhật ký được tách theo game (không gắn với game nào).
    @Published private(set) var legacyCount = 0
    private var scopeObserver: AnyCancellable?
    private var db: OpaquePointer?
    private let maxInMemory = 2000
    private let maxAnalyses = 300
    /// Số ảnh chụp "dịch màn hình" được giữ trên đĩa cho mỗi game.
    static let maxShots = 200
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
        CREATE TABLE IF NOT EXISTS summaries(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, profile TEXT NOT NULL, title TEXT NOT NULL,
            summary TEXT NOT NULL, lines TEXT NOT NULL, t_from REAL NOT NULL, t_to REAL NOT NULL,
            backend TEXT NOT NULL, latency INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS story(
            profile TEXT PRIMARY KEY, narrative TEXT NOT NULL DEFAULT '', characters TEXT NOT NULL DEFAULT '[]',
            last_entry_id INTEGER NOT NULL DEFAULT 0, last_analysis_id INTEGER NOT NULL DEFAULT 0,
            updated REAL NOT NULL DEFAULT 0, backend TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS story_parts(
            id INTEGER PRIMARY KEY AUTOINCREMENT, profile TEXT NOT NULL, ts REAL NOT NULL, title TEXT NOT NULL,
            summary TEXT NOT NULL, t_from REAL NOT NULL, t_to REAL NOT NULL,
            entry_from INTEGER NOT NULL, entry_to INTEGER NOT NULL, line_count INTEGER NOT NULL,
            backend TEXT NOT NULL, latency INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS story_parts_profile ON story_parts(profile, id);
        PRAGMA journal_mode=WAL;
        """)
        // Bản cũ lưu ảnh chụp màn hình kèm mỗi lần dịch → xoá một lần cho nhẹ file.
        if !UserDefaults.standard.bool(forKey: "thumbnailsPurged") {
            exec("UPDATE analyses SET thumbnail = NULL; VACUUM;")
            UserDefaults.standard.set(true, forKey: "thumbnailsPurged")
        }
        if !columns("story").contains("lore") { exec("ALTER TABLE story ADD COLUMN lore TEXT NOT NULL DEFAULT '[]'") }
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
        summaries = loadSummaries(profile: scope)
        story = loadStory(profile: scope)
        storyParts = loadStoryParts(profile: scope)
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
        summaries = loadSummaries(profile: active)
        story = loadStory(profile: active)
        storyParts = loadStoryParts(profile: active)
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

    // MARK: summaries
    private func loadSummaries(profile: String) -> [StorySummary] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, profile, title, summary, lines, t_from, t_to, backend, latency FROM summaries WHERE profile = ? ORDER BY id DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        var out: [StorySummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lines = (try? JSONDecoder().decode([AnalysisLine].self, from: Data(text(stmt, 5).utf8))) ?? []
            out.append(StorySummary(id: sqlite3_column_int64(stmt, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                    profile: text(stmt, 2), title: text(stmt, 3), summary: text(stmt, 4), lines: lines,
                                    from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                                    to: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                                    backend: text(stmt, 8), latencyMs: Int(sqlite3_column_int(stmt, 9))))
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func addSummary(title: String, summary: String, lines: [AnalysisLine], from: Date, to: Date,
                    backend: BackendKind, ms: Int, profile: String) -> StorySummary {
        let now = Date()
        let linesJSON = String(data: (try? JSONEncoder().encode(lines)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO summaries(ts, profile, title, summary, lines, t_from, t_to, backend, latency) VALUES(?,?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, profile, -1, transient)
            sqlite3_bind_text(stmt, 3, title, -1, transient)
            sqlite3_bind_text(stmt, 4, summary, -1, transient)
            sqlite3_bind_text(stmt, 5, linesJSON, -1, transient)
            sqlite3_bind_double(stmt, 6, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, to.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 8, backend.rawValue, -1, transient)
            sqlite3_bind_int(stmt, 9, Int32(ms))
            if sqlite3_step(stmt) != SQLITE_DONE { Log.error("SQLite insert summary: \(String(cString: sqlite3_errmsg(db)))") }
            sqlite3_finalize(stmt)
        }
        let s = StorySummary(id: sqlite3_last_insert_rowid(db), timestamp: now, profile: profile, title: title, summary: summary,
                             lines: lines, from: from, to: to, backend: backend.rawValue, latencyMs: ms)
        if profile == scope { summaries.insert(s, at: 0) }
        return s
    }

    func deleteSummary(_ id: Int64) {
        exec("DELETE FROM summaries WHERE id = \(id);")
        summaries.removeAll { $0.id == id }
    }

    /// Xoá mọi bản tóm tắt của game đang chọn.
    func clearSummaries() {
        exec("DELETE FROM summaries WHERE profile = '\(scope)';")
        summaries.removeAll()
    }

    // MARK: story (cốt truyện game)
    func loadStory(profile: String) -> GameStory? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT narrative, characters, last_entry_id, last_analysis_id, updated, backend, lore FROM story WHERE profile = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let chars = (try? JSONDecoder().decode([StoryCharacter].self, from: Data(text(stmt, 1).utf8))) ?? []
        let lore = (try? JSONDecoder().decode([StoryLore].self, from: Data(text(stmt, 6).utf8))) ?? []
        return GameStory(profile: profile, narrative: text(stmt, 0), characters: chars.filter { !$0.name.isEmpty },
                         lore: lore.filter { !$0.name.isEmpty },
                         lastEntryID: sqlite3_column_int64(stmt, 2), lastAnalysisID: sqlite3_column_int64(stmt, 3),
                         updated: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)), backend: text(stmt, 5))
    }

    private func loadStoryParts(profile: String) -> [StoryPart] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, profile, title, summary, t_from, t_to, entry_from, entry_to, line_count, backend, latency FROM story_parts WHERE profile = ? ORDER BY id DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        var out: [StoryPart] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(StoryPart(id: sqlite3_column_int64(stmt, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                 profile: text(stmt, 2), title: text(stmt, 3), summary: text(stmt, 4),
                                 from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                                 to: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                                 entryFrom: sqlite3_column_int64(stmt, 7), entryTo: sqlite3_column_int64(stmt, 8),
                                 lineCount: Int(sqlite3_column_int(stmt, 9)), backend: text(stmt, 10),
                                 latencyMs: Int(sqlite3_column_int(stmt, 11))))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Câu phụ đề của game có id lớn hơn con trỏ, cũ trước (kể cả câu bị bỏ qua không dịch, để giữ mạch hội thoại).
    func storyEntries(profile: String, after: Int64, limit: Int) -> [TranslationEntry] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, region, source, translated, backend, latency, kind, target, profile FROM history WHERE profile = ? AND id > ? AND kind = 'subtitle' ORDER BY id ASC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        sqlite3_bind_int64(stmt, 2, after)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var out: [TranslationEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        sqlite3_finalize(stmt)
        return out
    }

    /// Tóm tắt của các lần "Dịch màn hình" có nội dung (bỏ tóm tắt menu) sau con trỏ, cũ trước.
    func storyAnalyses(profile: String, after: Int64) -> [(id: Int64, timestamp: Date, summary: String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, summary FROM analyses WHERE profile = ? AND id > ? AND length(summary) >= 80 AND summary NOT LIKE '(%' ORDER BY id ASC LIMIT 20", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        sqlite3_bind_int64(stmt, 2, after)
        var out: [(id: Int64, timestamp: Date, summary: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((sqlite3_column_int64(stmt, 0), Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), text(stmt, 2)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Câu phụ đề của game có chứa một trong các cụm từ (không phân biệt hoa thường với chữ ASCII), mới nhất trước.
    /// Đọc thẳng từ DB nên tìm được cả những câu cũ không còn trong `entries`.
    func searchEntries(profile: String, terms: [String], limit: Int) -> [TranslationEntry] {
        let terms = Array(terms.filter { !$0.isEmpty }.prefix(12))
        guard !terms.isEmpty else { return [] }
        let cond = Array(repeating: "source LIKE ? ESCAPE '\\' OR translated LIKE ? ESCAPE '\\'", count: terms.count).joined(separator: " OR ")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, region, source, translated, backend, latency, kind, target, profile FROM history WHERE profile = ? AND kind = 'subtitle' AND (\(cond)) ORDER BY id DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        var i: Int32 = 2
        for t in terms {
            let pattern = "%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            sqlite3_bind_text(stmt, i, pattern, -1, transient)
            sqlite3_bind_text(stmt, i + 1, pattern, -1, transient)
            i += 2
        }
        sqlite3_bind_int(stmt, i, Int32(limit))
        var out: [TranslationEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    /// Số câu đã dịch và số lần dịch màn hình chưa được đưa vào cốt truyện.
    func storyPending(profile: String) -> (lines: Int, screens: Int) {
        let s = loadStory(profile: profile)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT (SELECT COUNT(*) FROM history WHERE profile = ?1 AND id > ?2 AND kind = 'subtitle' AND backend != 'skipped'),
                   (SELECT COUNT(*) FROM analyses WHERE profile = ?1 AND id > ?3 AND length(summary) >= 80 AND summary NOT LIKE '(%')
            """, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        sqlite3_bind_int64(stmt, 2, s?.lastEntryID ?? 0)
        sqlite3_bind_int64(stmt, 3, s?.lastAnalysisID ?? 0)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
    }

    /// Lưu kết quả một lần cập nhật cốt truyện. Trả về false (không lưu gì) nếu con trỏ đã đổi từ lúc bắt đầu,
    /// tức là người dùng vừa xoá / viết lại cốt truyện trong lúc model đang chạy.
    @discardableResult
    func saveStoryUpdate(_ s: GameStory, expectedEntryCursor: Int64, part: StoryPart?) -> Bool {
        guard (loadStory(profile: s.profile)?.lastEntryID ?? 0) == expectedEntryCursor else { return false }
        let charsJSON = String(data: (try? JSONEncoder().encode(s.characters)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let loreJSON = String(data: (try? JSONEncoder().encode(s.lore)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        exec("BEGIN IMMEDIATE;")
        var ok = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, """
            INSERT INTO story(profile, narrative, characters, last_entry_id, last_analysis_id, updated, backend, lore) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(profile) DO UPDATE SET narrative=excluded.narrative, characters=excluded.characters,
                last_entry_id=excluded.last_entry_id, last_analysis_id=excluded.last_analysis_id,
                updated=excluded.updated, backend=excluded.backend, lore=excluded.lore
            """, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, s.profile, -1, transient)
            sqlite3_bind_text(stmt, 2, s.narrative, -1, transient)
            sqlite3_bind_text(stmt, 3, charsJSON, -1, transient)
            sqlite3_bind_int64(stmt, 4, s.lastEntryID)
            sqlite3_bind_int64(stmt, 5, s.lastAnalysisID)
            sqlite3_bind_double(stmt, 6, s.updated.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 7, s.backend, -1, transient)
            sqlite3_bind_text(stmt, 8, loreJSON, -1, transient)
            ok = sqlite3_step(stmt) == SQLITE_DONE
            if !ok { Log.error("SQLite save story: \(String(cString: sqlite3_errmsg(db)))") }
            sqlite3_finalize(stmt)
        }
        var saved = part
        if ok, let p = part {
            if sqlite3_prepare_v2(db, "INSERT INTO story_parts(profile, ts, title, summary, t_from, t_to, entry_from, entry_to, line_count, backend, latency) VALUES(?,?,?,?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, s.profile, -1, transient)
                sqlite3_bind_double(stmt, 2, p.timestamp.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, p.title, -1, transient)
                sqlite3_bind_text(stmt, 4, p.summary, -1, transient)
                sqlite3_bind_double(stmt, 5, p.from.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 6, p.to.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 7, p.entryFrom)
                sqlite3_bind_int64(stmt, 8, p.entryTo)
                sqlite3_bind_int(stmt, 9, Int32(p.lineCount))
                sqlite3_bind_text(stmt, 10, p.backend, -1, transient)
                sqlite3_bind_int(stmt, 11, Int32(p.latencyMs))
                ok = sqlite3_step(stmt) == SQLITE_DONE
                if !ok { Log.error("SQLite insert story part: \(String(cString: sqlite3_errmsg(db)))") }
                sqlite3_finalize(stmt)
                saved?.id = sqlite3_last_insert_rowid(db)
            } else { ok = false }
        }
        exec(ok ? "COMMIT;" : "ROLLBACK;")
        guard ok else { return false }
        if s.profile == scope {
            story = s
            if let p = saved { storyParts.insert(p, at: 0) }
        }
        return true
    }

    /// Xoá cốt truyện của game đang chọn. `fromNow`: bỏ qua nhật ký đã có, chỉ viết từ những câu sau thời điểm này;
    /// ngược lại lần cập nhật tới sẽ viết lại từ đầu nhật ký.
    func resetStory(fromNow: Bool) {
        exec("DELETE FROM story WHERE profile = '\(scope)'; DELETE FROM story_parts WHERE profile = '\(scope)';")
        storyParts.removeAll()
        story = nil
        if fromNow { startStoryFromNow(profile: scope) }
    }

    /// Game chưa có cốt truyện → đặt con trỏ ở cuối nhật ký hiện có, để việc tự cập nhật chỉ viết từ những câu sau lúc này
    /// (nhật ký cũ chỉ được đưa vào khi người dùng bấm "Tóm tắt từ đầu nhật ký"). Không làm gì nếu game đã có con trỏ.
    func startStoryFromNow(profile: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT OR IGNORE INTO story(profile, last_entry_id, last_analysis_id)
            VALUES(?1, (SELECT COALESCE(MAX(id), 0) FROM history WHERE profile = ?1),
                   (SELECT COALESCE(MAX(id), 0) FROM analyses WHERE profile = ?1))
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if profile == scope { story = loadStory(profile: profile) }
    }

    /// Số câu đã dịch trong nhật ký của game (để mời "Tóm tắt từ đầu nhật ký").
    func storyBacklog(profile: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history WHERE profile = ? AND kind = 'subtitle' AND backend != 'skipped'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, profile, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func deleteStoryPart(_ id: Int64) {
        exec("DELETE FROM story_parts WHERE id = \(id);")
        storyParts.removeAll { $0.id == id }
    }

    func deleteStoryCharacter(name: String) {
        guard var s = loadStory(profile: scope) else { return }
        s.characters.removeAll { $0.name == name }
        let json = String(data: (try? JSONEncoder().encode(s.characters)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE story SET characters = ? WHERE profile = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, json, -1, transient)
            sqlite3_bind_text(stmt, 2, scope, -1, transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        story = s
    }

    /// Đưa con trỏ "màn hình đã đọc" của cốt truyện về đầu (giữ nguyên con trỏ câu phụ đề).
    func rewindStoryScreens(profile: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE story SET last_analysis_id = 0 WHERE profile = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, profile, -1, transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        if profile == scope { story = loadStory(profile: profile) }
    }

    func deleteStoryLore(name: String) {
        guard var s = loadStory(profile: scope) else { return }
        s.lore.removeAll { $0.name == name }
        let json = String(data: (try? JSONEncoder().encode(s.lore)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE story SET lore = ? WHERE profile = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, json, -1, transient)
            sqlite3_bind_text(stmt, 2, scope, -1, transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        story = s
    }
}
