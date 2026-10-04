import Foundation

/// Phân biệt phụ đề với chữ giao diện (menu, cài đặt, danh sách) bằng heuristic trên văn bản + bố cục OCR.
/// Chữ giao diện: nhiều từ Hoa Đầu Chữ, nhiều mảnh cùng hàng (cột), nhiều hàng, cỡ chữ lẫn, nhiều số/nhãn, cụm lặp.
/// Phụ đề: câu đầy đủ chữ thường, 1–3 dòng, cỡ chữ đều, có dấu câu.
enum SubtitleClassifier {
    static let threshold = 3

    struct Verdict {
        let score: Int
        let reasons: [String]
        var isUI: Bool { score >= SubtitleClassifier.threshold }
    }

    static func classify(_ r: VisionOCR.Result) -> Verdict {
        classify(text: r.text, rows: r.rows, maxPerRow: r.maxPerRow, heightRatio: r.heightRatio)
    }

    static func classify(text: String, rows: Int = 1, maxPerRow: Int = 1, heightRatio: Double = 1) -> Verdict {
        var score = 0
        var reasons: [String] = []
        let tokens = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return Verdict(score: 0, reasons: []) }

        // Hoa Đầu Chữ (bỏ từ đầu câu, bỏ qua nếu toàn chữ hoa).
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let allCaps = !letters.isEmpty && Double(upper) / Double(letters.count) >= 0.9
        if !allCaps {
            var considered = 0, capitalized = 0
            var sentenceStart = true
            for tok in tokens {
                let word = tok.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
                let wl = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                defer {
                    let last = tok.unicodeScalars.last.map { Character(String($0)) } ?? " "
                    sentenceStart = ".!?…:".contains(last) || tok.hasSuffix("...")
                }
                guard wl.count >= 2 else { continue }
                if sentenceStart { continue }
                considered += 1
                if let f = wl.first, CharacterSet.uppercaseLetters.contains(f) { capitalized += 1 }
            }
            if considered >= 3 {
                let ratio = Double(capitalized) / Double(considered)
                if ratio >= 0.5 { score += 2; reasons.append("hoa đầu chữ \(Int(ratio * 100))%") }
                else if ratio >= 0.35 { score += 1; reasons.append("hoa đầu chữ \(Int(ratio * 100))%") }
            }
        }

        // Không có dấu câu nào.
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: ".,!?…;'\"")) == nil {
            score += 1; reasons.append("không dấu câu")
        }

        // Bố cục.
        if maxPerRow >= 3 { score += 2; reasons.append("cột (\(maxPerRow) mảnh/hàng)") }
        if rows >= 4 { score += 1; reasons.append("\(rows) hàng") }
        if heightRatio >= 1.6 { score += 1; reasons.append("cỡ chữ lẫn ×\(String(format: "%.1f", heightRatio))") }

        // Số / đơn vị / nhãn.
        let numeric = tokens.filter { isNumericToken($0) }.count
        if tokens.count >= 4, Double(numeric) / Double(tokens.count) >= 0.25 {
            score += 1; reasons.append("nhiều số (\(numeric)/\(tokens.count))")
        }
        let colons = text.filter { $0 == ":" || $0 == "：" }.count
        if colons >= 2 { score += 1; reasons.append("\(colons) dấu hai chấm") }

        // Cụm 3 từ lặp ≥ 3 lần.
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if words.count >= 9 {
            var counts: [String: Int] = [:]
            for i in 0..<(words.count - 2) {
                let key = words[i] + " " + words[i + 1] + " " + words[i + 2]
                counts[key, default: 0] += 1
            }
            if let (k, n) = counts.max(by: { $0.value < $1.value }), n >= 3 {
                score += 1; reasons.append("lặp “\(k)” ×\(n)")
            }
        }

        if tokens.count > 45 { score += 1; reasons.append("\(tokens.count) từ") }
        return Verdict(score: score, reasons: reasons)
    }

    /// 0.3, 20K, 1.2K, MB, GB, 50%, +, -, 10:30, v1.2
    private static func isNumericToken(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        if t.isEmpty { return true }
        let scalars = Array(t.unicodeScalars)
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if digits > 0 && digits >= scalars.count - 2 { return true }
        return ["MB", "GB", "KB", "TB", "K", "M", "FPS", "MS", "HZ", "DB"].contains(t.uppercased())
    }
}
