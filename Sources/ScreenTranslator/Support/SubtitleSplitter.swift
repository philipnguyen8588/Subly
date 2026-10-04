import Foundation

/// Tách kết quả OCR (nhiều hàng) thành từng câu thoại và bỏ những câu đã xử lý rồi.
/// Xử lý 3 tình huống: (1) game giữ câu cũ và hiện thêm câu mới bên dưới; (2) hai người nói hiện cùng lúc;
/// (3) câu mới đi kèm câu cũ bị coi là "trùng" nên bị bỏ mất.
enum SubtitleSplitter {
    /// Hàng bắt đầu một câu thoại mới: "Tên: …" (tên đã học hoặc tên hợp lệ) hoặc gạch đầu dòng "- …".
    static func startsUtterance(_ row: String, speakers: [String], useNames: Bool) -> Bool {
        let t = row.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^[-–—]\s*\S"#, options: .regularExpression) != nil { return true }
        guard useNames, let r = t.range(of: #"^[^:：]{1,40}[:：]\s*\S"#, options: .regularExpression) else { return false }
        let head = String(t[r])
        guard let colon = head.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let name = head[..<colon].trimmingCharacters(in: .whitespaces)
        if SpeakerNames.canonical(name, speakers: speakers) != nil { return true }
        return SpeakerNames.learn(from: t.replacingOccurrences(of: #"[:：]\s*"#, with: ": ", options: .regularExpression, range: r)) != nil
    }

    /// Gom các hàng thành câu thoại: hàng không mở đầu câu mới thì nối vào câu trước.
    static func utterances(rows: [String], speakers: [String], useNames: Bool) -> [String] {
        var out: [String] = []
        for row in rows where !row.isEmpty {
            if out.isEmpty || startsUtterance(row, speakers: speakers, useNames: useNames) {
                out.append(stripDash(row))
            } else {
                out[out.count - 1] += " " + row
            }
        }
        return out
    }

    private static func stripDash(_ s: String) -> String {
        s.replacingOccurrences(of: #"^[-–—]\s*"#, with: "", options: .regularExpression)
    }

    /// Độ giống cao nhất (0...1) của `text` so với các câu đã xử lý gần đây.
    static func score(_ text: String, recent: [String]) -> Double {
        recent.map { max(TextUtils.similarity(text, $0), TextUtils.wordSimilarity(text, $0)) }.max() ?? 0
    }

    /// Trả về các câu thoại CHƯA xử lý, theo thứ tự trên màn hình.
    static func fresh(rows: [String], speakers: [String], useNames: Bool, recent: [String], threshold: Double) -> [String] {
        let known: (String) -> Bool = { score($0, recent: recent) >= threshold }
        var parts = utterances(rows: rows, speakers: speakers, useNames: useNames)
        if parts.count == 1 {
            // Không tách được theo tên: hoặc là biến thể OCR của câu cũ, hoặc "câu cũ + câu mới" (game không hiện tên).
            let whole = parts[0]
            let wholeScore = score(whole, recent: recent)
            var split: [String]?
            if rows.count >= 2 {
                for k in stride(from: rows.count - 1, through: 1, by: -1) {
                    let head = rows[0..<k].joined(separator: " ")
                    let hs = score(head, recent: recent)
                    // Phần đầu khớp câu cũ TỐT HƠN cả đoạn → phần còn lại là câu mới.
                    if hs >= threshold, hs > wholeScore + 0.02 { split = [head, rows[k...].joined(separator: " ")]; break }
                }
            }
            if let split { parts = split } else if wholeScore >= threshold { return [] }
        }
        return parts.compactMap { part -> String? in
            guard TextUtils.letterCount(part) >= 2, !known(part) else { return nil }
            // Câu mới MỞ ĐẦU bằng một câu đã đọc (game nối thêm chữ, hoặc OCR đọc lặp phần đuôi) → chỉ giữ phần thêm.
            if let rest = remainderAfterKnownPrefix(part, recent: recent) {
                return rest.isEmpty || known(rest) ? nil : rest
            }
            return part
        }
    }

    // MARK: từ cảm thán

    private static let interjectionWords: Set<String> = [
        "hm", "hmm", "hmph", "mhm", "mm", "mmhmm", "uh", "um", "er", "erm", "ah", "aha", "oh", "ooh", "eh", "huh", "ha", "heh",
        "ho", "hey", "wow", "whoa", "ugh", "argh", "agh", "gah", "grr", "tsk", "pfft", "phew", "oof", "ow", "ouch", "shh", "psst",
        "yikes", "whew", "meh", "bah", "eek", "ack", "urgh", "nngh", "hah", "ahem", "uhhuh", "uhuh", "ahh", "ohh", "oho", "ehh",
    ]
    /// Dạng kéo dài / lặp: hmmmm, hahaha, uhhh, aaah, ooooh, grrrr, arrrgh…
    private static let interjectionPattern = try! NSRegularExpression(pattern:
        #"^(h+m+p?h?|m+h*m+|u+h+|u+m+|e+r+m*|a+h+a*|o+h+o*|e+h+|h+u+h+|(ha|he|ho|hi|hu){2,}h?|he+h+|ha+h*|ho+h*|a+r+g+h*|u+r*g+h+|a+g+h+|g+r+|w+h*o+a+h*|wo+w+|phe+w+|o+f+|o+w+|t+s+k+|p+f+t+|s+h+|z+|n+g+h+|y+a+h+)$"#)

    /// Câu chỉ gồm từ cảm thán (hmm, haha, huh…) hoặc mô tả âm thanh trong ngoặc ([grunts], (sighs), *laughs*).
    /// Tên người nói ở đầu ("Kratos: Hmm.") được bỏ qua khi xét.
    static func isInterjectionOnly(_ text: String) -> Bool {
        var t = TextUtils.stripSpeaker(text)
        // Mô tả âm thanh trong ngoặc không phải lời thoại.
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: " ", options: .regularExpression)
        let words = t.lowercased().split { !$0.isLetter }.map(String.init)
        if words.isEmpty { return TextUtils.letterCount(text) > 0 && t.trimmingCharacters(in: .whitespacesAndNewlines).count < text.count }
        return words.allSatisfy { w in
            interjectionWords.contains(w)
                || interjectionPattern.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)) != nil
        }
    }

    /// Từ tiếng Anh cơ bản mà người chơi tự hiểu được, không cần dịch.
    private static let basicWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "no", "nope", "nah", "ok", "okay", "alright", "all", "right", "sure", "fine", "good", "great",
        "nice", "cool", "well", "so", "and", "but", "or", "oh", "hey", "hi", "hello", "bye", "goodbye", "thanks", "thank", "you",
        "please", "sorry", "what", "why", "who", "where", "when", "how", "really", "maybe", "now", "here", "there", "this", "that",
        "it", "is", "it's", "that's", "what's", "i", "i'm", "me", "my", "we", "us", "he", "she", "they", "a", "an", "the", "to", "of",
        "go", "come", "on", "in", "out", "up", "down", "let's", "wait", "stop", "look", "run", "move", "help", "see", "know", "got",
        "get", "do", "did", "don't", "not", "can", "can't", "will", "too", "very", "again", "more", "one", "two", "three",
        "man", "boss", "sir", "ma'am", "damn", "shit", "fuck", "hell", "god", "wow", "huh", "hmm", "mm", "uh", "um", "ah",
    ]

    /// Từ điển tiếng Anh của hệ điều hành (nạp khi cần lần đầu), để phân biệt câu ngắn thật với chữ OCR vô nghĩa ("imph", "impr").
    private static let dictionary: Set<String> = {
        guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\n").map { $0.lowercased() })
    }()

    /// Có ít nhất một từ tiếng Anh thật (từ 2 chữ cái, hoặc "I"/"a").
    static func hasEnglishWord(_ text: String) -> Bool {
        let words = TextUtils.stripSpeaker(text).lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0 == "'") }.map(String.init)
        return words.contains { w in
            if w == "i" || w == "a" { return true }
            guard w.count >= 2 else { return false }
            if basicWords.contains(w) || dictionary.contains(w) { return true }
            // Dạng biến đổi thường gặp: số nhiều, quá khứ, -ing, 's, n't.
            for suffix in ["n't", "'s", "'re", "'ll", "'ve", "'d", "ing", "ed", "es", "s"] where w.hasSuffix(suffix) && w.count > suffix.count + 1 {
                if dictionary.contains(String(w.dropLast(suffix.count))) { return true }
            }
            return false
        }
    }

    /// Câu quá đơn giản, không cần dịch hay đọc (mục tiêu là hiểu nội dung game, không phải đọc hết):
    /// sau khi bỏ tên người nói còn tối đa 2 từ ("V: No.", "Mechanic: What?", "Kill him."), hoặc tối đa 5 từ mà toàn từ cơ bản
    /// ("Okay, let's go.", "What? No, no, no.").
    static func isSimple(_ text: String) -> Bool {
        let t = TextUtils.stripSpeaker(text.trimmingCharacters(in: .whitespaces))
        let words = t.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init).filter { !$0.isEmpty }
        if words.count <= 2 { return true }
        return words.count <= 5 && words.allSatisfy(basicWords.contains)
    }

    /// Mẩu chữ lạc đứng một mình, không phải lời thoại: tối đa 2 từ, không có tên người nói, không có dấu câu
    /// ("mph", "impr", "ON mph" của đồng hồ xe; "Quick", "BACK" của nút bấm). Lời thoại ngắn thật luôn có dấu câu
    /// ("No.", "What?") hoặc tên người nói ("V: Sure").
    static func isStrayFragment(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^[^:：]{1,40}[:：]\s*\S"#, options: .regularExpression) != nil { return false }
        if t.rangeOfCharacter(from: CharacterSet(charactersIn: ".,!?…")) != nil { return false }
        return t.split(separator: " ").count <= 2
    }

    private static func norm(_ w: String) -> String {
        String(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    private static func alike(_ a: String, _ b: String) -> Bool {
        a == b || (a.count >= 3 && b.count >= 3 && TextUtils.similarity(a, b) >= 0.72)
    }

    /// Nếu `text` bắt đầu bằng (gần đúng, theo từng từ) một câu trong `recent`: trả về phần còn lại sau câu đó.
    /// Phần còn lại là "" khi nó chỉ là tiếng vọng OCR của mấy từ cuối (ví dụ "... How youve grown! uve prown sa").
    /// Trả về nil nếu không có câu nào là phần mở đầu.
    static func remainderAfterKnownPrefix(_ text: String, recent: [String]) -> String? {
        let tokens = text.split(separator: " ").map(String.init)
        let words = tokens.map(norm)
        var best: (n: Int, known: [String])?
        for r in recent {
            let kw = r.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
            let n = kw.count
            guard n >= 3, words.count > n else { continue }
            // So từng từ, cho phép ~15 % sai do OCR.
            var hits = 0
            for i in 0..<n where alike(kw[i], words[i]) { hits += 1 }
            if Double(hits) / Double(n) >= 0.85, n > (best?.n ?? 0) { best = (n, kw) }
        }
        guard let best else { return nil }
        let restTokens = Array(tokens[best.n...])
        let restWords = restTokens.map(norm).filter { $0.count >= 2 }
        guard !restWords.isEmpty else { return "" }
        // Tiếng vọng OCR: mọi từ còn lại đều giống hoặc nằm trong một từ của câu đã đọc.
        let echo = restWords.allSatisfy { w in
            best.known.contains { k in k.contains(w) || w.contains(k) && k.count >= 3 || TextUtils.similarity(k, w) >= 0.6 }
        }
        // Mảnh vụn: quá ngắn, toàn chữ thường, không có dấu câu → không phải câu thoại mới.
        let rest = restTokens.joined(separator: " ")
        let fragment = restWords.count <= 3 && rest == rest.lowercased() && rest.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?…")) == nil
        return echo || fragment ? "" : rest
    }
}
