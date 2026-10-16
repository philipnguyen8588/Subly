import Foundation

/// Hỏi đáp về cốt truyện: chỉ chọn phần dữ liệu liên quan tới câu hỏi (nhân vật, bách khoa, đoạn diễn biến, câu phụ đề
/// có từ khoá) để gửi model, thay vì gửi cả kho cốt truyện mỗi lần hỏi cho đỡ tốn token.
enum StoryQA {
    struct Turn { let question: String; let answer: String }

    /// Giới hạn ngữ cảnh (ký tự): model qua mạng, và model 4096 token trên máy của Apple Intelligence.
    static let cloudBudget = 24_000
    static let deviceBudget = 2_600
    static let maxQuestion = 500

    /// Từ để hỏi / từ nối, đã bỏ dấu: không dùng để tìm.
    private static let stopWords = Set("""
        co nhung nguoi nao la ai gi cua va voi trong ve nay do bao nhieu sao tai vi khi thi mot cac duoc đuoc da đa dang đang se \
        hay cho toi minh ban ke biet hoi the nhu o ra len xuong di đi den đen tu bi lam con khong chua roi vay ha nhe oi nua lai \
        ma nen neu hon nhat rat qua cung deu đeu tung moi tat ca gom nhan vat chuyen truyen cot game tom hien luc bay gio \
        who what which where when why how is are was were a an of in on to and or does did about tell me there from with \
        people person character characters story has have chinh quan he
        """.split(separator: " ").map(String.init))

    /// Phần dữ liệu đã chọn cho một câu hỏi; `render` cắt theo giới hạn của từng engine.
    struct Material {
        var question: String
        var narrative: String
        var parts: [String]
        var characters: [String]
        var otherCharacters: [String]
        var lore: [String]
        var otherLore: [String]
        var excerpts: [String]
        var history: [String]
        /// Câu hỏi + tên được nhắc tới: chỉ đưa thuật ngữ liên quan vào lời dặn.
        var focus: String
    }

    // MARK: chọn dữ liệu

    static func fold(_ s: String) -> String { StoryUpdate.nameKey(s).lowercased() }

    private struct Term { let folded: String; let raw: String; let words: Int }

    /// Cụm 1–3 từ của câu hỏi, không bắt đầu / kết thúc bằng từ để hỏi; từ đơn phải từ 3 ký tự.
    private static func terms(_ question: String) -> [Term] {
        let raw = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let folded = raw.map(fold)
        var out: [Term] = [], seen = Set<String>()
        for n in stride(from: 3, through: 1, by: -1) where raw.count >= n {
            for i in 0...(raw.count - n) {
                let f = Array(folded[i..<i + n])
                guard !stopWords.contains(f.first!), !stopWords.contains(f.last!) else { continue }
                if n == 1, f[0].count < 3 { continue }
                let key = f.joined(separator: " ")
                guard seen.insert(key).inserted else { continue }
                out.append(Term(folded: key, raw: raw[i..<i + n].joined(separator: " "), words: n))
            }
        }
        return out
    }

    /// `term` có trong `hay` như một cụm từ trọn vẹn (không phải một phần của từ khác).
    static func containsWord(_ hay: String, _ term: String) -> Bool {
        guard !term.isEmpty else { return false }
        var from = hay.startIndex
        while let r = hay.range(of: term, range: from..<hay.endIndex) {
            let before = r.lowerBound == hay.startIndex ? nil : hay[hay.index(before: r.lowerBound)]
            let after = r.upperBound == hay.endIndex ? nil : hay[r.upperBound]
            if !(before?.isLetter ?? false) && !(before?.isNumber ?? false) && !(after?.isLetter ?? false) && !(after?.isNumber ?? false) {
                return true
            }
            from = r.upperBound
        }
        return false
    }

    private static let termWeight = [0, 3, 15, 30]

    /// Điểm liên quan của một mục: tên có trong câu hỏi, cụm từ của câu hỏi có trong nội dung,
    /// hoặc nội dung nhắc tới một tên mà câu hỏi hỏi tới (vd. hỏi "Iron Kingdom" → người có tiểu sử nhắc Iron Kingdom).
    private static func score(name: String, text: String, question qKey: String, terms: [Term], mentioned: [String]) -> Int {
        let nk = fold(name)
        var s = 0
        if !nk.isEmpty, containsWord(qKey, nk) { s += 100 }
        else {
            let words = nk.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 && !stopWords.contains($0) }
            if words.contains(where: { containsWord(qKey, $0) }) { s += 40 }
        }
        let hay = fold(text)
        for t in terms where containsWord(hay, t.folded) { s += termWeight[t.words] }
        for m in mentioned where m != nk && containsWord(hay, m) { s += 40 }
        return s
    }

    static func gather(question: String, story: GameStory?, parts: [StoryPart], history: [Turn],
                       search: ([String]) -> [TranslationEntry]) -> Material {
        let qKey = fold(question)
        let characters = story?.characters ?? [], lore = story?.lore ?? []
        // Tên nhân vật / mục bách khoa được hỏi thẳng.
        let mentioned = (characters.map(\.name) + lore.map(\.name)).map(fold).filter { $0.count >= 2 && containsWord(qKey, $0) }
        // Bỏ các từ lẻ nằm trong một tên được hỏi ("iron", "kingdom" của "Iron Kingdom"): chúng kéo về câu không liên quan.
        let terms = terms(question).filter { t in !mentioned.contains { $0 != t.folded && containsWord($0, t.folded) } }

        let scoredLore = lore.map { l in (l, score(name: l.name, text: l.description, question: qKey, terms: terms, mentioned: mentioned)) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
        let detailedLore = Set(scoredLore.map(\.name))
        let loreLines = scoredLore.map { "- \($0.name) [\($0.kind)]: \($0.description)" }
        let otherLore = lore.filter { !detailedLore.contains($0.name) }.map(\.name)

        // Đoạn diễn biến (mới nhất trước trong `parts`): những đoạn khớp nhất, không có thì 3 đoạn gần nhất; xếp lại cũ trước.
        var pickedParts = parts.map { p in (p, score(name: "", text: p.title + " " + p.summary, question: qKey, terms: terms, mentioned: mentioned)) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
        if pickedParts.isEmpty { pickedParts = Array(parts.prefix(3)) }
        let partLines = pickedParts.sorted { $0.id < $1.id }.map { "- \($0.title): \(TextUtils.normalize($0.summary))" }

        // Câu phụ đề: tìm theo tên được hỏi (viết như trong game) và các cụm từ của câu hỏi, lấy 40 câu khớp nhất.
        let namesAsWritten = (characters.map(\.name) + lore.map(\.name)).filter { mentioned.contains(fold($0)) }
        let searchTerms = namesAsWritten + terms.filter { $0.words >= 2 || $0.raw.count >= 4 }.map(\.raw)
        var seenTerm = Set<String>()
        let uniqueTerms = searchTerms.filter { seenTerm.insert(fold($0)).inserted }
        let found = uniqueTerms.isEmpty ? [] : search(uniqueTerms)
        let scoredLines: [(entry: TranslationEntry, score: Int)] = found.map { e in
            (e, score(name: "", text: e.source + " " + e.translated, question: qKey, terms: terms, mentioned: mentioned))
        }
        let bestLines = scoredLines.filter { $0.score > 0 }.sorted { a, b in a.score != b.score ? a.score > b.score : a.entry.id > b.entry.id }.prefix(40)
        let excerpts = bestLines.map(\.entry).sorted { $0.id < $1.id }.map { TextUtils.normalize($0.source) }

        // Nhân vật: ngoài điểm theo câu hỏi, cộng thêm cho người nói / được nhắc trong các câu phụ đề vừa tìm được và trong
        // mục bách khoa được hỏi tới. Hồ sơ nhân vật viết bằng ngôn ngữ đích (vd. "Vương quốc Sắt") nên tên tiếng Anh trong
        // câu hỏi ("Iron Kingdom") thường không khớp thẳng: phụ đề gốc là cầu nối.
        let speakers = Set(excerpts.compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 30 else { return nil }
            return fold(String(line[..<colon]))
        })
        let linked = fold((scoredLore.filter { mentioned.contains(fold($0.name)) }.map(\.description) + excerpts).joined(separator: "\n"))
        func charText(_ c: StoryCharacter) -> String {
            [c.role, c.personality, c.background, c.relations, c.status, c.journal].joined(separator: " ")
        }
        // Cụm 2 từ trong mô tả của mục bách khoa được hỏi (vd. "thượng phụ"): nhân vật có vai trò chứa cụm đó cũng liên quan.
        let loreBigrams = Set(scoredLore.filter { mentioned.contains(fold($0.name)) }.flatMap { l -> [String] in
            let w = fold(l.description).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard w.count >= 2 else { return [] }
            return (0..<(w.count - 1)).filter { !stopWords.contains(w[$0]) && !stopWords.contains(w[$0 + 1]) }.map { w[$0] + " " + w[$0 + 1] }
        })
        func linkBonus(_ c: StoryCharacter) -> Int {
            let full = fold(c.name)
            let first = full.split(separator: " ").first.map(String.init) ?? full
            if speakers.contains(full) || speakers.contains(first) { return 25 }
            if containsWord(linked, full) || (first.count >= 4 && containsWord(linked, first)) { return 20 }
            let role = fold(c.role + " " + c.journal)
            if loreBigrams.contains(where: { containsWord(role, $0) }) { return 15 }
            return 0
        }
        var scoredChars = characters.map { c in
            (c, score(name: c.name, text: charText(c), question: qKey, terms: terms, mentioned: mentioned) + linkBonus(c))
        }
        .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
        // Câu hỏi chung chung (không khớp ai): đưa những người vừa xuất hiện gần đây.
        if scoredChars.isEmpty { scoredChars = Array(characters.filter { $0.seen > 0 }.sorted { $0.seen > $1.seen }.prefix(6)) }
        let detailedNames = Set(scoredChars.map(\.name))
        let charLines = scoredChars.map { c -> String in
            let fields = [("role", c.role), ("personality", c.personality), ("background", c.background), ("relations", c.relations),
                          ("status", c.status), ("journal", c.journal)]
                .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
            return "- \(c.name): \(fields.isEmpty ? "(nothing known yet)" : fields)"
        }
        let otherChars = characters.filter { !detailedNames.contains($0.name) }.map { c -> String in
            let role = TextUtils.normalize(c.role)
            return role.isEmpty ? c.name : "\(c.name) (\(role.count > 70 ? String(role.prefix(70)) + "…" : role))"
        }

        let historyLines = history.suffix(3).map { t in
            "Q: \(t.question)\nA: \(t.answer.count > 500 ? String(t.answer.prefix(500)) + "…" : t.answer)"
        }
        let focus = ([question] + namesAsWritten + scoredChars.map(\.name) + scoredLore.map(\.name)).joined(separator: "\n")
        return Material(question: question, narrative: story?.narrative ?? "", parts: partLines, characters: charLines,
                        otherCharacters: otherChars, lore: loreLines, otherLore: otherLore, excerpts: excerpts,
                        history: historyLines, focus: focus)
    }

    // MARK: dựng nội dung gửi model

    /// Lấy các mục theo thứ tự cho tới khi đủ `cap` ký tự (mục đầu quá dài thì cắt bớt).
    private static func fill(_ items: [String], cap: Int, separator: String = "\n") -> String {
        var out = ""
        for item in items {
            let add = (out.isEmpty ? "" : separator) + item
            if out.count + add.count > cap {
                if out.isEmpty { out = String(item.prefix(max(0, cap - 1))) + "…" }
                break
            }
            out += add
        }
        return out
    }

    static func render(_ m: Material, budget: Int) -> String {
        func cap(_ share: Double) -> Int { Int(Double(budget) * share) }
        var blocks: [(String, String)] = []
        let narrative = m.narrative.count > cap(0.2) ? String(m.narrative.prefix(cap(0.2))) + "…" : m.narrative
        blocks.append(("STORY SO FAR", narrative))
        blocks.append(("STORY PARTS (oldest first)", fill(m.parts, cap: cap(0.14))))
        blocks.append(("CHARACTERS", fill(m.characters, cap: cap(0.26))))
        blocks.append(("ALL OTHER CHARACTERS", fill(m.otherCharacters, cap: cap(0.09), separator: "; ")))
        blocks.append(("LORE", fill(m.lore, cap: cap(0.1))))
        blocks.append(("OTHER LORE ENTRIES", fill(m.otherLore, cap: cap(0.03), separator: ", ")))
        blocks.append(("SUBTITLE EXCERPTS (oldest first)", fill(m.excerpts, cap: cap(0.12))))
        blocks.append(("PREVIOUS Q&A", fill(m.history, cap: cap(0.06), separator: "\n\n")))
        var out = blocks.filter { !$0.1.isEmpty }.map { "\($0.0):\n\($0.1)" }.joined(separator: "\n\n")
        out += (out.isEmpty ? "" : "\n\n") + "QUESTION:\n\(m.question)"
        return out
    }
}
