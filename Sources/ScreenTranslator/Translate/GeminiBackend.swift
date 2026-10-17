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
    /// Model dự phòng của bản này (AI share chỉ được thử các model đã share).
    var fallbackModels = GeminiBackend.fallbackModels

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

    /// Nhiều key miễn phí dùng xoay vòng: mỗi request lấy key kế tiếp để chia đều quota; key bị 429 thì nghỉ đến hết
    /// thời gian Google báo, các key còn lại chạy tiếp.
    var apiKeys: [String]
    var apiKey: String {
        get { apiKeys.first ?? "" }
        set { apiKeys = newValue.isEmpty ? [] : [newValue] }
    }
    private var keyIndex = 0
    private var keyCooldown: [String: Date] = [:]
    private let keyLock = NSLock()
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
        list += fallbackModels
        var seen = Set<String>(); list = list.filter { seen.insert($0).inserted }
        return Array(list.prefix(maxAttempts))
    }

    private static func isRetryable(_ e: Error) -> Bool {
        if case GeminiError.http(let code, _) = e { return code == 503 || code == 404 || code == 500 || code == 502 }
        if let u = e as? URLError { return u.code == .timedOut }
        return false
    }

    convenience init(apiKey: String, model: String, timeout: TimeInterval) {
        self.init(apiKeys: apiKey.isEmpty ? [] : [apiKey], model: model, timeout: timeout)
    }

    init(apiKeys: [String], model: String, timeout: TimeInterval) {
        self.apiKeys = apiKeys
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

    private var glossaryBlock: String { glossaryBlock(focus: glossaryFocus) }

    /// `focus` truyền riêng để việc chạy nền (cốt truyện) không ghi đè `glossaryFocus` của câu phụ đề đang dịch.
    private func glossaryBlock(focus rawFocus: String) -> String {
        let focus = rawFocus.lowercased()
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
        case .eastern:
            return """
            Setting: feudal Japan or ancient China (samurai, ronin, warlords, ninja, monks, yokai, Chinese myth). Write like the \
            Vietnamese dub of a historical martial-arts drama (phim cổ trang, kiếm hiệp): dignified, concise, no modern slang. \
            Pronouns: a retainer or soldier speaking to his lord says "thuộc hạ" or "tôi" and calls him "chúa công" \
            ("my lord" = "thưa chúa công"); "Lord X" = "lãnh chúa X"; "-sama"/"-dono" after a name = "X đại nhân"; \
            lords, warlords, demons, gods and enemies speaking down say "ta" and "ngươi"; friendly equals say "tôi" and "anh"/"cô", \
            sworn brothers "huynh" and "đệ"; a master and a disciple say "sư phụ" and "con"/"đồ nhi"; a monk calls himself "bần tăng", \
            an old man "lão". "Sensei" = "sư phụ". Keep Japanese and Chinese names, ranks and places as written. \
            Never use "tớ", "cậu", "bạn", "tụi" or modern slang. \
            \(common)Examples of the style:
            Jin: I will not abandon you, uncle. → Jin: Cháu sẽ không bỏ mặc chú đâu, chú à.
            Samurai: My lord, the Mongols have reached the gate. → Samurai: Thưa chúa công, quân Mông Cổ đã tới cổng thành.
            Khotun Khan: You fight bravely, samurai. → Khotun Khan: Ngươi chiến đấu dũng cảm lắm, samurai.
            Monk: I am only a humble monk. → Monk: Bần tăng chỉ là kẻ tu hành.
            Erlang: You still have far to go, monkey. → Erlang: Ngươi còn phải đi xa lắm, con khỉ.

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

    /// Trả lời câu hỏi của người chơi về cốt truyện, chỉ dựa trên dữ liệu `StoryQA` gửi kèm (dùng chung cho mọi engine).
    func storyQAPrompt(focus: String) -> String {
        let source = gameName.isEmpty ? "a video game" : "the video game \"\(gameName)\""
        let trimmedNote = translationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? "" : "Notes from the player about this game (relationships, names): \(trimmedNote)\n"
        return """
        You answer a player's questions about the story of \(source), using ONLY the story record in the user message. \
        The app built that record from the subtitles and journal screens the player has seen so far. The user message may contain: \
        STORY SO FAR, STORY PARTS, CHARACTERS (full details of the characters related to the question), ALL OTHER CHARACTERS \
        (name and role), LORE (places, factions, concepts), OTHER LORE ENTRIES (names only), SUBTITLE EXCERPTS (original lines \
        that mention the question's keywords, oldest first; a line may start with the speaker's name and a colon), PREVIOUS Q&A \
        (earlier turns of this conversation, for follow-up questions) and finally QUESTION.
        Rules:
        - Answer in \(targetName), directly. For "who / what / which" questions, put each item on its own line starting with "- ", \
        the name first, then a short note on how the record links it to the question (role, relation, what they did).
        - Be complete: look through every block, including ALL OTHER CHARACTERS, LORE and SUBTITLE EXCERPTS. When asked who is in, \
        belongs to or is connected with a place or faction, list everyone and every group the record ties to it: rulers, \
        members, people who live there, come from there, serve or served it, fight for or against it, and its people or army.
        - Use only the record. Never add facts, plot, backstory or future events from your own knowledge of the game (no spoilers). \
        When the record only hints at something, say that it is not certain.
        - If the record has nothing relevant, say in one sentence that the record has no information about it yet, and mention the \
        closest related thing it does contain, if any.
        - Keep character names and game terms as written in the record unless the glossary says otherwise.
        - Plain text only: no headings, bold, tables or code fences.
        \(note)\(glossaryBlock(focus: focus))
        """
    }

    /// Cập nhật cốt truyện game: một lần gọi trả về đoạn diễn biến mới, bài viết liền mạch, các nhân vật có thay đổi
    /// và các mục bách khoa (địa danh, thế lực, khái niệm) lấy từ màn hình nhật ký.
    func storyUpdatePrompt(focus: String) -> String {
        let source = gameName.isEmpty ? "a video game" : "the video game \"\(gameName)\""
        let trimmedNote = translationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? "" : "Notes from the player about this game (relationships, names): \(trimmedNote)\n"
        return """
        You keep a running story record for a player of \(source). The user sends four blocks: STORY SO FAR (the record you wrote \
        earlier; may be empty), KNOWN CHARACTERS (may be empty), KNOWN LORE (names of codex entries already recorded; may be empty) \
        and NEW LINES: subtitle lines in the order they appeared since the last update. A line may start with the speaker's name \
        and a colon. Lines starting with "[Screen]" are summaries of journal, quest or codex screens the player opened. \
        "[…later…]" marks a break in play time. OCR may contain small errors; infer the intent.
        A "[Screen]" line is reference material, not an event. When it describes who a character is, or explains a place, a \
        faction, army or organisation, or a concept of the game world, it must go ONLY into "characters" (field "journal") or \
        "lore" below: never retell it in "part" or "narrative", and never write that the player opened or read a screen. Only a \
        "[Screen]" line that states something that happened in the story or the current objective may inform "part" and "narrative".
        Write in \(targetName) and return JSON with:
        - "part": {"title", "summary"} covering only what happens in NEW LINES. "title": 3–8 words. "summary": retell it as a clear \
        story: who is involved, what they say, want or decide, what is revealed, and how it ends; 2–4 sentences for a short exchange, \
        up to 3 short paragraphs for a long scene. If NEW LINES contain nothing of the story (menus, combat shouts, small talk, \
        or only reference screens), use null.
        - "narrative": the whole story so far as one continuous text: STORY SO FAR extended with the new events and rewritten so it \
        reads as one retelling, in chronological order, in short paragraphs separated by a blank line. Keep every important earlier \
        event, name, reveal and decision; never drop the beginning. At most about 450 words: when it would be longer, tell older \
        events more briefly and recent ones in more detail. If nothing changes, return "".
        - "characters": every named character who speaks or takes part in NEW LINES and is not yet listed in KNOWN CHARACTERS, \
        plus every known character about whom NEW LINES reveal something new or whose situation changes; [] if none. A character \
        counts as new whenever the name is missing from KNOWN CHARACTERS, even if the story treats them as familiar: always \
        include the protagonist and the companions travelling with them. Each is \
        {"name", "role", "personality", "background", "relations", "status", "journal"}, every field except "journal" at most \
        two short sentences. "journal" holds what a "[Screen]" line says about this character (their profile in the game's \
        journal or codex): keep all of its facts, in up to 4 sentences; "" when no screen describes them. A character described \
        only by a "[Screen]" line still belongs in "characters". \
        "status" is the character's current situation at the end of NEW LINES: where they are, their condition (alive, dead, \
        wounded, captured, missing, rescued…) and what they are doing or about to do; rewrite it whenever it changes. For a known \
        character, write the full updated text of each field you change and "" for fields that do not change. Use "" when \
        something is not known; never guess. Use names exactly as in KNOWN CHARACTERS and the glossary; if a new name is clearly \
        the same person as a known character, use the known name. Do not add unnamed speakers (Soldier, Guard) unless they \
        matter to the story.
        - "lore": codex entries explained by "[Screen]" lines in NEW LINES: places, factions (armies, orders, nations, \
        organisations) and concepts (magic, creatures, items, historical events); [] if none. Each is {"name", "kind", \
        "description"}: "name" as written in the game (use the exact name from KNOWN LORE when it is the same entry); "kind" is \
        "place", "faction", "concept" or "other"; "description" keeps every fact the screen gives, in up to 5 sentences. \
        People go in "characters", not in "lore".
        Stay faithful: use only STORY SO FAR and NEW LINES. Never add plot, backstory or future events from your own knowledge of \
        the game (no spoilers); never invent actions, gestures or feelings; when it is unclear who did something, keep it vague. \
        Never list the lines one by one; never give advice.
        Keep character names and game terms as written unless the glossary says otherwise.
        \(note)\(glossaryBlock(focus: focus))
        Reply with JSON only, no code fences and no other text, exactly in this shape (inside a string write a paragraph \
        break as \\n\\n, never a real line break, and use single quotes ‘…’ instead of double quotes):
        {"part": {"title": "…", "summary": "…"}, "narrative": "…", "characters": [{"name": "…", "role": "…", "personality": "…", "background": "…", "relations": "…", "status": "…", "journal": "…"}], "lore": [{"name": "…", "kind": "…", "description": "…"}]}
        """
    }

    /// Gọi model với lời dặn và nội dung tuỳ ý (có thử model dự phòng như dịch màn hình).
    func generate(system: String, input: String, timeout: TimeInterval, maxOutputTokens: Int = 4096, model preferred: String? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.noKey }
        let gen: [String: Any] = ["temperature": 0.4, "max_output_tokens": maxOutputTokens]
        return try await sendWithFallback(system: system, input: input, generation: gen, timeout: timeout, maxAttempts: 3, preferred: preferred)
    }

    // MARK: subtitle translate

    func translate(_ text: String, context: [TranslationPair]) async throws -> String {
        try await translate(text, context: context, model: nil)
    }

    /// `model`: model riêng cho việc dịch phụ đề (Cài đặt → Dịch); nil = model mặc định.
    func translate(_ text: String, context: [TranslationPair], model preferred: String?) async throws -> String {
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
                                             timeout: timeout, maxAttempts: 2, preferred: preferred)
        let cleaned = Self.clean(raw)
        guard !cleaned.isEmpty else { throw GeminiError.empty }
        return cleaned
    }

    // MARK: screen analysis (JSON mode)

    struct AnalysisResult {
        let summary: String
        let translations: [Int: String]
    }

    func analyze(lines: [String], timeout: TimeInterval, model preferred: String? = nil) async throws -> AnalysisResult {
        guard !apiKey.isEmpty else { throw GeminiError.noKey }
        let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let gen: [String: Any] = ["temperature": 0.3, "max_output_tokens": 4096]
        let system = analysisSystemPrompt + """

        Reply with JSON only, no code fences and no other text, exactly in this shape:
        {"summary": "…", "lines": [{"i": 1, "t": "…"}, {"i": 2, "t": "…"}]}
        "lines" must have exactly \(lines.count) entries: one per numbered input line, "i" = that line's number.
        Never merge, split, skip or reorder lines, even when a line looks like a fragment of another one.
        """
        let raw = try await sendWithFallback(system: system, input: numbered, generation: gen,
                                             timeout: timeout, maxAttempts: 3, preferred: preferred)
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
    /// `preferred`: model riêng của một việc (khác model mặc định) → thử nó trước rồi tới các model dự phòng, và không
    /// đụng tới trạng thái "dính" / "model không tồn tại" của model mặc định.
    private func sendWithFallback(system: String, input: String, generation: [String: Any],
                                  timeout: TimeInterval, maxAttempts: Int, preferred: String? = nil) async throws -> String {
        var lastErr: Error = GeminiError.empty
        if let p = preferred, !p.isEmpty, p != model {
            var seen = Set<String>()
            for m in ([p] + fallbackModels).filter({ seen.insert($0).inserted }).prefix(maxAttempts) {
                do {
                    let out = try await send(model: m, system: system, input: input, generation: generation, timeout: timeout)
                    if m != p { Log.warn("Gemini chuyển sang model dự phòng \(m) (model đã chọn: \(p))") }
                    return out
                } catch {
                    lastErr = error
                    guard Self.isRetryable(error) else { throw error }
                    Log.warn("Gemini \(m) lỗi (\(error.localizedDescription.prefix(60))) → thử model khác")
                }
            }
            throw lastErr
        }
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

    /// Các key cho request này, bắt đầu từ key kế tiếp trong vòng; key đang nghỉ vì 429 bị bỏ qua (trừ khi mọi key đều nghỉ).
    private func keysForRequest() -> [String] {
        keyLock.lock(); defer { keyLock.unlock() }
        guard !apiKeys.isEmpty else { return [] }
        let start = keyIndex % apiKeys.count
        keyIndex = (start + 1) % apiKeys.count
        let ordered = Array(apiKeys[start...] + apiKeys[..<start])
        let now = Date()
        let ready = ordered.filter { (keyCooldown[$0] ?? .distantPast) <= now }
        return ready.isEmpty ? [ordered[0]] : ready
    }

    /// Gửi bằng key kế tiếp; key nào bị 429 thì cho nghỉ và thử ngay key khác. Chỉ báo hết quota khi mọi key đều hết.
    private func request(model: String, system: String, input: String, generation: [String: Any], timeout: TimeInterval, thinking: Bool) async throws -> String {
        var limited: Error = GeminiError.noKey
        for key in keysForRequest() {
            do {
                return try await request(key: key, model: model, system: system, input: input, generation: generation, timeout: timeout, thinking: thinking)
            } catch GeminiError.rateLimited(let retry) {
                keyLock.withLock { keyCooldown[key] = Date().addingTimeInterval(retry ?? 60) }
                if apiKeys.count > 1 { Log.warn("Gemini key …\(key.suffix(4)) hết quota (429) → thử key khác") }
                limited = GeminiError.rateLimited(retryAfter: retry)
            }
        }
        throw limited
    }

    /// POST /interactions (Gemini Interactions API): lời dặn ở `system_instruction`, nội dung ở `input`,
    /// kết quả là các bước `model_output` trong `steps` (bỏ qua bước `thought`).
    private func request(key: String, model: String, system: String, input: String, generation: [String: Any], timeout: TimeInterval, thinking: Bool) async throws -> String {
        var gen = generation
        if thinking { gen["thinking_level"] = "low" }
        let body: [String: Any] = ["model": model, "system_instruction": system, "input": input, "generation_config": gen]
        var req = URLRequest(url: URL(string: "\(baseURL)/interactions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
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

/// AI share dùng Gemini qua proxy của server: router gọi nó như các nhà cung cấp kiểu chat khác.
extension GeminiBackend: CloudChatBackend {
    var isReady: Bool { !apiKey.isEmpty && !model.isEmpty }

    func complete(system: String, user: String, json: Bool, maxTokens: Int, timeout: TimeInterval, model: String?) async throws -> String {
        try await generate(system: system, input: user, timeout: timeout, maxOutputTokens: maxTokens, model: model)
    }
}
