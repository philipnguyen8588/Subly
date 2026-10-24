import Foundation
import Combine

/// Tự viết cốt truyện của game đang chơi: định kỳ khi đang dịch, một lần sau khi dừng, hoặc khi người dùng bấm cập nhật.
/// Mỗi lần lấy các câu phụ đề (và tóm tắt "Dịch màn hình") sau con trỏ đã lưu của game, gửi model cùng cốt truyện đã có,
/// rồi lưu bài viết liền mạch, đoạn diễn biến mới và nhân vật vào nhật ký. Con trỏ chỉ tiến khi lưu thành công.
@MainActor
final class StoryTracker: ObservableObject {
    static let shared = StoryTracker()

    enum Trigger { case timer, stop, manual, catchUp }

    @Published private(set) var isRunning = false
    /// Số câu đang được đưa vào cốt truyện (khi `isRunning`).
    @Published private(set) var runningLines = 0
    /// Số câu đã dịch / số lần dịch màn hình chưa được đưa vào cốt truyện của game đang chọn.
    @Published private(set) var pendingLines = 0
    @Published private(set) var pendingScreens = 0
    /// Số câu đã dịch trong cả nhật ký của game (để mời "Tóm tắt từ đầu nhật ký").
    @Published private(set) var backlogLines = 0
    @Published private(set) var lastError: String?
    /// Lý do tạm hoãn (không phải lỗi): hết quota, chưa có câu mới…
    @Published private(set) var notice: String?

    private let settings = AppSettings.shared
    private let store = HistoryStore.shared
    private var bag = Set<AnyCancellable>()
    private var loop: Task<Void, Never>?
    private var loopInterval: TimeInterval = 0
    private var stopTask: Task<Void, Never>?
    private var catchUp: Task<Void, Never>?
    /// Chuỗi cập nhật do người dùng bấm: chạy tiếp tới khi hết câu tồn, kể cả khi đang tắt tự động.
    private var chainManual = false
    /// Người dùng vừa bấm "Tóm tắt từ đầu nhật ký" và chưa lưu được lần nào → chưa đặt con trỏ ở cuối nhật ký.
    private var fromStart = false
    private var failStreak = 0
    private var nextAutoAllowed = Date.distantPast

    private static let lineCap = 150
    private static let charCap = 12_000

    private var interval: TimeInterval { settings.forceStoryInterval ?? Double(max(1, settings.storyIntervalMin)) * 60 }
    private var activeProfile: String { settings.activeProfile.id.uuidString }

    func dismissError() { lastError = nil; notice = nil }

    /// Gọi một lần lúc khởi động, sau khi `Pipeline.shared` đã có.
    func begin() {
        Pipeline.shared.$isRunning.removeDuplicates().dropFirst()
            .sink { [weak self] running in self?.pipelineChanged(running: running) }
            .store(in: &bag)
        settings.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.watch() }
            .store(in: &bag)
        store.$entries.map(\.first?.id).removeDuplicates()
            .merge(with: store.$analyses.map(\.first?.id).removeDuplicates())
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPending() }
            .store(in: &bag)
        watch()
    }

    /// Cài đặt hoặc game đổi: đặt con trỏ cho game chưa có cốt truyện, bật / tắt vòng định kỳ.
    private func watch() {
        let profile = activeProfile
        if settings.storyOn, !isRunning, !fromStart, store.loadStory(profile: profile) == nil {
            store.startStoryFromNow(profile: profile)
        }
        let want = settings.storyOn && Pipeline.shared.isRunning
        if !want {
            loop?.cancel(); loop = nil
        } else if loop == nil || loopInterval != interval {
            loop?.cancel()
            let every = interval
            loopInterval = every
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(every))
                    if Task.isCancelled { break }
                    await self?.run(.timer)
                }
            }
        }
        refreshPending()
    }

    private func pipelineChanged(running: Bool) {
        stopTask?.cancel(); stopTask = nil
        watch()
        guard !running, settings.storyOn else { return }
        // Sửa khung dịch làm pipeline dừng rồi chạy lại ngay → chờ một lúc, vẫn dừng mới coi là hết buổi chơi.
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !Pipeline.shared.isRunning else { return }
            await self?.run(.stop)
        }
    }

    func refreshPending() {
        let profile = activeProfile
        let p = store.storyPending(profile: profile)
        if pendingLines != p.lines { pendingLines = p.lines }
        if pendingScreens != p.screens { pendingScreens = p.screens }
        let b = store.storyBacklog(profile: profile)
        if backlogLines != b { backlogLines = b }
    }

    /// Nút "Cập nhật ngay": đưa các câu mới (sau con trỏ) vào cốt truyện.
    func updateNow() {
        chainManual = true
        Task { await run(.manual) }
    }

    /// Nút "Tóm tắt từ đầu nhật ký": xoá cốt truyện đang có của game rồi viết lại từ câu đầu tiên, nhiều lượt cho tới hết.
    func summarizeFromStart() {
        resetState()
        store.resetStory(fromNow: false)
        fromStart = true
        refreshPending()
        updateNow()
    }

    /// Nút "Đọc lại các màn hình đã dịch" (Bách khoa): đưa con trỏ màn hình về đầu để các màn hình nhật ký dịch trước đây
    /// được tách thành mục bách khoa / hồ sơ nhân vật; con trỏ câu phụ đề giữ nguyên nên diễn biến không bị viết lại.
    func rescanScreens() {
        resetState()
        store.rewindStoryScreens(profile: activeProfile)
        refreshPending()
        updateNow()
    }

    /// Xoá cốt truyện của game đang chọn. `fromNow`: chỉ viết tiếp từ những câu sau lúc này.
    func reset(fromNow: Bool) {
        resetState()
        store.resetStory(fromNow: fromNow)
        if fromNow { refreshPending() } else { summarizeFromStart() }
    }

    private func resetState() {
        catchUp?.cancel(); catchUp = nil
        fromStart = false
        failStreak = 0
        nextAutoAllowed = .distantPast
        lastError = nil
        notice = nil
    }

    private func minimumWeight(_ trigger: Trigger, manual: Bool) -> Int {
        if manual { return 1 }
        switch trigger {
        case .timer, .catchUp: return settings.forceStoryInterval != nil ? 3 : 15
        case .stop: return 5
        case .manual: return 1
        }
    }

    private func run(_ trigger: Trigger) async {
        guard !isRunning else { return }
        let manual = trigger == .manual || (trigger == .catchUp && chainManual)
        if trigger != .manual, trigger != .catchUp { chainManual = false }
        guard manual || settings.storyOn else { return }
        let profile = activeProfile
        let pending = store.storyPending(profile: profile)
        guard pending.lines + 5 * pending.screens >= minimumWeight(trigger, manual: manual) else {
            if trigger == .manual { notice = "Chưa có câu mới nào để đưa vào cốt truyện" }
            return
        }
        if !manual, Date() < nextAutoAllowed { return }

        isRunning = true
        runningLines = min(pending.lines, Self.lineCap)
        defer { isRunning = false; runningLines = 0; refreshPending() }
        if manual {
            guard await SessionCheck.shared.authorizeAction() else { return }
        } else {
            guard SessionCheck.shared.valid() else { return }
        }

        let current = store.loadStory(profile: profile)
        let cursor = current?.lastEntryID ?? 0, screenCursor = current?.lastAnalysisID ?? 0
        // Lỗi liên tiếp (thường do đoạn quá dài bị cắt cụt) → mỗi lần lấy ít câu hơn.
        let cap = max(40, Self.lineCap >> failStreak)
        var entries = store.storyEntries(profile: profile, after: cursor, limit: cap + 1)
        var more = entries.count > cap
        if more { entries.removeLast() }
        var chars = 0, keep = 0
        for e in entries {
            chars += e.source.count + 1
            if chars > Self.charCap, keep >= 20 { break }
            keep += 1
        }
        if keep < entries.count { entries = Array(entries.prefix(keep)); more = true }
        var screens = store.storyAnalyses(profile: profile, after: screenCursor)
        if more, let last = entries.last { screens = screens.filter { $0.timestamp <= last.timestamp } }
        // Lượt chỉ có màn hình (không có câu phụ đề mới, ví dụ khi đọc lại màn hình cũ) lấy được nhiều màn hình hơn.
        let screenCap = entries.isEmpty ? 15 : 5
        if screens.count > screenCap { screens = Array(screens.prefix(screenCap)); more = true }
        guard !entries.isEmpty || !screens.isEmpty else { return }

        let skipped = BackendKind.skipped.rawValue
        let counted = entries.filter { $0.backend != skipped }.count
        runningLines = counted
        lastError = nil
        notice = nil
        let (input, focus) = Self.buildInput(story: current, entries: entries, screens: screens)
        do {
            let out = try await Pipeline.shared.router.updateStory(input: input, focus: focus, background: !manual)
            let u = out.update
            let now = Date()
            var story = current ?? GameStory(profile: profile, narrative: "", characters: [], lastEntryID: 0, lastAnalysisID: 0,
                                             updated: now, backend: "")
            story.narrative = StoryUpdate.mergeNarrative(old: story.narrative, update: u)
            story.characters = StoryUpdate.mergeCharacters(old: story.characters, new: u.characters)
            story.lore = StoryUpdate.mergeLore(old: story.lore, new: u.lore)
            story.lastEntryID = entries.last?.id ?? cursor
            story.lastAnalysisID = screens.last?.id ?? screenCursor
            story.updated = now
            story.backend = out.backend.rawValue
            let from = entries.first?.timestamp ?? screens.first?.timestamp ?? now
            let to = entries.last?.timestamp ?? screens.last?.timestamp ?? now
            story.characters = StoryUpdate.markSeen(story.characters, in: focus, mentioned: u.characters, at: to)
            let part: StoryPart? = u.partSummary.isEmpty ? nil : StoryPart(
                id: 0, timestamp: now, profile: profile, title: u.partTitle.isEmpty ? "Diễn biến lúc \(from.hm)" : u.partTitle,
                summary: u.partSummary, from: from, to: to, entryFrom: entries.first?.id ?? cursor, entryTo: story.lastEntryID,
                lineCount: counted, backend: out.backend.rawValue, latencyMs: out.ms)
            guard store.saveStoryUpdate(story, expectedEntryCursor: cursor, part: part) else {
                Log.info("Cốt truyện: bỏ kết quả vì cốt truyện của game vừa được xoá / viết lại")
                return
            }
            fromStart = false
            failStreak = 0
            nextAutoAllowed = .distantPast
            Log.info("Cốt truyện [\(out.backend.rawValue)] +\(counted) câu, \(screens.count) màn hình, \(out.ms)ms: "
                     + "\(part?.title ?? "(không có diễn biến mới)") · truyện \(story.narrative.count) ký tự · "
                     + "\(story.characters.count) nhân vật · \(story.lore.count) mục bách khoa (id ≤ \(story.lastEntryID))")
            if more { scheduleCatchUp(manual: manual) }
        } catch {
            if case TranslationRouter.StoryError.busy = error {
                notice = error.localizedDescription + (manual ? " · sẽ tự thử lại sau 1 phút" : "")
                Log.info("Cốt truyện: \(error.localizedDescription)")
                // Chuỗi do người dùng bấm (tóm tắt cả nhật ký): hết quota thì chờ rồi chạy tiếp, không bắt bấm lại.
                if manual { scheduleCatchUp(manual: true, wait: 60) }
                return
            }
            failStreak += 1
            nextAutoAllowed = Date().addingTimeInterval(min(interval * pow(2, Double(failStreak)), 3600))
            let retrying = manual && failStreak < 3
            lastError = "Không cập nhật được cốt truyện: \(error.localizedDescription)" + (retrying ? " · đang thử lại với ít câu hơn" : "")
            Log.error("Cốt truyện \(counted) câu lỗi: \(error.localizedDescription)")
            if retrying { scheduleCatchUp(manual: true, wait: 15) }
        }
    }

    /// Còn câu tồn (nhật ký dài hơn một lượt) → chạy lượt tiếp sau một lúc, không dồn request làm hết quota/phút.
    private func scheduleCatchUp(manual: Bool, wait fixed: Double? = nil) {
        chainManual = manual
        catchUp?.cancel()
        let wait: Double = fixed ?? (settings.forceStoryInterval != nil ? 5 : (manual ? 10 : 30))
        catchUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.run(.catchUp)
        }
    }

    /// Bốn khối gửi model: cốt truyện đã có, nhân vật đã biết (chi tiết chỉ với người có mặt trong câu mới),
    /// tên các mục bách khoa đã có, câu mới.
    static func buildInput(story: GameStory?, entries: [TranslationEntry],
                           screens: [(id: Int64, timestamp: Date, text: String)]) -> (input: String, focus: String) {
        var items: [(Date, String)] = entries.map { ($0.timestamp, $0.source) }
        // Chữ gốc trên màn hình (nhật ký, codex, nhiệm vụ…), giống câu phụ đề cũng dùng bản gốc.
        items += screens.map { ($0.timestamp, "[Screen] " + String(TextUtils.normalize($0.text).prefix(1500))) }
        items.sort { $0.0 < $1.0 }
        var lines: [String] = []
        var prev: Date?
        for (t, text) in items {
            if let p = prev, t.timeIntervalSince(p) > 300 { lines.append("[…later…]") }
            lines.append(text)
            prev = t
        }
        let focus = lines.joined(separator: "\n")
        let haystack = StoryUpdate.nameKey(focus)
        var detailed: [String] = [], others: [String] = []
        for c in story?.characters ?? [] {
            guard haystack.contains(StoryUpdate.nameKey(c.name)) else { others.append(c.name); continue }
            let fields = [("role", c.role), ("personality", c.personality), ("background", c.background), ("relations", c.relations),
                          ("status", c.status)]
                .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
            detailed.append("- \(c.name): \(fields.isEmpty ? "(nothing known yet)" : fields)")
        }
        var known = detailed.joined(separator: "\n")
        if !others.isEmpty { known += (known.isEmpty ? "" : "\n") + "Other known names: " + others.joined(separator: ", ") }
        let narrative = story?.narrative ?? ""
        let loreNames = (story?.lore ?? []).map(\.name).joined(separator: ", ")
        let input = """
        STORY SO FAR:
        \(narrative.isEmpty ? "(empty: this is the first update)" : narrative)

        KNOWN CHARACTERS:
        \(known.isEmpty ? "(none yet)" : known)

        KNOWN LORE:
        \(loreNames.isEmpty ? "(none yet)" : loreNames)

        NEW LINES:
        \(focus)
        """
        return (input, focus)
    }
}
