import Foundation

final class GeminiBackend: TranslationBackend {
    let kind: BackendKind = .gemini

    static let models = [
        "gemini-2.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-3.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-3.5-flash",
    ]
    /// Thứ tự thử khi model đã chọn bị 503/404/timeout.
    static let fallbackModels = ["gemini-2.5-flash-lite", "gemini-flash-lite-latest", "gemini-2.5-flash", "gemini-3.1-flash-lite"]

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
    /// Tên game đang chơi (tên profile) để model dùng hiểu biết về thế giới của game đó.
    var gameName: String = ""
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
        return "\nCharacter names (keep exactly as written, never translate; keep the \"Name: \" prefix when the input has it): " + speakers.joined(separator: ", ") + "\n"
    }

    private var glossaryBlock: String {
        let items = glossary.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
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
        return """
        You write \(targetName) subtitles for \(source). Translate the meaning and the feeling, never word by word, \
        like a professional film subtitler. Turn slang, idioms and swearing into natural spoken \(targetName) of the same strength; \
        never translate them literally. Keep lines short and spoken, like real people talking. \
        Keep character names and game terms as written unless the glossary says otherwise. \
        Output ONLY the \(targetName) line, keeping the "Name: " prefix if the input has it, with no quotes, notes or explanations.
        \(targetName == "Vietnamese" ? Self.vietnameseStyle : "")\(story)\(glossaryBlock)
        """
    }

    /// Hướng dẫn riêng cho tiếng Việt: xưng hô là chỗ dịch máy hay sai nhất.
    static let vietnameseStyle = """
    Pronouns: by default the speaker says "tôi" and calls teammates and friends "cậu" or "anh"/"cô", strangers and officials \
    "anh"/"cô"/"ông". Use "tao/mày" only when the speaker is openly hostile or insulting. Machines and announcements say "quý khách". \
    Keep the same pronouns as the previous lines between the same people. Never use "ngươi" unless the setting is ancient. \
    "jack in" = "kết nối vào".
    Examples of the style:
    V: About to find out. → V: Sắp biết ngay đây.
    Jackie: Locked an' ready, hermano. Do your thing. → Jackie: Sẵn sàng rồi, hermano. Làm đi.
    Sheriff (hostile): Ain't buyin' it. → Sheriff: Đừng hòng tao tin.

    """

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

    // MARK: subtitle translate

    func translate(_ text: String, context: [TranslationPair]) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.noKey }
        var contents: [[String: Any]] = []
        for p in context {
            contents.append(["role": "user", "parts": [["text": p.source]]])
            contents.append(["role": "model", "parts": [["text": p.target]]])
        }
        contents.append(["role": "user", "parts": [["text": text]]])
        let gen: [String: Any] = ["temperature": 0.2, "maxOutputTokens": 256]
        let raw = try await sendWithFallback(system: subtitleSystemPrompt, contents: contents, generation: gen,
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
        let contents: [[String: Any]] = [["role": "user", "parts": [["text": numbered]]]]
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "summary": ["type": "STRING"],
                "lines": ["type": "ARRAY", "items": [
                    "type": "OBJECT",
                    "properties": ["i": ["type": "INTEGER"], "t": ["type": "STRING"]],
                    "required": ["i", "t"],
                ]],
            ],
            "required": ["summary", "lines"],
        ]
        let gen: [String: Any] = [
            "temperature": 0.3, "maxOutputTokens": 4096,
            "responseMimeType": "application/json", "responseSchema": schema,
        ]
        let raw = try await sendWithFallback(system: analysisSystemPrompt, contents: contents, generation: gen,
                                             timeout: timeout, maxAttempts: 3)
        guard let data = raw.data(using: .utf8),
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
    private func sendWithFallback(system: String, contents: [[String: Any]], generation: [String: Any],
                                  timeout: TimeInterval, maxAttempts: Int) async throws -> String {
        var lastErr: Error = GeminiError.empty
        for m in candidateModels(maxAttempts: maxAttempts) {
            do {
                let out = try await send(model: m, system: system, contents: contents, generation: generation, timeout: timeout)
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

    private func send(model: String, system: String, contents: [[String: Any]], generation: [String: Any], timeout: TimeInterval) async throws -> String {
        do {
            return try await request(model: model, system: system, contents: contents, generation: generation, timeout: timeout, thinking: true)
        } catch GeminiError.http(400, let msg) where msg.lowercased().contains("thinking") {
            return try await request(model: model, system: system, contents: contents, generation: generation, timeout: timeout, thinking: false)
        }
    }

    private func request(model: String, system: String, contents: [[String: Any]], generation: [String: Any], timeout: TimeInterval, thinking: Bool) async throws -> String {
        var gen = generation
        if thinking {
            gen["thinkingConfig"] = model.hasPrefix("gemini-2.5") ? ["thinkingBudget": 0] : ["thinkingLevel": "low"]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": gen,
        ]
        var req = URLRequest(url: URL(string: "\(baseURL)/models/\(model):generateContent")!)
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
        guard let cands = json?["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw GeminiError.empty }
        let out = parts.compactMap { p -> String? in
            if (p["thought"] as? Bool) == true { return nil }
            return p["text"] as? String
        }.joined()
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
