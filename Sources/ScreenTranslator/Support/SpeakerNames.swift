import Foundation

/// Học và nhận diện tên người nói ở đầu câu phụ đề ("Atreus: ...").
enum SpeakerNames {
    private static let learnPattern = #"^([A-Z][A-Za-z'\-]{0,20}(?: [A-Z][A-Za-z'\-]{1,20}){0,2}):\s+\S"#

    /// Trả về tên nếu câu có dạng "Tên: nội dung" (tên 1–3 từ, viết hoa chữ đầu; tên một chữ cái như "V" cũng nhận).
    static func learn(from source: String) -> String? {
        guard let r = source.range(of: learnPattern, options: .regularExpression) else { return nil }
        let head = source[r]
        guard let colon = head.firstIndex(of: ":") else { return nil }
        let name = head[..<colon].trimmingCharacters(in: .whitespaces)
        // Loại vài từ hay đứng trước dấu hai chấm mà không phải tên
        let blacklist: Set<String> = ["Note", "Warning", "Tip", "Hint", "Objective", "Quest", "Mission", "Chapter", "Press", "Error", "Info"]
        if blacklist.contains(name) { return nil }
        return name
    }

    struct Match {
        let speaker: String
        let rest: String
    }

    /// Nếu câu bắt đầu bằng "Tên:" hoặc bằng một tên đã học (dấu hai chấm bị OCR đọc sai thành , . ; - hoặc mất),
    /// trả về tên chuẩn và phần còn lại.
    static func match(_ text: String, speakers: [String]) -> Match? {
        let t = text.trimmingCharacters(in: .whitespaces)
        // 1. Dạng chuẩn "X: ..."
        if let r = t.range(of: #"^[^:：]{1,40}[:：]\s+"#, options: .regularExpression) {
            let name = String(t[r]).replacingOccurrences(of: #"[:：]\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let rest = String(t[r.upperBound...])
            if let known = canonical(name, speakers: speakers) { return Match(speaker: known, rest: rest) }
            if learn(from: t) != nil { return Match(speaker: name, rest: rest) }   // tên mới hợp lệ (viết hoa, không nằm blacklist)
            return nil
        }
        guard !speakers.isEmpty else { return nil }
        // 2. Tên đã học đứng đầu, sau đó là , . ; - – — hoặc khoảng trắng
        let tokens = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for n in stride(from: min(3, tokens.count), through: 1, by: -1) {
            var head = tokens[0..<n].joined(separator: " ")
            head = head.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-–—!?"))
            guard let known = canonical(head, speakers: speakers) else { continue }
            let restTokens = tokens[n...]
            var rest = restTokens.joined(separator: " ")
            rest = rest.replacingOccurrences(of: #"^[,.;:\-–— ]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            return Match(speaker: known, rest: rest)
        }
        return nil
    }

    /// Khớp tên (không phân biệt hoa thường, cho phép OCR sai ~20 %) với danh sách đã học.
    static func canonical(_ name: String, speakers: [String]) -> String? {
        let n = name.lowercased()
        guard !n.isEmpty else { return nil }
        if let exact = speakers.first(where: { $0.lowercased() == n }) { return exact }
        guard n.count >= 2 else { return nil }      // tên một chữ cái chỉ khớp chính xác, không đoán gần đúng
        var best: (String, Double)?
        for s in speakers {
            let sim = TextUtils.similarity(n, s.lowercased())
            if sim >= 0.8, sim > (best?.1 ?? 0) { best = (s, sim) }
        }
        return best?.0
    }

    /// Chuẩn hoá câu nguồn thành "Tên: nội dung" để dịch nhất quán.
    static func normalize(_ text: String, speakers: [String]) -> (text: String, speaker: String?) {
        guard let m = match(text, speakers: speakers) else { return (text, nil) }
        return ("\(m.speaker): \(m.rest)", m.speaker)
    }

    /// Bỏ tên người nói khỏi câu dịch để đọc voice (Gemini có thể trả "Angrboda, ..." hoặc "Angrboda: ...").
    static func stripForVoice(_ translated: String, speaker: String?, speakers: [String]) -> String {
        var all = speakers
        if let s = speaker, !all.contains(s) { all.append(s) }
        if let m = match(translated, speakers: all) { return m.rest }
        return TextUtils.stripSpeaker(translated)
    }
}
