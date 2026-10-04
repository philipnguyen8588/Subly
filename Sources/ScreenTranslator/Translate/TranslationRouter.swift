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

        var isGemini: Bool { self == .gemini }
        var level: Int {   // 0 xanh, 1 vàng, 2 đỏ
            switch self {
            case .gemini, .appleAI: return 0
            case .appleQuota, .appleError, .appleOnly, .aiUnavailable: return 1
            case .appleNoKey, .appleOffline, .appleNotInstalled, .geminiFailedNoApple: return 2
            }
        }
        var label: String {
            switch self {
            case .gemini: return "Gemini"
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
        ai.summaryInstructions = { [gemini] in
            "You are helping a player understand a video game screen. The user gives numbered lines of English text extracted by OCR from one screenshot. " +
            "Reply with 2-4 sentences in \(gemini.targetName) explaining what is on screen and what the player should do or know now. Output only that summary."
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
        gemini.glossary = settings.glossary
        gemini.speakers = settings.showsSpeakerNames ? settings.speakers : []
        ai.timeout = settings.aiTimeout
    }

    private var useAI: Bool { settings.engine == .appleIntelligence }

    /// Số câu nên dịch cùng lúc. Gemini (qua mạng) chạy song song được; model trên máy của Apple Intelligence xử lý
    /// lần lượt (đo thực tế: gửi song song không nhanh hơn mà còn đảo thứ tự) nên chỉ 1; Apple Translation vốn tức thì.
    var parallelism: Int { state == .gemini ? 3 : 1 }
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

    private func refreshUsage() async { usedToday = await limiter.usedToday }

    private func refreshState() {
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
    private func acquireGemini() async -> Bool {
        guard settings.engine == .auto, !gemini.apiKey.isEmpty, online else { return false }
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

    func translate(_ text: String) async -> Output? {
        let t0 = Date()
        if await acquireGemini() {
            do {
                let out = try await gemini.translate(text, context: Array(context.suffix(settings.contextPairs)))
                usedToday = await limiter.usedToday
                state = .gemini
                lastError = nil
                activeModel = gemini.activeModel
                adoptFallbackModelIfNeeded()
                remember(text, out)
                return Output(text: out, backend: .gemini, ms: Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                await handleGeminiError(error)
            }
        }
        // Apple Intelligence: khi được chọn, hoặc làm dự phòng cuối khi chưa cài gói Apple Translation.
        if (useAI || apple.installed != true), ai.isAvailable {
            do {
                let out = try await ai.translate(text, context: Array(context.suffix(settings.contextPairs)))
                if useAI { state = .appleAI; lastError = nil }
                remember(text, out)
                return Output(text: out, backend: .appleAI, ms: Int(Date().timeIntervalSince(t0) * 1000))
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

    // MARK: screen analysis

    func analyze(lines: [String]) async -> AnalysisOutput? {
        let t0 = Date()
        if await acquireGemini() {
            do {
                let r = try await gemini.analyze(lines: lines, timeout: settings.analyzeTimeout)
                usedToday = await limiter.usedToday
                state = .gemini
                lastError = nil
                activeModel = gemini.activeModel
                adoptFallbackModelIfNeeded()
                let translations = lines.indices.map { r.translations[$0 + 1] ?? "" }
                return AnalysisOutput(summary: r.summary, translations: translations, backend: .gemini,
                                      ms: Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                await handleGeminiError(error)
            }
        }
        // Không có Gemini: Apple Intelligence viết tóm tắt (nếu dùng được); dòng thì dịch bằng Apple Translation cho nhanh.
        var summary = ""
        if ai.isAvailable {
            do { summary = try await ai.summarize(lines: lines, timeout: settings.analyzeTimeout) }
            catch { Log.warn("Apple Intelligence tóm tắt lỗi: \(error.localizedDescription)") }
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
