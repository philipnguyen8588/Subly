import Foundation

/// Thuật ngữ game đóng kèm app (Contents/Resources/glossaries/*.csv). Dùng để tạo sẵn profile cho các game
/// thông dụng ở lần chạy đầu. Mỗi CSV: dòng `#!game=Tên game` (tuỳ chọn), các dòng `thuật ngữ,bản dịch`
/// (bản dịch trống = giữ nguyên), dòng `#` là chú thích.
enum GameGlossaries {
    struct Game {
        let name: String
        let entries: [GlossaryEntry]
    }

    static func bundled() -> [Game] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("glossaries", isDirectory: true),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(parse)
    }

    static func parse(_ url: URL) -> Game? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var name = url.deletingPathExtension().lastPathComponent
        var entries: [GlossaryEntry] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#!game=") {
                name = String(line.dropFirst("#!game=".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let term = parts[0]
            guard !term.isEmpty, term.lowercased() != "term", seen.insert(term.lowercased()).inserted else { continue }
            let tr = parts.count > 1 ? parts[1] : ""
            entries.append(GlossaryEntry(term: term, translation: tr, keepAsIs: tr.isEmpty))
        }
        guard !entries.isEmpty else { return nil }
        return Game(name: name, entries: entries)
    }
}
