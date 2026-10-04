import Foundation

enum TextUtils {
    /// Gộp khoảng trắng, trim, bỏ ký tự điều khiển.
    static func normalize(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Độ giống theo từ (hệ số Dice trên tập từ, bỏ dấu câu, không phân biệt hoa thường). 0...1.
    static func wordSimilarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init).filter { !$0.isEmpty })
        }
        let x = words(a), y = words(b)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }

    /// Hai kết quả OCR có phải cùng một câu không: lấy max(giống theo ký tự, giống theo từ).
    static func sameLine(_ a: String, _ b: String, threshold: Double) -> Bool {
        if a == b { return true }
        return max(similarity(a, b), wordSimilarity(a, b)) >= threshold
    }

    /// Bỏ token OCR vô nghĩa (trộn chữ/số kiểu "Ư0", "09000000V", "l|", ...). Giữ số thuần, giờ, %, mã ngắn như PS5/1st/4K.
    static func stripJunkTokens(_ s: String) -> String {
        let tokens = s.split(separator: " ").map(String.init)
        // "V:" ở đầu dòng là tên người nói một chữ cái (V trong Cyberpunk 2077), không phải rác.
        let kept = tokens.enumerated().filter { i, t in
            if i == 0, tokens.count > 1, t.range(of: #"^[A-Z][:：]$"#, options: .regularExpression) != nil { return true }
            return !isJunk(t)
        }.map(\.element)
        return kept.joined(separator: " ")
    }

    private static func isJunk(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        if t.isEmpty { return raw.count > 2 }               // chuỗi toàn ký hiệu dài → rác
        let scalars = Array(t.unicodeScalars)
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }
        let others = scalars.count - letters.count - digits.count
        if letters.isEmpty {
            // số thuần: 3, 2024, 10:30, 50%, 1,000 → giữ nếu không quá dài
            return digits.count > 6 || others > 2
        }
        if digits.isEmpty {
            // chữ thuần: bỏ nếu 1 ký tự lạ (trừ a/A/I) hoặc có nhiều ký tự không phải chữ xen giữa
            if letters.count == 1 { return !["a", "A", "I", "i"].contains(t) }
            return others > 1 && letters.count <= 3
        }
        // trộn chữ + số
        let nonASCII = letters.contains { !$0.isASCII }
        if nonASCII { return true }                          // "Ư0", "đ9"
        if digits.count >= 3 { return true }                 // "09000000V", "a1b2c3"
        if letters.count <= 2 && digits.count <= 2 {         // PS5, 4K, 1st, 2nd, F1, A4 → giữ
            return false
        }
        return digits.count > letters.count
    }

    /// Bỏ "Tên người nói: " ở đầu câu (Young Woman:, Người phụ nữ trẻ:, KRATOS:).
    static func stripSpeaker(_ s: String) -> String {
        guard let r = s.range(of: #"^[^:：]{1,40}[:：]\s+"#, options: .regularExpression) else { return s }
        let rest = String(s[r.upperBound...])
        return rest.isEmpty ? s : rest
    }

    static func letterCount(_ s: String) -> Int {
        s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    /// 0...1, 1 = giống hệt. Levenshtein trên chuỗi lowercase.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        let dist = prev[y.count]
        return 1 - Double(dist) / Double(max(x.count, y.count))
    }
}
