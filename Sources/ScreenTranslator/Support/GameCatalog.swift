import Foundation

/// Game mẫu: game kèm sẵn thuật ngữ, phong cách dịch, ghi chú cho AI và cài đặt tên người nói, để tạo nhanh một game.
/// Danh sách lấy từ server (GET /v1/games, sửa ở trang quản trị nên thêm game không cần build lại app), lưu cache trong
/// Application Support; chưa tải được lần nào thì dùng bản đóng kèm app (Contents/Resources/glossaries/*.json).
@MainActor
final class GameCatalog: ObservableObject {
    static let shared = GameCatalog()

    struct Term: Codable, Equatable {
        var term: String
        var translation: String?
    }

    struct Group: Codable, Equatable {
        var group: String
        var entries: [Term]
    }

    struct Game: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var aliases: [String] = []
        var style: String = "auto"
        var description: String = ""
        var note: String = ""
        var showsSpeakerNames = true
        var speakerAbove = false
        var speakers: [String] = []
        var glossary: [Group] = []

        enum CodingKeys: String, CodingKey { case id, name, aliases, style, description, note, showsSpeakerNames, speakerAbove, speakers, glossary }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? name.lowercased()
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
            style = try c.decodeIfPresent(String.self, forKey: .style) ?? "auto"
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            showsSpeakerNames = try c.decodeIfPresent(Bool.self, forKey: .showsSpeakerNames) ?? true
            speakerAbove = try c.decodeIfPresent(Bool.self, forKey: .speakerAbove) ?? false
            speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
            glossary = try c.decodeIfPresent([Group].self, forKey: .glossary) ?? []
        }

        var translationStyle: TranslationStyle { TranslationStyle(rawValue: style) ?? .auto }

        /// Thuật ngữ dạng danh sách phẳng của một game (bỏ trùng, không phân biệt hoa thường).
        var entries: [GlossaryEntry] {
            var seen = Set<String>()
            return glossary.flatMap(\.entries).compactMap { t in
                let term = t.term.trimmingCharacters(in: .whitespaces)
                guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
                let tr = (t.translation ?? "").trimmingCharacters(in: .whitespaces)
                return GlossaryEntry(term: term, translation: tr, keepAsIs: tr.isEmpty)
            }
        }

        /// Game mới tạo từ game mẫu: lấy luôn thuật ngữ, phong cách dịch, ghi chú cho AI và cài đặt tên người nói.
        func makeProfile(source: ProfileSource = .external) -> Profile {
            var p = Profile(name: name, source: source, glossary: entries, showsSpeakerNames: showsSpeakerNames, speakers: speakers)
            p.speakerAbove = speakerAbove
            p.translationStyle = translationStyle
            p.translationNote = note
            return p
        }

        func matches(_ query: String) -> Bool {
            ([name] + aliases).contains { $0.localizedStandardContains(query) }
        }
    }

    @Published private(set) var games: [Game]
    private var etag: String?

    private struct Cache: Codable {
        var etag: String?
        var games: [Game]
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTranslator/games.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: data), !c.games.isEmpty {
            games = Self.sorted(c.games)
            etag = c.etag
        } else {
            games = Self.sorted(Self.bundled())
        }
    }

    private static func sorted(_ g: [Game]) -> [Game] {
        g.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Bản đóng kèm app.
    nonisolated static func bundled() -> [Game] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("glossaries", isDirectory: true),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap { u in
            do { return try JSONDecoder().decode(Game.self, from: Data(contentsOf: u)) } catch {
                Log.warn("Game mẫu \(u.lastPathComponent) lỗi: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Game mẫu ứng với tên một game của người dùng (trùng tên hoặc tên gọi khác, không phân biệt hoa thường / dấu).
    func game(named name: String) -> Game? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        let same = { (a: String) in a.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return games.first { same($0.name) } ?? games.first { $0.aliases.contains(where: same) }
    }

    private var refreshing = false

    /// Tải danh sách mới từ server (gửi ETag nên không đổi thì không tải lại). Lỗi mạng thì giữ danh sách đang có.
    func refresh() async {
        guard !refreshing, let server = RuntimeConfig.server, let url = URL(string: server + "/v1/games") else { return }
        refreshing = true
        defer { refreshing = false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 304 { return }
            guard http.statusCode == 200 else { Log.warn("Game mẫu: server trả HTTP \(http.statusCode)"); return }
            let fresh = try JSONDecoder().decode(Cache.self, from: data).games
            // Server chưa có game nào (chưa nạp danh sách) → giữ bản đang có.
            guard !fresh.isEmpty else { return }
            let tag = http.value(forHTTPHeaderField: "ETag")
            try? JSONEncoder().encode(Cache(etag: tag, games: fresh)).write(to: Self.cacheURL, options: .atomic)
            etag = tag
            let list = Self.sorted(fresh)
            if list != games {
                games = list
                Log.info("Game mẫu: đã cập nhật \(list.count) game từ server")
            }
        } catch {
            Log.warn("Game mẫu: không tải được danh sách từ server: \(error.localizedDescription)")
        }
    }
}
