import Foundation

/// Kết quả một lần model cập nhật cốt truyện game: đoạn diễn biến mới, bài viết liền mạch, các nhân vật có thay đổi.
/// Việc đọc và gộp là hàm thuần, để một phản hồi hỏng hoặc bị cắt cụt không bao giờ xoá mất phần đã lưu.
struct StoryUpdate: Equatable {
    var partTitle = ""
    var partSummary = ""
    var narrative = ""
    var characters: [StoryCharacter] = []

    /// Đọc {"part": {"title", "summary"} | null, "narrative", "characters": [...]} (model đôi khi bọc trong ```json … ```).
    static func parse(_ raw: String) throws -> StoryUpdate {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw TranslationRouter.StoryError.badJSON
        }
        let body = String(raw[start...end])
        func object(_ s: String) -> [String: Any]? {
            s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard let obj = object(body) ?? object(escapeControls(body)),
              obj["part"] != nil || obj["narrative"] != nil || obj["characters"] != nil || obj["summary"] != nil
        else { throw TranslationRouter.StoryError.badJSON }
        func str(_ v: Any?) -> String { TextUtils.normalize((v as? String) ?? "") }
        func paragraphs(_ v: Any?) -> String { TranslationRouter.cleanParagraphs((v as? String) ?? "") }
        var u = StoryUpdate()
        // Chấp nhận cả dạng phẳng {"title", "summary"} khi model bỏ lớp "part".
        let part = (obj["part"] as? [String: Any]) ?? obj
        u.partTitle = str(part["title"])
        u.partSummary = paragraphs(part["summary"])
        u.narrative = paragraphs(obj["narrative"])
        for item in (obj["characters"] as? [Any]) ?? [] {
            guard let c = item as? [String: Any] else { continue }
            let name = str(c["name"])
            guard !name.isEmpty else { continue }
            u.characters.append(StoryCharacter(name: name, role: str(c["role"]), personality: str(c["personality"]),
                                               background: str(c["background"]), relations: str(c["relations"]),
                                               status: str(c["status"])))
        }
        return u
    }

    /// Model hay xuống dòng thật giữa bài viết nhiều đoạn, trong khi JSON đòi viết thành \n → đổi các ký tự điều khiển
    /// nằm trong chuỗi thành dạng thoát để vẫn đọc được.
    static func escapeControls(_ json: String) -> String {
        var out = ""
        var inString = false, escaped = false
        for ch in json {
            if !inString {
                if ch == "\"" { inString = true }
                out.append(ch)
            } else if escaped {
                escaped = false
                out.append(ch)
            } else if ch == "\\" {
                escaped = true
                out.append(ch)
            } else if ch == "\"" {
                inString = false
                out.append(ch)
            } else if ch == "\n" || ch == "\r\n" {
                out += "\\n"
            } else if ch == "\r" {
                continue
            } else if ch == "\t" {
                out += "\\t"
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Khoá so tên nhân vật: không phân biệt hoa thường và dấu.
    static func nameKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Bài viết mới thay bài cũ, trừ khi nó rỗng hoặc ngắn bất thường (bị cắt cụt): khi đó giữ bài cũ và nối đoạn mới vào.
    static func mergeNarrative(old: String, update u: StoryUpdate) -> String {
        let truncated = old.count >= 600 && u.narrative.count < old.count / 2
        if !u.narrative.isEmpty, !truncated { return u.narrative }
        if u.partSummary.isEmpty { return old }
        return old.isEmpty ? u.partSummary : old + "\n\n" + u.partSummary
    }

    /// Trường có nội dung thay trường cũ, trường rỗng giữ nguyên; tên chưa có thì thêm vào cuối. Model không xoá được nhân vật.
    static func mergeCharacters(old: [StoryCharacter], new: [StoryCharacter], limit: Int = 40) -> [StoryCharacter] {
        var out = old
        for c in new {
            if let i = out.firstIndex(where: { nameKey($0.name) == nameKey(c.name) }) {
                if !c.role.isEmpty { out[i].role = c.role }
                if !c.personality.isEmpty { out[i].personality = c.personality }
                if !c.background.isEmpty { out[i].background = c.background }
                if !c.relations.isEmpty { out[i].relations = c.relations }
                if !c.status.isEmpty { out[i].status = c.status }
            } else if out.count < limit {
                out.append(c)
            }
        }
        return out
    }
}
