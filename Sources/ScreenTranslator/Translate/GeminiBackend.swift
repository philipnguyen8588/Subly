import Foundation

final class GeminiBackend: TranslationBackend {
    let kind: BackendKind = .gemini

    /// Từ 10/2026 Google không cho tài khoản mới dùng model 2.x và endpoint generateContent cũ trả 404 → gọi qua Interactions API.
    static let models = [
        "gemini-3.5-flash-lite",
        "gemini-flash-lite-latest",
        "gemini-3.1-flash-lite",
        "gemini-3.5-flash",
        "gemini-3.8-flash",
    ]
    /// Thứ tự thử khi model đã chọn bị 503/404/timeout.
    static let fallbackModels = ["gemini-3.5-flash-lite", "gemini-flash-lite-latest", "gemini-3.1-flash-lite", "gemini-3.5-flash"]

    enum GeminiError: LocalizedError {
        case noKey
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int, String)
        case empty
        case badJSON
        var errorDescription: String? {
            switch self {
            case .noKey: return "Chưa có Gemini API key"
            case .rateLimited(let r): return "Gemini 429 rate limited (retry \(r.map { Int($0) } ?? 60)s)"
            case .http(let c, let m): return "Gemini HTTP \(c): \(m)"
            case .empty: return "Gemini trả về rỗng"
            case .badJSON: return "Gemini trả về JSON không hợp lệ"
            }
        }
    }

    var apiKey: String
    var model: String
    var timeout: TimeInterval
    var baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    var targetName: String = "Vietnamese"
    var glossary: [GlossaryEntry] = []
    var speakers: [String] = []
    /// Chữ đang dịch (câu + ngữ cảnh). Có giá trị thì chỉ đưa vào prompt những thuật ngữ xuất hiện trong đó,
    /// để danh sách dài không làm đầy cửa sổ ngữ cảnh nhỏ của Apple Intelligence.
    var glossaryFocus: String = ""
    /// Tên game đang chơi (tên profile) để model dùng hiểu biết về thế giới của game đó.
    var gameName: String = ""
    var translationStyle: TranslationStyle = .modern
    /// Ghi chú riêng của người chơi cho game này (thêm nguyên văn vào lời dặn).
    var translationNote: String = ""
    /// Bối cảnh cốt truyện: tóm tắt "Dịch màn hình" gần nhất có nội dung (Journal, tiểu sử nhân vật…).
    var storyContext: String = ""
    /// Model đang thực sự dùng (có thể là model dự phòng) + hạn "dính" 5 phút.
    private(set) var activeModel: String?
    private var activeUntil = Date.distantPast
    private(set) var lastError: String?
    /// Model người dùng chọn trả 404 (không tồn tại với key này) → Router sẽ đổi cài đặt sang model dự phòng.
    private(set) var chosenModelMissing = false
    private let session: URLSession

    /// Danh sách model để thử theo thứ tự cho một request.
    private func candidateModels(maxAttempts: Int) -> [String] {
        var list: [String] = []
        if let a = activeModel, Date() < activeUntil { list.append(a) }
        list.append(model)
        list += Self.fallbackModels
        var seen = Set<String>(); list = list.filter { seen.insert($0).inserted }
        return Array(list.prefix(maxAttempts))
    }

    private static func isRetryable(_ e: Error) -> Bool {
        if case GeminiError.http(let code, _) = e { return code == 503 || code == 404 || code == 500 || code == 502 }
        if let u = e as? URLError { return u.code == .timedOut }
        return false
    }

    init(apiKey: String, model: String, timeout: TimeInterval) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 90
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // MARK: prompts

    private var speakersBlock: String {
        guard !speakers.isEmpty else { return "" }
        return "\nCharacter names (keep exactly as written, never translate; a line that starts with one of them followed by a colon keeps it at the start): " + speakers.joined(separator: ", ") + "\n"
    }

    private var glossaryBlock: String {
        let focus = glossaryFocus.lowercased()
        let items = glossary.filter { g in
            let t = g.term.trimmingCharacters(in: .whitespaces)
            // So khớp theo nguyên từ (không phải chuỗi con): "Uma" không khớp "human", "Quen" không khớp "frequent";
            // cho phép đuôi số nhiều -s/-es/'s ("drowner" khớp "drowners").
            guard !t.isEmpty else { return false }
            if focus.isEmpty { return true }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: t.lowercased()) + "(?:'?s|es)?(?![\\p{L}\\p{N}])"
            return focus.range(of: pattern, options: .regularExpression) != nil
        }
        guard !items.isEmpty else { return speakersBlock }
        let rows = items.map { g -> String in
            if g.keepAsIs || g.translation.trimmingCharacters(in: .whitespaces).isEmpty {
                return "- \"\(g.term)\" → keep exactly as \"\(g.term)\""
            }
            return "- \"\(g.term)\" → \"\(g.translation)\""
        }
        return "\nGlossary (always apply, case-insensitive match):\n" + rows.joined(separator: "\n") + "\n" + speakersBlock
    }

    var subtitleSystemPrompt: String {
        let source = gameName.isEmpty ? "movies and video games" : "the video game \"\(gameName)\""
        let story = storyContext.isEmpty ? "" : "\nStory so far (background only, never translate it): \(storyContext)\n"
        let trimmedNote = translationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? "" : "Notes from the player for this game (follow them): \(trimmedNote)\n"
        return """
        You write \(targetName) subtitles for \(source). Translate the meaning and the feeling, never word by word, \
        like a professional film subtitler. Turn slang, idioms and swearing into natural spoken \(targetName) of the same strength; \
        never translate them literally. Keep lines short and spoken, like real people talking. \
        Keep character names and game terms as written unless the glossary says otherwise. \
        Output ONLY the \(targetName) line, with no quotes, notes or explanations. If the input starts with a speaker's name and a colon \
        (for example "Jackie: "), start the output with that same name and colon; if it does not, do not add any name.
        \(targetName == "Vietnamese" ? Self.vietnameseStyle(translationStyle) : "")\(note)\(story)\(glossaryBlock)
        """
    }

    /// Hướng dẫn riêng cho tiếng Việt: xưng hô là chỗ dịch máy hay sai nhất.
    /// Hướng dẫn riêng cho tiếng Việt, theo phong cách của game: xưng hô là chỗ dịch máy hay sai nhất.
    static func vietnameseStyle(_ style: TranslationStyle) -> String {
        // Xưng hô theo quan hệ trong gia đình: model hay bỏ qua nếu không nhắc (chú Byron gọi cháu Clive là "ngươi").
        let family = """
        Family members always use family terms: uncle/aunt and nephew/niece → "chú/bác/cô/dì" and "cháu"; parent and child → \
        "cha/bố/mẹ" and "con"; siblings → "anh/chị" and "em"; grandparents → "ông/bà" and "cháu". "Uncle X" = "chú X". \
        Decide the relationship from the conversation and the story context.

        """
        let common = family + """
        Greetings, goodbyes, thanks and stock phrases must use what a Vietnamese person would actually say in that moment, \
        not a literal rendering. Keep the same pronouns as the previous lines between the same people. \
        If the input is a cut-off fragment, translate only what is there and add nothing.

        """
        switch style {
        case .modern, .auto:
            return """
            Pronouns: by default the speaker says "tôi" and calls teammates and friends "cậu" or "anh"/"cô", strangers and officials \
            "anh"/"cô"/"ông". Use "tao/mày" only when the speaker is openly hostile or insulting. Never use "ngươi". \
            "jack in" = "kết nối vào". Short Spanish or other foreign phrases are translated by meaning into the same natural Vietnamese, \
            except names and single words like "hermano", "choom" that work as nicknames. \
            \(common)Examples of the style:
            V: About to find out. → V: Sắp biết ngay đây.
            Jackie: Locked an' ready, hermano. Do your thing. → Jackie: Sẵn sàng rồi, hermano. Làm đi.
            Jackie: I will. Ahí luego. → Jackie: Chắc chắn rồi. Gặp sau nhé.
            V: Tell Misty I said "Hi." → V: Gửi lời chào Misty giúp tôi nhé.
            Sheriff (hostile): Ain't buyin' it. → Sheriff: Đừng hòng tao tin.

            """
        case .fantasy:
            return """
            Setting: a medieval fantasy world of knights, lords and kingdoms. Write in a dignified, slightly old-fashioned Vietnamese, \
            like a Vietnamese dub of a fantasy film. \
            Pronouns: a soldier or servant speaking to his lord or commander says "tôi" and calls him "ngài"; comrades-in-arms say "tôi" and "anh"; \
            lords, enemies and anyone speaking down say "ta" and "ngươi"; groups say "chúng tôi" (not including the listener) or \
            "chúng ta" (including the listener). Titles: "Sir X" = "ngài X", "Lady X" = "tiểu thư X", "my lord" = "thưa ngài", \
            "Your Highness" = "điện hạ". Never use "tớ", "tụi", "bạn" or modern slang. \
            \(common)Examples of the style:
            Soldier: As you command. → Soldier: Tuân lệnh.
            Clive: Thank you, Sir Wade. → Clive: Cảm ơn ngài Wade.
            Clive: And so we shall. → Clive: Và chúng ta sẽ làm vậy.
            Knight: We are outnumbered, my lord. → Knight: Thưa ngài, quân ta yếu thế hơn.
            Clive: I have a favor to ask, Uncle Byron. → Clive: Cháu có việc muốn nhờ chú, chú Byron.

            """
        case .myth:
            return """
            Setting: an epic of gods, giants and ancient myth. Write in a strong, terse, slightly archaic Vietnamese. \
            Pronouns: gods, giants and enemies speaking to each other or to mortals say "ta" and "ngươi"; a father speaking to his son \
            says "ta" and "con", the son says "con" and "cha"; companions say "tôi" and "anh"/"ông". Never use "tớ", "tụi", "bạn" or \
            modern slang. \
            \(common)Examples of the style:
            Kratos: Boy. → Kratos: Con.
            Kratos: We go. Now. → Kratos: Đi. Ngay.
            Thor: You'll pay for that. → Thor: Ngươi sẽ phải trả giá.

            """
        }
    }

    /// Cách viết phần tóm tắt của "Dịch màn hình", dùng chung cho Gemini và Apple Intelligence.
    static let summaryGuide = """
    How long the summary is depends on the screen. \
    If the screen only has menus, buttons, settings or stats, write one short sentence saying what the screen is. \
    If it contains story, quest, journal, codex or character text, retell ALL of that text's content in your own words, \
    not just the gist: keep every person, relationship, trait, past event, motive, goal, place, faction, item and number it mentions, \
    in the original order, in as many sentences as needed (usually 4–10). Do not add facts that are not on screen. \
    Write natural flowing prose. Never list categories, never comment on what the text contains, and never give advice; \
    mention the player's next step only when the screen states an objective.
    """

    var analysisSystemPrompt: String {
        """
        You are helping a player understand a video game screen. The user gives you numbered lines of English text \
        extracted by OCR from one screenshot (UI labels, dialog, quest text, stats). OCR may contain small errors; infer the intent.
        Return JSON with:
        - "summary": in \(targetName). \(Self.summaryGuide)
        - "lines": an array of {"i": line number, "t": \(targetName) translation}. Translate every line; keep names, numbers, keys and game terms as-is unless the glossary says otherwise.
        \(glossaryBlock)
        """
    }

    /// Tóm tắt một đoạn phụ đề người dùng chọn trong nhật ký (dùng chung cho mọi engine).
    var storySummaryPrompt: String {
        let source = gameName.isEmpty ? "a video game or movie" : "the video game \"\(gameName)\""
        let trimmedNote = translationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? "" : "Notes from the player about this game (relationships, names): \(trimmedNote)\n"
        return """
        You help a player follow the story of \(source). The user sends subtitle lines in the order they appeared; \
        a line may start with the speaker's name and a colon. OCR may contain small errors; infer the intent.
        Write in \(targetName):
        - "title": a short title for this part of the story (3–8 words).
        - "summary": retell what happens in this part as a clear story: who is involved, what they say, want or decide, \
        what is revealed, relationships and motives, and how it ends. Mention characters by name. Length depends on the input: \
        2–4 sentences for a short exchange, up to 3 short paragraphs for a long scene. Stay faithful: only what the lines say or \
        clearly imply; never invent actions, gestures or feelings (hugs, tears…), and when it is unclear who did something, \
        keep it vague instead of guessing. Never list the lines one by one; never give advice.
        Keep character names and game terms as written unless the glossary says otherwise.
        \(note)\(glossaryBlock)
        """
    }

    /// Gọi model với lời dặn và nội dung tuỳ ý (có thử model dự phòng như dịch màn hình).
    func generate(system: String, input: String, timeout: TimeInterval) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.noKey }
        let gen: [String: Any] = ["temperature": 0.4, "max_output_tokens": 4096]
        return try await sendWithFallback(system: system, input: input, generation: gen, timeout: timeout, maxAttempts: 3)
    }

    // MARK: subtitle translate

    func translate(_ text: String, context: [TranslationPair]) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.noKey }
        // Interactions API nhận một đoạn input: gộp các câu trước làm ngữ cảnh (như với Apple Intelligence).
        var input = ""
        if !context.isEmpty {
            input += "Previous lines of this conversation (context only, do not repeat them):\n"
            for p in context { input += "EN: \(p.source)\nTranslated: \(p.target)\n" }
            input += "\n"
        }
        input += "Translate this new line:\n" + text
        let gen: [String: Any] = ["temperature": 0.2, "max_output_tokens": 256]
        let raw = try await sendWithFallback(system: subtitleSystemPrompt, input: input, generation: gen,
                                             timeout: timeout, maxAttempts: 2)
        let cleaned = Self.clean(raw)
        guard !cleaned.isEmpty else { throw GeminiError.empty }
        return cleaned
    }

    // MARK: screen analysis (JSON mode)

    struct AnalysisResult {
        let summary: String
        let translations: [Int: String]
    }

    func analyze(lines: [String], timeout: TimeInterval) async throws -> AnalysisResult {
        guard !apiKey.isEmpty else { throw GeminiError.noKey }
        let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let gen: [String: Any] = ["temperature": 0.3, "max_output_tokens": 4096]
        let system = analysisSystemPrompt + """

        Reply with JSON only, no code fences and no other text, exactly in this shape:
        {"summary": "…", "lines": [{"i": 1, "t": "…"}, {"i": 2, "t": "…"}]}
        """
        let raw = try await sendWithFallback(system: system, input: numbered, generation: gen,
                                             timeout: timeout, maxAttempts: 3)
        // Lấy phần {...} (model đôi khi bọc trong ```json … ```).
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GeminiError.badJSON }
        let summary = (obj["summary"] as? String) ?? ""
        var map: [Int: String] = [:]
        for l in (obj["lines"] as? [[String: Any]]) ?? [] {
            if let i = l["i"] as? Int, let t = l["t"] as? String { map[i] = t }
        }
        return AnalysisResult(summary: TextUtils.normalize(summary), translations: map)
    }

    // MARK: transport

    /// Thử lần lượt các model; 503/404/timeout → model tiếp theo. Model thành công được "dính" 5 phút.
    private func sendWithFallback(system: String, input: String, generation: [String: Any],
                                  timeout: TimeInterval, maxAttempts: Int) async throws -> String {
        var lastErr: Error = GeminiError.empty
        for m in candidateModels(maxAttempts: maxAttempts) {
            do {
                let out = try await send(model: m, system: system, input: input, generation: generation, timeout: timeout)
                if m != model, m != activeModel { Log.warn("Gemini chuyển sang model dự phòng \(m) (model đã chọn: \(model))") }
                activeModel = m
                activeUntil = Date().addingTimeInterval(300)
                lastError = nil
                return out
            } catch {
                lastErr = error
                lastError = "\(m): \(error.localizedDescription)"
                if m == model, case GeminiError.http(404, _) = error { chosenModelMissing = true }
                if Self.isRetryable(error) {
                    Log.warn("Gemini \(m) lỗi (\(error.localizedDescription.prefix(60))) → thử model khác")
                    if m == activeModel { activeModel = nil }
                    continue
                }
                throw error
            }
        }
        throw lastErr
    }

    private func send(model: String, system: String, input: String, generation: [String: Any], timeout: TimeInterval) async throws -> String {
        do {
            return try await request(model: model, system: system, input: input, generation: generation, timeout: timeout, thinking: true)
        } catch GeminiError.http(400, let msg) where msg.lowercased().contains("thinking") {
            return try await request(model: model, system: system, input: input, generation: generation, timeout: timeout, thinking: false)
        }
    }

    /// POST /interactions (Gemini Interactions API): lời dặn ở `system_instruction`, nội dung ở `input`,
    /// kết quả là các bước `model_output` trong `steps` (bỏ qua bước `thought`).
    private func request(model: String, system: String, input: String, generation: [String: Any], timeout: TimeInterval, thinking: Bool) async throws -> String {
        var gen = generation
        if thinking { gen["thinking_level"] = "low" }
        let body: [String: Any] = ["model": model, "system_instruction": system, "input": input, "generation_config": gen]
        var req = URLRequest(url: URL(string: "\(baseURL)/interactions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 429 { throw GeminiError.rateLimited(retryAfter: Self.retryDelay(from: json)) }
        guard (200..<300).contains(code) else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.http(code, msg)
        }
        let steps = (json?["steps"] as? [[String: Any]]) ?? []
        let out = steps.filter { ($0["type"] as? String) == "model_output" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
        guard !out.isEmpty else { throw GeminiError.empty }
        return out
    }

    private static func retryDelay(from json: [String: Any]?) -> TimeInterval? {
        guard let details = (json?["error"] as? [String: Any])?["details"] as? [[String: Any]] else { return nil }
        for d in details {
            if let t = d["@type"] as? String, t.hasSuffix("RetryInfo"), let s = d["retryDelay"] as? String,
               let v = TimeInterval(s.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) { return v }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        var t = TextUtils.normalize(s)
        if t.count >= 2, let f = t.first, let l = t.last, "\"“”'".contains(f), "\"“”'".contains(l) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    /// GET /models: các model hỗ trợ generateContent, ưu tiên flash/lite.
    static func listModels(apiKey: String, baseURL: String) async throws -> [String] {
        var req = URLRequest(url: URL(string: "\(baseURL)/models?pageSize=200")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            throw GeminiError.http(code, ((json?["error"] as? [String: Any])?["message"] as? String) ?? "")
        }
        let models = (json?["models"] as? [[String: Any]]) ?? []
        let names = models.compactMap { m -> String? in
            guard let n = m["name"] as? String,
                  let methods = m["supportedGenerationMethods"] as? [String], methods.contains("generateContent") else { return nil }
            let id = n.split(separator: "/").last.map(String.init) ?? n
            if id.contains("tts") || id.contains("image") || id.contains("embedding") || id.contains("live") || id.contains("omni") { return nil }
            return id
        }
        return names.sorted { a, b in
            let la = a.contains("lite"), lb = b.contains("lite")
            if la != lb { return la }
            return a > b
        }
    }

    /// Nút "Test key" trong Settings.
    static func test(apiKey: String, model: String) async -> Result<String, Error> {
        let b = GeminiBackend(apiKey: apiKey, model: model, timeout: 10)
        b.baseURL = AppSettings.shared.geminiBaseURL
        b.targetName = AppSettings.shared.target.englishName
        do {
            let t0 = Date()
            let r = try await b.translate("Hello, how are you?", context: [])
            return .success("\(r)  (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        } catch {
            return .failure(error)
        }
    }
}
