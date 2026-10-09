import Foundation
import Network
import Combine

/// Chọn backend: Gemini nếu có key, còn quota, không cooldown, có mạng; ngược lại Apple.
@MainActor
final class TranslationRouter: ObservableObject {
    enum State: Equatable {
        case gemini
        case appleQuota(String)
        case appleNoKey
        case appleOffline
        case appleOnly
        case appleError(String)
        case appleNotInstalled
        case geminiFailedNoApple(String)   // Gemini lỗi và Apple chưa cài → không dịch được
        case appleAI                       // Apple Intelligence (model trên máy)
        case aiUnavailable(String)         // chọn Apple Intelligence nhưng chưa dùng được → Apple Translation
        case openAI                        // OpenAI (trả phí)
        case openAIFallback(String)        // chọn OpenAI nhưng không dùng được (chưa key, mất mạng, lỗi) → Apple Intelligence

        var isGemini: Bool { self == .gemini }
        var level: Int {   // 0 xanh, 1 vàng, 2 đỏ
            switch self {
            case .gemini, .appleAI, .openAI: return 0
            case .appleQuota, .appleError, .appleOnly, .aiUnavailable, .openAIFallback: return 1
            case .appleNoKey, .appleOffline, .appleNotInstalled, .geminiFailedNoApple: return 2
            }
        }
        var label: String {
            switch self {
            case .gemini: return "Gemini"
            case .openAI: return "OpenAI"
            case .openAIFallback(let s): return "Apple Intelligence · OpenAI \(s)"
            case .appleAI: return "Apple Intelligence"
            case .aiUnavailable(let s): return "Apple · Apple Intelligence \(s)"
            case .appleQuota(let s): return "Apple · Gemini \(s)"
            case .appleNoKey: return "Apple · chưa có Gemini key"
            case .appleOffline: return "Apple · offline"
            case .appleOnly: return "Apple Translation"
            case .appleError(let s): return "Apple · Gemini lỗi: \(s)"
            case .appleNotInstalled: return "Chưa có engine dịch"
            case .geminiFailedNoApple(let s): return "Gemini lỗi: \(s)"
            }
        }
    }

    struct Output {
        let text: String
        let backend: BackendKind
        let ms: Int
    }

    struct AnalysisOutput {
        let summary: String
        let translations: [String]
        let backend: BackendKind
        let ms: Int
    }

    @Published private(set) var state: State = .appleNoKey
    @Published private(set) var usedToday: Int = 0
    @Published private(set) var online = true
    @Published private(set) var lastError: String? = nil
    @Published private(set) var activeModel: String? = nil

    let gemini: GeminiBackend
    let apple: AppleTranslationBackend
    let ai = AppleIntelligenceBackend()
    let openai = OpenAIBackend()
    let limiter: RateLimiter
    private let settings = AppSettings.shared
    private var context: [TranslationPair] = []
    private let monitor = NWPathMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var lastTarget: String

    init(apple: AppleTranslationBackend) {
        self.apple = apple
        self.gemini = GeminiBackend(apiKey: settings.geminiAPIKey, model: settings.geminiModel, timeout: settings.geminiTimeout)
        self.limiter = RateLimiter(rpm: settings.rpm, rpd: settings.rpd)
        self.lastTarget = settings.targetLanguage
        applyGeminiSettings()
        ai.instructions = { [gemini] in gemini.subtitleSystemPrompt }
        openai.subtitlePrompt = { [gemini] in gemini.subtitleSystemPrompt }
        openai.analysisPrompt = { [gemini] in gemini.analysisSystemPrompt }
        ai.summaryInstructions = { [gemini] in
            "You are helping a player understand a video game screen. The user gives numbered lines of English text extracted by OCR from one screenshot. " +
            "Reply in \(gemini.targetName) with a summary of the screen. " + GeminiBackend.summaryGuide + " Output only that summary."
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.online = (path.status == .satisfied)
                self?.refreshState()
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.monitor"))
        settings.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        apple.$installed.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshState() }.store(in: &cancellables)
        Task { await refreshUsage(); refreshState() }
    }

    private func applyGeminiSettings() {
        gemini.apiKey = settings.geminiAPIKey
        gemini.model = settings.geminiModel
        gemini.timeout = settings.geminiTimeout
        gemini.baseURL = settings.geminiBaseURL
        gemini.targetName = settings.target.englishName
        gemini.glossary = settings.effectiveGlossary
        gemini.speakers = settings.showsSpeakerNames ? settings.speakers : []
        gemini.gameName = settings.activeProfile.name
        gemini.translationStyle = settings.effectiveTranslationStyle
        gemini.translationNote = settings.translationNote
        refreshStory()
        ai.timeout = settings.aiTimeout
        openai.apiKey = settings.openAIKey
        openai.model = settings.openAIModel
        openai.timeout = settings.openAITimeout
    }

    private var useAI: Bool { settings.engine == .appleIntelligence }
    private var useOpenAI: Bool { settings.engine == .openAI }

    /// Số câu nên dịch cùng lúc. Gemini (qua mạng) chạy song song được; model trên máy của Apple Intelligence xử lý
    /// lần lượt (đo thực tế: gửi song song không nhanh hơn mà còn đảo thứ tự) nên chỉ 1; Apple Translation vốn tức thì.
    var parallelism: Int { state == .gemini || state == .openAI ? 3 : 1 }
    func prewarm() { if useAI { ai.prewarm() } }

    func applySettings() {
        applyGeminiSettings()
        if settings.targetLanguage != lastTarget {
            lastTarget = settings.targetLanguage
            resetContext()
        }
        Task {
            await limiter.configure(rpm: settings.rpm, rpd: settings.rpd)
            refreshState()
        }
    }

    func resetContext() { context.removeAll() }

    /// Bắt đầu lại sau khi Dừng: lấy các câu vừa dịch trong 10 phút gần nhất của game đang chơi (nhật ký chỉ chứa game đó)
    /// làm ngữ cảnh, để những câu đầu sau khi tiếp tục vẫn giữ mạch hội thoại và cách xưng hô.
    func seedContextFromHistory() {
        let recent = HistoryStore.shared.entries
            .prefix { Date().timeIntervalSince($0.timestamp) < 600 }
            .filter { $0.backend != BackendKind.skipped.rawValue && $0.kind == .subtitle && $0.targetLang == settings.targetLanguage }
            .prefix(10)
        context = recent.reversed().map { TranslationPair(source: $0.source, target: $0.translated) }
        if !context.isEmpty { Log.info("Ngữ cảnh dịch: nạp lại \(context.count) câu gần đây từ nhật ký") }
    }

    private func refreshUsage() async { usedToday = await limiter.usedToday }

    private func refreshState() {
        if useOpenAI {
            if openai.apiKey.isEmpty { state = .openAIFallback("chưa có key"); return }
            if !online { state = .openAIFallback("offline"); return }
            if case .openAIFallback = state, lastError != nil { return }
            state = .openAI
            return
        }
        if settings.preferSpeed { state = apple.installed == false ? .appleNotInstalled : .appleOnly; return }
        if useAI {
            let st = ai.status
            state = st == .available ? .appleAI : (apple.installed == false ? .appleNotInstalled : .aiUnavailable(st.label))
            return
        }
        if gemini.apiKey.isEmpty {
            state = apple.installed == false ? .appleNotInstalled : .appleNoKey
            return
        }
        if !online { state = .appleOffline; return }
        if case .appleQuota = state { return }
        if case .appleError = state { return }
        if case .geminiFailedNoApple = state { return }
        state = .gemini
    }

    /// Có được phép gọi Gemini cho request tiếp theo không (trừ token nếu có).
    /// `forScreen`: lần "Dịch màn hình" dùng engine riêng (Cài đặt → Dịch → Dịch màn hình), không theo engine phụ đề.
    private func acquireGemini(forScreen: Bool = false) async -> Bool {
        let wanted = forScreen ? settings.screenEngine == .gemini : settings.engine == .auto
        guard wanted, !gemini.apiKey.isEmpty, online else { return false }
        if let denial = await limiter.acquire() {
            switch denial {
            case .cooldown(let s): state = .appleQuota("cooldown \(Int(s))s")
            case .minute: state = .appleQuota("hết quota/phút")
            case .day: state = .appleQuota("hết quota/ngày")
            }
            return false
        }
        return true
    }

    private func handleGeminiError(_ error: Error) async {
        let appleOK = apple.installed == true
        if case GeminiBackend.GeminiError.rateLimited(let retry) = error {
            await limiter.reportRateLimited(retryAfter: retry)
            let msg = "429, chờ \(Int(retry ?? 60))s"
            state = appleOK ? .appleQuota(msg) : .geminiFailedNoApple(msg)
            lastError = "Gemini hết quota (\(msg))"
            Log.warn("Gemini 429 → \(appleOK ? "Apple" : "không có fallback")")
        } else {
            let msg = short(error)
            state = appleOK ? .appleError(msg) : .geminiFailedNoApple(msg)
            lastError = "Gemini lỗi: \(error.localizedDescription)" + (appleOK ? "" : " · Apple Translation chưa cài gói ngôn ngữ nên không có dự phòng")
            Log.warn("Gemini error → \(appleOK ? "Apple" : "không có fallback"): \(error.localizedDescription)")
        }
    }

    // MARK: subtitle

    /// Bối cảnh cốt truyện = tóm tắt "Dịch màn hình" gần nhất có nội dung của game đang chơi (bỏ tóm tắt menu, vốn chỉ
    /// một câu ngắn). Gọi trước mỗi câu vì lần dịch màn hình mới không làm đổi cài đặt.
    private func refreshStory() {
        let story = HistoryStore.shared.analyses.first { $0.summary.count >= 80 && !$0.summary.hasPrefix("(") }?.summary ?? ""
        gemini.storyContext = String(story.prefix(500))
    }

    func translate(_ text: String) async -> Output? {
        guard SessionCheck.shared.valid() else { return nil }
        let t0 = Date()
        refreshStory()
        gemini.glossaryFocus = ([text] + context.suffix(settings.contextPairs).map(\.source)).joined(separator: "\n")
        if useOpenAI, !openai.apiKey.isEmpty, online {
            do {
                let out = try await openai.translate(text, context: Array(context.suffix(settings.contextPairs)))
                state = .openAI
                lastError = nil
                let fixed = Self.fixSpeaker(source: text, translated: out)
                remember(text, fixed)
                return Output(text: fixed, backend: .openAI, ms: Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                state = .openAIFallback("lỗi")
                lastError = error.localizedDescription
                Log.warn("OpenAI lỗi → Apple Intelligence: \(error.localizedDescription)")
            }
        }
        if await acquireGemini() {
            do {
                let out = try await gemini.translate(text, context: Array(context.suffix(settings.contextPairs)))
                usedToday = await limiter.usedToday
                state = .gemini
                lastError = nil
                activeModel = gemini.activeModel
                adoptFallbackModelIfNeeded()
                let fixed = Self.fixSpeaker(source: text, translated: out)
                remember(text, fixed)
                return Output(text: fixed, backend: .gemini, ms: Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                await handleGeminiError(error)
            }
        }
        // Apple Intelligence: khi được chọn, hoặc làm dự phòng cuối khi chưa cài gói Apple Translation.
        if (useAI || useOpenAI || apple.installed != true), ai.isAvailable {
            do {
                let out = try await ai.translate(text, context: Array(context.suffix(settings.contextPairs)))
                if useAI { state = .appleAI; lastError = nil }
                let fixed = Self.fixSpeaker(source: text, translated: out)
                remember(text, fixed)
                return Output(text: fixed, backend: .appleAI, ms: Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                Log.warn("Apple Intelligence lỗi → Apple Translation: \(error.localizedDescription)")
                if useAI, apple.installed != true { lastError = error.localizedDescription }
            }
        } else if useAI {
            refreshState()
        }
        guard apple.installed == true else {
            if case .geminiFailedNoApple = state {} else { state = .appleNotInstalled }
            Log.warn("Apple language pack not installed; skipping")
            return nil
        }
        do {
            let out = try await apple.translate(text, context: [])
            remember(text, out)
            return Output(text: out, backend: .apple, ms: Int(Date().timeIntervalSince(t0) * 1000))
        } catch {
            Log.error("Apple Translation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: story summary

    struct StoryOutput {
        let title: String
        let summary: String
        let backend: BackendKind
        let ms: Int
    }

    enum StoryError: LocalizedError {
        case noEngine, empty
        var errorDescription: String? {
            switch self {
            case .noEngine: return "Không có engine nào tóm tắt được (cần OpenAI, Gemini hoặc Apple Intelligence)"
            case .empty: return "Model trả về tóm tắt rỗng"
            }
        }
    }

    /// Tóm tắt các câu phụ đề người dùng chọn trong nhật ký. Dùng engine của "Dịch màn hình" (OpenAI / Gemini);
    /// lỗi hoặc không có thì dùng Apple Intelligence.
    func summarizeStory(lines: [String]) async throws -> StoryOutput {
        let t0 = Date()
        gemini.glossaryFocus = lines.joined(separator: "\n")
        let system = gemini.storySummaryPrompt
        let jsonRule = "\nReply with JSON only, no code fences and no other text, exactly in this shape:\n{\"title\": \"…\", \"summary\": \"…\"}"
        let input = lines.joined(separator: "\n")
        let timeout = max(settings.analyzeTimeout, 60)
        var lastErr: Error = StoryError.noEngine
        func output(_ raw: String, _ backend: BackendKind) throws -> StoryOutput {
            let (title, summary) = Self.parseStory(raw)
            guard !summary.isEmpty else { throw StoryError.empty }
            return StoryOutput(title: title, summary: summary, backend: backend, ms: Int(Date().timeIntervalSince(t0) * 1000))
        }
        if settings.screenEngine == .openAI, !openai.apiKey.isEmpty, online {
            do {
                let raw = try await openai.complete(system: system + jsonRule, user: input, json: true, maxTokens: 2500, timeout: timeout)
                return try output(raw, .openAI)
            } catch {
                Log.warn("OpenAI (tóm tắt) lỗi → engine khác: \(error.localizedDescription)")
                lastErr = error
            }
        }
        if await acquireGemini(forScreen: true) {
            do {
                let raw = try await gemini.generate(system: system + jsonRule, input: input, timeout: timeout)
                usedToday = await limiter.usedToday
                activeModel = gemini.activeModel
                return try output(raw, .gemini)
            } catch {
                await handleGeminiError(error)
                lastErr = error
            }
        }
        if ai.isAvailable {
            do { return try output(try await summarizeStoryOnDevice(lines, system: system), .appleAI) }
            catch {
                Log.warn("Apple Intelligence (tóm tắt) lỗi: \(error.localizedDescription)")
                lastErr = error
            }
        }
        throw lastErr
    }

    /// Model trên máy chỉ có 4096 token: đoạn dài thì tóm tắt từng phần rồi gộp lại.
    private func summarizeStoryOnDevice(_ lines: [String], system: String) async throws -> String {
        let plain = "\nReply in plain text: the title alone on the first line, then an empty line, then the summary."
        var chunks: [String] = [], cur = ""
        for l in lines {
            if !cur.isEmpty, cur.count + l.count > 2200 { chunks.append(cur); cur = "" }
            cur += l + "\n"
        }
        if !cur.isEmpty { chunks.append(cur) }
        if chunks.count == 1 { return try await ai.generate(system: system + plain, prompt: chunks[0], timeout: 60) }
        var parts: [String] = []
        for c in chunks {
            let s = try await ai.generate(system: system + "\nThis is one part of a longer scene. Output only the summary of this part, no title.",
                                          prompt: c, timeout: 60)
            parts.append(TextUtils.normalize(s))
        }
        var joined = ""
        for (i, p) in parts.enumerated() where joined.count < 2600 { joined += "Part \(i + 1): \(p)\n\n" }
        return try await ai.generate(system: system + "\nThe user sends summaries of consecutive parts of one scene; merge them into one summary." + plain,
                                     prompt: joined, timeout: 60)
    }

    /// Đọc {"title", "summary"} (hoặc văn bản thường: dòng đầu là tiêu đề), giữ xuống đoạn.
    static func parseStory(_ raw: String) -> (title: String, summary: String) {
        func clean(_ s: String) -> String {
            s.components(separatedBy: "\n")
                .map { TextUtils.normalize($0) }
                .split(whereSeparator: \.isEmpty).map { $0.joined(separator: " ") }
                .joined(separator: "\n\n")
        }
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
           let data = String(raw[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (TextUtils.normalize((obj["title"] as? String) ?? ""), clean((obj["summary"] as? String) ?? ""))
        }
        var rows = raw.components(separatedBy: "\n")
        while let f = rows.first, f.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeFirst() }
        guard !rows.isEmpty else { return ("", "") }
        var title = rows.removeFirst().trimmingCharacters(in: .whitespaces)
        for p in ["#", "*", "Title:", "Tiêu đề:"] { while title.hasPrefix(p) { title = String(title.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) } }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "*\"“”"))
        let summary = clean(rows.joined(separator: "\n"))
        return summary.isEmpty ? ("", clean(title)) : (title, summary)
    }

    // MARK: screen analysis

    func analyze(lines: [String]) async -> AnalysisOutput? {
        let t0 = Date()
        gemini.glossaryFocus = lines.joined(separator: "\n")
        if settings.screenEngine == .openAI, !openai.apiKey.isEmpty, online {
            do {
                let r = try await openai.analyze(lines: lines, timeout: settings.analyzeTimeout)
                Log.info("Dịch màn hình bằng OpenAI (\(openai.model))")
                let translations = lines.indices.map { r.translations[$0 + 1] ?? "" }
                return AnalysisOutput(summary: r.summary, translations: translations, backend: .openAI,
                                      ms: Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                Log.warn("OpenAI (dịch màn hình) lỗi → engine trên máy: \(error.localizedDescription)")
            }
        }
        if await acquireGemini(forScreen: true) {
            do {
                let r = try await gemini.analyze(lines: lines, timeout: settings.analyzeTimeout)
                usedToday = await limiter.usedToday
                activeModel = gemini.activeModel
                adoptFallbackModelIfNeeded()
                Log.info("Dịch màn hình bằng Gemini (\(gemini.activeModel ?? settings.geminiModel))")
                let translations = lines.indices.map { r.translations[$0 + 1] ?? "" }
                return AnalysisOutput(summary: r.summary, translations: translations, backend: .gemini,
                                      ms: Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                await handleGeminiError(error)
            }
        }
        // Không dùng / không được Gemini: Apple Intelligence viết tóm tắt (nếu dùng được). Dòng chữ: chọn Apple Intelligence
        // thì dịch bằng nó (có ngữ cảnh), còn lại dịch bằng Apple Translation cho nhanh.
        var summary = ""
        if ai.isAvailable {
            do { summary = try await ai.summarize(lines: lines, timeout: settings.analyzeTimeout) }
            catch { Log.warn("Apple Intelligence tóm tắt lỗi: \(error.localizedDescription)") }
        }
        if settings.screenEngine == .appleIntelligence, ai.isAvailable,
           let out = try? await ai.translateBatch(lines, timeout: settings.analyzeTimeout) {
            return AnalysisOutput(summary: summary, translations: out, backend: .appleAI,
                                  ms: Int(Date().timeIntervalSince(t0) * 1000))
        }
        guard apple.installed == true else {
            if ai.isAvailable, let out = try? await ai.translateBatch(lines, timeout: settings.analyzeTimeout) {
                return AnalysisOutput(summary: summary, translations: out, backend: .appleAI,
                                      ms: Int(Date().timeIntervalSince(t0) * 1000))
            }
            if case .geminiFailedNoApple = state {} else { state = .appleNotInstalled }
            return nil
        }
        do {
            let out = try await apple.translateBatch(lines)
            return AnalysisOutput(summary: summary, translations: out, backend: summary.isEmpty ? .apple : .appleAI,
                                  ms: Int(Date().timeIntervalSince(t0) * 1000))
        } catch {
            Log.error("Apple batch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Model đã chọn không tồn tại → lưu model dự phòng đang chạy làm mặc định để khỏi thử lại mãi.
    private func adoptFallbackModelIfNeeded() {
        if gemini.chosenModelMissing, let a = gemini.activeModel, a != settings.geminiModel {
            Log.warn("Model \(settings.geminiModel) không tồn tại → đổi cài đặt sang \(a)")
            settings.geminiModel = a
        }
    }

    /// Tên người nói trong bản dịch phải khớp câu gốc. Model có lúc chép nguyên chữ "Name:" của lời dặn, gắn tên của câu
    /// trước vào câu không có người nói ("Call Elevator" → "Mechanic: …"), hoặc dịch mất tên.
    static func fixSpeaker(source: String, translated: String) -> String {
        let pattern = #"^\s*[^:：\n]{1,30}[:：]\s+"#
        func head(_ s: String) -> Range<String.Index>? {
            guard let r = s.range(of: pattern, options: .regularExpression),
                  s[r].split(separator: " ").count <= 6 else { return nil }
            return r
        }
        var out = translated.trimmingCharacters(in: .whitespaces)
        // Bỏ các tiền tố thừa ở đầu bản dịch (có thể lặp: "Name: Regina: …").
        // Câu gốc chỉ có người nói khi phần trước dấu hai chấm đúng dạng tên ("Jackie", "Coach Fred", "V"), không phải nhãn
        // như "Warning:", "Note:".
        var srcName: String?
        if let r = head(source), SpeakerNames.learn(from: source) != nil {
            srcName = String(source[r]).trimmingCharacters(in: .whitespaces)
        }
        // Chỉ xoá tiền tố trông như tên tiếng Anh do model chèn vào ("Name:", "Mechanic:"); nhãn đã dịch ("Cảnh báo:") giữ nguyên.
        func injected(_ h: String) -> Bool {
            let n = h.dropLast().trimmingCharacters(in: .whitespaces)
            return n.lowercased() == "name" || n.lowercased() == "tên" || SpeakerNames.learn(from: h + " x") != nil
        }
        var guardCount = 0
        while let r = head(out), guardCount < 3 {
            let h = String(out[r]).trimmingCharacters(in: .whitespaces)
            let isSrc = srcName.map { h.lowercased().hasPrefix($0.lowercased().dropLast()) } ?? false
            // Câu gốc có người nói mà bản dịch mở đầu bằng tên khác → model đã dịch tên ("Mechanic:" → "Thợ máy:"): thay lại.
            let translatedName = srcName != nil && guardCount == 0
            guard isSrc || injected(h) || translatedName else { break }
            out = String(out[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guardCount += 1
            if isSrc { break }
        }
        guard !out.isEmpty else { return translated }
        if let n = srcName { return n + " " + out }
        return out
    }

    private func remember(_ s: String, _ t: String) {
        context.append(TranslationPair(source: s, target: t))
        if context.count > 20 { context.removeFirst(context.count - 20) }
    }

    private func short(_ e: Error) -> String {
        if case GeminiBackend.GeminiError.http(let code, _) = e {
            switch code {
            case 503: return "503 quá tải"
            case 404: return "404 model không có"
            case 400: return "400 request sai"
            case 401, 403: return "\(code) key không hợp lệ"
            default: return "HTTP \(code)"
            }
        }
        if let u = e as? URLError, u.code == .timedOut { return "timeout" }
        let s = e.localizedDescription
        return s.count > 40 ? String(s.prefix(40)) + "…" : s
    }
}
