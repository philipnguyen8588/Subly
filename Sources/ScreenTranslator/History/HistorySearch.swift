import Foundation

/// Một kết quả tìm trong cốt truyện: nhân vật, mục bách khoa, đoạn diễn biến, bản tóm tắt hoặc một đoạn của bài tóm lược.
struct StorySearchHit: Identifiable, Equatable {
    enum Kind: String {
        case character, lore, part, summary, narrative
        var label: String {
            switch self {
            case .character: return "Nhân vật"
            case .lore: return "Bách khoa"
            case .part: return "Diễn biến"
            case .summary: return "Tóm tắt"
            case .narrative: return "Tóm lược"
            }
        }
        var icon: String {
            switch self {
            case .character: return "person.fill"
            case .lore: return "books.vertical.fill"
            case .part: return "list.bullet.rectangle"
            case .summary: return "text.quote"
            case .narrative: return "text.book.closed"
            }
        }
    }
    let id: String
    let kind: Kind
    let title: String
    /// Toàn văn của mục (hiện khi mở chi tiết).
    let body: String
    var date: Date?
}

/// Tìm một cụm từ trong phụ đề, cốt truyện và dịch màn hình của game đang chọn.
/// Phụ đề và dịch màn hình đọc thẳng từ DB (cả dòng cũ ngoài bộ nhớ); cốt truyện lọc từ dữ liệu đã nạp.
@MainActor
enum HistorySearch {
    struct Results: Equatable {
        var query = ""
        var subtitles: [TranslationEntry] = []
        var story: [StorySearchHit] = []
        var screens: [ScreenAnalysis] = []
        /// Phụ đề / màn hình chạm giới hạn đọc từ DB (còn kết quả cũ hơn chưa lấy).
        var subtitlesCapped = false
        var screensCapped = false
        var isEmpty: Bool { subtitles.isEmpty && story.isEmpty && screens.isEmpty }
    }

    static let dbLimit = 500
    static let minLength = 2

    /// Không phân biệt hoa thường (cả chữ có dấu), nhưng phân biệt dấu: "gia" không khớp "giá".
    nonisolated static func matches(_ text: String, _ q: String) -> Bool {
        text.range(of: q, options: .caseInsensitive) != nil
    }

    static func run(_ raw: String) -> Results {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var r = Results(query: q)
        guard q.count >= minLength else { return r }
        let store = HistoryStore.shared
        let profile = store.scope
        // LIKE của SQLite chỉ bỏ qua hoa thường với chữ ASCII → gửi thêm vài biến thể hoa thường rồi lọc lại bằng Swift.
        var terms: [String] = []
        for t in [q, q.lowercased(), q.uppercased(), q.capitalized] where !terms.contains(t) { terms.append(t) }

        let subs = store.searchEntries(profile: profile, terms: terms, limit: dbLimit)
        r.subtitlesCapped = subs.count >= dbLimit
        r.subtitles = subs.filter { matches($0.source, q) || matches($0.translated, q) }

        let shots = store.searchAnalyses(profile: profile, terms: terms, limit: dbLimit)
        r.screensCapped = shots.count >= dbLimit
        r.screens = shots.filter { a in matches(a.summary, q) || a.lines.contains { matches($0.source, q) || matches($0.target, q) } }

        r.story = storyHits(q, store: store)
        return r
    }

    private static func storyHits(_ q: String, store: HistoryStore) -> [StorySearchHit] {
        var out: [StorySearchHit] = []
        let story = store.story
        for c in story?.characters ?? [] {
            let fields: [(String, String)] = [("Tình trạng", c.status), ("Vai trò", c.role), ("Tính cách", c.personality),
                                              ("Lai lịch", c.background), ("Quan hệ", c.relations), ("Hồ sơ", c.journal)]
            guard matches(c.name, q) || fields.contains(where: { matches($0.1, q) }) else { continue }
            let body = fields.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            out.append(StorySearchHit(id: "c:\(c.name)", kind: .character, title: c.name, body: body,
                                      date: c.seen > 0 ? Date(timeIntervalSince1970: c.seen) : nil))
        }
        for l in story?.lore ?? [] where matches(l.name, q) || matches(l.description, q) {
            out.append(StorySearchHit(id: "l:\(l.name)", kind: .lore, title: "\(l.name) · \(l.kindLabel)", body: l.description))
        }
        for p in store.storyParts where matches(p.title, q) || matches(p.summary, q) {
            out.append(StorySearchHit(id: "p:\(p.id)", kind: .part, title: p.title, body: p.summary, date: p.timestamp))
        }
        for s in store.summaries {
            let lines = s.lines.filter { matches($0.source, q) || matches($0.target, q) }
            guard matches(s.title, q) || matches(s.summary, q) || !lines.isEmpty else { continue }
            let quoted = lines.prefix(5).map { "• \($0.target.isEmpty ? $0.source : $0.target)" }
            out.append(StorySearchHit(id: "s:\(s.id)", kind: .summary, title: s.title,
                                      body: ([s.summary] + quoted).joined(separator: "\n"), date: s.timestamp))
        }
        let paragraphs = (story?.narrative ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, para) in paragraphs.enumerated() where matches(para, q) {
            out.append(StorySearchHit(id: "n:\(i)", kind: .narrative, title: "Bài tóm lược · đoạn \(i + 1)", body: para))
        }
        return newestFirst(out)
    }

    /// Mới trước, cũ sau: mục có thời điểm (nhân vật vừa xuất hiện, đoạn diễn biến, bản tóm tắt) xếp theo thời điểm giảm dần;
    /// mục không có (bách khoa, nhân vật của dữ liệu cũ, đoạn của bài tóm lược) đứng sau, cái thêm sau / viết sau trước.
    private static func newestFirst(_ hits: [StorySearchHit]) -> [StorySearchHit] {
        hits.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?): return x != y ? x > y : a.offset > b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset > b.offset
            }
        }.map(\.element)
    }

    /// Một đoạn khoảng `width` ký tự quanh chỗ khớp đầu tiên (thêm "…" ở đầu / cuối khi bị cắt), gộp về một dòng.
    nonisolated static func snippet(_ text: String, _ q: String, width: Int = 140) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " · ")
        guard flat.count > width else { return flat }
        guard let r = flat.range(of: q, options: .caseInsensitive) else { return String(flat.prefix(width)) + "…" }
        let before = max(0, (width - flat.distance(from: r.lowerBound, to: r.upperBound)) / 3)
        let start = flat.index(r.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
