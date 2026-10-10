import Foundation
import AppKit
import Combine
import CoreVideo

/// Worker cho một vùng phụ đề: capture → gate → chờ ổn định → OCR → dedup → báo về Pipeline.
final class RegionWorker {
    let region: Region
    private let capture: FrameCapture
    private let gate: FrameGate
    private let ocr = VisionOCR()                 // chỉ giữ tuỳ chọn; OCR thật chạy trong tiến trình phụ (`helper`)
    private let helper: OCRClient
    // .workItem: object tạm của Vision/CoreVideo được giải phóng sau mỗi khung, không dồn lại tới khi luồng rảnh.
    private let ocrQueue = DispatchQueue(label: "ocr", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let gateQueue = DispatchQueue(label: "gate", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var ocrBusy = false                   // chỉ đọc/ghi trên gateQueue
    private var ocrStartedAt = Date()             // chỉ đọc/ghi trên gateQueue
    private var reportedHang = false              // chỉ đọc/ghi trên gateQueue
    private var stopped = false                   // chỉ đọc/ghi trên gateQueue
    private var restarting = false                // chỉ đọc/ghi trên gateQueue
    private var lastText = ""
    /// Các câu đã nhận còn đang được nhớ (để lọc trùng). `missingSince`: lần OCR đầu tiên không còn thấy câu này
    /// (nil = vẫn đang trên màn hình). Màn hình đứng yên thì không OCR nên không ai đánh dấu → câu vẫn được nhớ.
    private var recent: [(text: String, missingSince: Date?)] = []
    private let dedup: Double
    private let skipUI: Bool
    private let skipInterjections: Bool
    private let skipSimple: Bool
    private let stableDelay: TimeInterval
    private var pendingPB: CVPixelBuffer?
    private var stableTimer: DispatchWorkItem?
    private var changingSince: Date?          // video chuyển động liên tục → OCR sau maxWait dù chưa ổn định
    private let maxWait: TimeInterval
    private var frameCount = 0, ocrRuns = 0, heldFrames = 0
    // Chụp thông minh: sau khi nhận một câu, câu đó còn nằm trên màn hình một lúc (dài thì lâu, ngắn thì nhanh),
    // nên trong khoảng đó bỏ qua khung hình, không so sánh, không OCR.
    private let adaptive: Bool
    private var holdUntil = Date.distantPast      // chỉ đọc/ghi trên gateQueue
    private var dupStreak = 0
    private var lastLookAt = Date.distantPast     // lần OCR trước xong lúc nào (chỉ dùng trên ocrQueue)
    /// Cỡ chữ phụ đề đã học trong phiên (chiều cao hàng, tỉ lệ theo vùng); hàng nhỏ hơn 60 % mức này bị bỏ. Chỉ dùng trên ocrQueue.
    private var subtitleHeight: Double?
    private var statsTimer: DispatchSourceTimer?
    var onText: ((String, Region) -> Void)?
    var onEmpty: ((Region) -> Void)?
    var onUI: ((String, Region) -> Void)?       // chữ giao diện (menu/cài đặt) → bỏ qua
    var onSkipped: ((String, Region) -> Void)?  // câu quá đơn giản → chỉ ghi nhật ký, không dịch, không đọc
    var onOCR: (() -> Void)?
    var onActiveChange: ((Bool) -> Void)?
    /// Luồng chụp chết và không khởi động lại được → thông báo lỗi; nil = đã chạy lại bình thường.
    var onCaptureError: ((String?) -> Void)?
    /// Tên nhân vật đã học + game có hiện tên không (đọc trực tiếp từ settings mỗi lần OCR vì danh sách tăng dần).
    var speakerNames: () -> [String] = { [] }
    var usesNames: () -> Bool = { true }
    var namesAbove: () -> Bool = { false }
    private var appActive = true

    init(region: Region, settings: AppSettings) {
        self.region = region
        capture = region.embedded ? PS5FrameCapture(region: region, fps: settings.fps)
                                  : RegionCapture(region: region, fps: settings.fps, scale: settings.captureScale)
        gate = FrameGate(threshold: settings.diffThreshold)
        helper = OCRClient(name: region.name)
        ocr.minTextHeight = Float(settings.minTextHeight)
        ocr.level = settings.ocrAccurate ? .accurate : .fast
        ocr.centerOnly = settings.centerOnlySubtitles
        dedup = settings.dedupSimilarity
        skipUI = settings.skipUIText
        skipInterjections = settings.skipInterjections
        skipSimple = settings.skipSimpleLines
        adaptive = settings.adaptiveCapture
        stableDelay = max(0, settings.stableDelayMs) / 1000
        maxWait = max(stableDelay, 0.4)
        capture.onFrame = { [weak self] pb in
            guard let self else { return }
            self.gateQueue.async { self.handle(pb) }
        }
        capture.onStopped = { [weak self] error in
            guard let self else { return }
            self.gateQueue.async { self.restartCapture(after: error) }
        }
    }

    /// Chạy trên gateQueue. Luồng chụp bị hệ thống dừng (cửa sổ đóng, màn hình ngủ, lỗi…) → thử mở lại vài lần.
    private func restartCapture(after error: Error) {
        guard !stopped, !restarting else { return }
        restarting = true
        stableTimer?.cancel(); stableTimer = nil; pendingPB = nil; changingSince = nil
        gate.reset()
        Task { [weak self] in
            var lastError = error.localizedDescription
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                guard let self, !self.gateQueue.sync(execute: { self.stopped }) else { return }
                do {
                    try await self.capture.start()
                    // Người dùng bấm Dừng đúng lúc đang mở lại → đóng luồng vừa mở.
                    if self.gateQueue.sync(execute: { self.stopped }) { await self.capture.stop(); return }
                    Log.info("Vùng '\(self.region.name)': đã mở lại luồng chụp (lần \(attempt))")
                    self.gateQueue.async { self.restarting = false }
                    self.onCaptureError?(nil)
                    return
                } catch {
                    lastError = error.localizedDescription
                    Log.warn("Vùng '\(self.region.name)': mở lại luồng chụp lỗi (lần \(attempt)/5): \(lastError)")
                }
            }
            guard let self else { return }
            self.gateQueue.async { self.restarting = false }
            self.onCaptureError?("Mất luồng chụp: \(lastError)")
        }
    }

    func start() async throws {
        try await capture.start()
        let t = DispatchSource.makeTimerSource(queue: gateQueue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Log.info("STATS[\(self.region.name)] frames/10s=\(self.frameCount) ocr/10s=\(self.ocrRuns) nghỉ/10s=\(self.heldFrames)")
            // Một lượt OCR (bình thường dưới 0,2 s) quá 10 s chưa xong: Vision đã treo, chỉ mở lại app mới hết.
            if self.ocrBusy, Date().timeIntervalSince(self.ocrStartedAt) > 10, !self.reportedHang {
                self.reportedHang = true
                Log.error("OCR[\(self.region.name)] treo \(Int(Date().timeIntervalSince(self.ocrStartedAt))) s trong Vision")
                self.onCaptureError?("Nhận dạng chữ của macOS bị treo, phụ đề không được dịch. Thoát hẳn app (⌘Q) rồi mở lại.")
            }
            self.frameCount = 0; self.ocrRuns = 0; self.heldFrames = 0
        }
        t.resume()
        statsTimer = t
    }

    func stop() async {
        statsTimer?.cancel(); statsTimer = nil
        gateQueue.sync { stopped = true }
        await capture.stop()
        gateQueue.sync { stableTimer?.cancel(); stableTimer = nil; pendingPB = nil }
        ocrQueue.async { [helper] in helper.stop() }
    }

    /// Chạy trên gateQueue. Frame đổi → đợi `stableDelay` không có thay đổi nữa rồi mới OCR.
    private func handle(_ pb: CVPixelBuffer) {
        guard !stopped else { return }
        frameCount += 1
        if let bid = region.appBundleID, !region.followsWindow {
            let active = WindowFinder.frontmostBundleID == bid
            if active != appActive {
                appActive = active
                Log.info("Vùng '\(region.name)': \(region.appName ?? bid) \(active ? "ở phía trước → tiếp tục" : "không ở phía trước → tạm dừng")")
                if !active { stableTimer?.cancel(); stableTimer = nil; pendingPB = nil; changingSince = nil; gate.reset() }
                onActiveChange?(active)
            }
            guard active else { return }
        }
        if adaptive, Date() < holdUntil { heldFrames += 1; return }      // đang trong khoảng nghỉ
        guard let v = gate.process(pb) else { return }
        switch v {
        case .first:
            runOCR(pb)
        case .changed:
            pendingPB = pb
            let now = Date()
            if changingSince == nil { changingSince = now }
            // Nền video đổi liên tục: không đợi mãi, OCR sau maxWait kể từ lần đổi đầu tiên.
            if let since = changingSince, now.timeIntervalSince(since) >= maxWait {
                flushPending()
                return
            }
            stableTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.flushPending() }
            stableTimer = item
            gateQueue.asyncAfter(deadline: .now() + stableDelay, execute: item)
        case .unchanged:
            if pendingPB != nil { flushPending() }
        }
    }

    /// Chạy trên gateQueue: OCR frame đang chờ và reset trạng thái chờ.
    private func flushPending() {
        stableTimer?.cancel(); stableTimer = nil
        changingSince = nil
        guard let p = pendingPB else { return }
        pendingPB = nil
        runOCR(p)
    }

    /// Ước lượng một câu thoại nằm trên màn hình bao lâu (nói nhanh ~3,2 từ/giây, tối thiểu 1 s) và nghỉ nửa thời gian đó,
    /// TRỪ ĐI `lag` = khoảng app không nhìn màn hình trước khi thấy câu này (câu có thể đã hiện từ lúc đó).
    /// Nhờ vậy lúc hết nghỉ câu vẫn còn trên màn hình, câu ngắn hiện ngay sau đó không bị lọt.
    /// Câu 3 từ nghỉ 0,3–0,5 s, câu 10 từ trở lên tối đa 1,2 s. Hết nghỉ thì khung kế tiếp được OCR ngay.
    /// Câu đã đọc mà không còn thấy trên màn hình quá chừng này thì quên (đủ để bỏ qua vài khung OCR đọc trượt
    /// hoặc phụ đề nháy tắt rồi hiện lại cùng một câu).
    static let forgetAfter: TimeInterval = 4

    static func holdAfterSubtitle(_ text: String, lag: TimeInterval = 0) -> TimeInterval {
        let words = Double(text.split { $0 == " " || $0 == "\n" }.count)
        let display = max(1.0, words / 3.2)
        return min(1.2, max(0.3, display * 0.5 - max(0, lag)))
    }

    /// Đặt khoảng nghỉ (gọi từ hàng đợi OCR) và bảo bộ so khung coi khung đầu tiên sau khi nghỉ là "mới".
    private func hold(_ seconds: TimeInterval) {
        guard adaptive, seconds > 0 else { return }
        gateQueue.async { [self] in
            holdUntil = Date().addingTimeInterval(seconds)
            stableTimer?.cancel(); stableTimer = nil; pendingPB = nil; changingSince = nil
            gate.reset()
        }
    }

    private func runOCR(_ pb: CVPixelBuffer) {
        guard !ocrBusy else { pendingPB = pb; return }
        ocrBusy = true
        ocrStartedAt = Date()
        ocrRuns += 1
        ocrQueue.async { [self] in
            // Xong OCR: nếu trong lúc bận có khung mới đang chờ (và không có timer chờ ổn định) thì OCR luôn,
            // không đợi tới khung kế tiếp. Chạy sau `hold()` nên câu vừa nhận vẫn được nghỉ như cũ.
            defer {
                gateQueue.async { [self] in
                    ocrBusy = false
                    if !stopped, stableTimer == nil, pendingPB != nil { flushPending() }
                }
            }
            ocr.minRowHeight = CGFloat((subtitleHeight ?? 0) * 0.6)
            // OCR trong tiến trình phụ: Vision treo thì tiến trình phụ bị tắt và mở lại, app vẫn chạy tiếp.
            guard let r = helper.recognize(pb, accurate: ocr.level == .accurate, minTextHeight: ocr.minTextHeight,
                                           centerOnly: ocr.centerOnly, minRowHeight: ocr.minRowHeight) else { return }
            let lag = min(2.5, Date().timeIntervalSince(lastLookAt))
            lastLookAt = Date()
            onOCR?()
            // Game hiện tên ở dòng riêng phía trên: ghép "Tên" + câu bên dưới thành "Tên: câu".
            var rows = r.lines
            var nameJoined = false
            if namesAbove() { (rows, nameJoined) = SpeakerNames.joinNameAbove(rows, speakers: speakerNames()) }
            let text = nameJoined ? rows.joined(separator: " ") : r.text
            if text.isEmpty || TextUtils.letterCount(text) < 2 {
                RegionPreviewProvider.shared.reportOCR(regionID: region.id, ms: r.ms, text: text)
                if !lastText.isEmpty { lastText = ""; onEmpty?(region) }
                // Phụ đề đã biến mất: bắt đầu đếm thời gian vắng mặt của mọi câu đang nhớ.
                let now = Date()
                for i in recent.indices where recent[i].missingSince == nil { recent[i].missingSince = now }
                return
            }
            // Chữ giao diện (menu, cài đặt, danh sách) → không dịch, không đọc.
            if skipUI {
                // Dòng tên riêng (Viết Hoa, không dấu câu, cỡ chữ khác câu thoại) không được tính là dấu hiệu chữ giao diện.
                let v = nameJoined
                    ? SubtitleClassifier.classify(text: r.lines.dropFirst().joined(separator: " "), rows: max(1, r.rows - 1), maxPerRow: r.maxPerRow, heightRatio: 1)
                    : SubtitleClassifier.classify(r)
                if v.isUI {
                    RegionPreviewProvider.shared.reportOCR(regionID: region.id, ms: r.ms, text: "⏸ " + text)
                    if !TextUtils.sameLine(text, lastText, threshold: dedup) {
                        Log.info("UI[\(region.name)] bỏ qua (\(v.reasons.joined(separator: ", "))): \(text.prefix(80))")
                    }
                    lastText = text
                    onUI?(text, region)
                    hold(0.8)      // menu / màn hình cài đặt đứng yên lâu, không cần soi liên tục
                    return
                }
            }
            RegionPreviewProvider.shared.reportOCR(regionID: region.id, ms: r.ms, text: text)
            // Tách thành từng câu thoại và lọc trùng theo từng câu (so với 6 câu gần nhất trong 20 s).
            // Nhờ vậy: câu cũ còn nằm trên màn hình không bị đọc lại, hai người nói cùng lúc thành hai câu riêng.
            let now = Date()
            // Chỉ nhớ những câu ĐANG nằm trên màn hình: câu còn hiện liên tục thì không đọc lại, dù đứng yên bao lâu.
            // Câu OCR không còn thấy quá `Self.forgetAfter` giây, hoặc đã bị câu mới thay thế (xem dưới), thì quên:
            // A → B → A đọc lại A. Thời gian vắng mặt chỉ tính từ lần OCR thấy câu đã biến mất, không theo đồng hồ.
            let onScreen = SubtitleSplitter.utterances(rows: rows, speakers: speakerNames(), useNames: usesNames())
            recent.removeAll { $0.missingSince.map { now.timeIntervalSince($0) > Self.forgetAfter } ?? false }
            for i in recent.indices {
                if SubtitleSplitter.score(recent[i].text, recent: onScreen) >= dedup { recent[i].missingSince = nil }
                else if recent[i].missingSince == nil { recent[i].missingSince = now }
            }
            var fresh = SubtitleSplitter.fresh(rows: rows, speakers: speakerNames(), useNames: usesNames(),
                                               recent: recent.map(\.text), threshold: dedup)
            let changed = text != lastText
            lastText = text
            // Câu chỉ có từ cảm thán (hmm, haha, huh…): không dịch, không đọc; vẫn ghi nhớ để không xét lại.
            if skipInterjections {
                let dropped = fresh.filter(SubtitleSplitter.isInterjectionOnly)
                if !dropped.isEmpty {
                    fresh.removeAll(where: SubtitleSplitter.isInterjectionOnly)
                    for d in dropped { recent.append((d, nil)) }
                    if recent.count > 6 { recent.removeFirst(recent.count - 6) }
                    Log.info("CẢM THÁN[\(region.name)] bỏ qua: \(dropped.joined(separator: " ⏎ "))")
                    if fresh.isEmpty { return }
                }
            }
            // Mẩu chữ lạc đứng một mình (chữ trong cảnh game, nút bấm): không dịch, không đọc; ghi nhớ để không xét lại.
            if skipUI {
                let stray = fresh.filter(SubtitleSplitter.isStrayFragment)
                if !stray.isEmpty {
                    fresh.removeAll(where: SubtitleSplitter.isStrayFragment)
                    for d in stray { recent.append((d, nil)) }
                    if recent.count > 6 { recent.removeFirst(recent.count - 6) }
                    Log.info("LẠC[\(region.name)] bỏ qua: \(stray.joined(separator: " ⏎ "))")
                    if fresh.isEmpty { hold(0.6); return }
                }
            }
            // Câu quá đơn giản (1–2 từ, toàn từ cơ bản): người chơi tự hiểu → không dịch, không đọc, chỉ ghi vào nhật ký.
            // Không có từ tiếng Anh thật nào (OCR đọc bậy: "imph", "impr") thì bỏ hẳn. Đều được ghi nhớ để không xét lại.
            if skipSimple {
                let simple = fresh.filter(SubtitleSplitter.isSimple)
                if !simple.isEmpty {
                    fresh.removeAll(where: SubtitleSplitter.isSimple)
                    for d in simple { recent.append((d, nil)) }
                    if recent.count > 6 { recent.removeFirst(recent.count - 6) }
                    let real = simple.filter(SubtitleSplitter.hasEnglishWord)
                    let junk = simple.filter { !SubtitleSplitter.hasEnglishWord($0) }
                    if !real.isEmpty {
                        Log.info("ĐƠN GIẢN[\(region.name)] không dịch, chỉ ghi nhật ký: \(real.joined(separator: " ⏎ "))")
                        onSkipped?(real.joined(separator: "\n"), region)
                    }
                    if !junk.isEmpty { Log.info("VÔ NGHĨA[\(region.name)] bỏ hẳn: \(junk.joined(separator: " ⏎ "))") }
                    if fresh.isEmpty { hold(0.4); return }
                }
            }
            guard !fresh.isEmpty else {
                if changed { Log.info("DUP[\(region.name)] đã đọc rồi: \(text.prefix(60))") }
                // Câu cũ vẫn còn trên màn hình: soi thưa dần (0,4 → 0,6 s) cho tới khi có câu mới.
                dupStreak += 1
                hold(dupStreak >= 2 ? 0.6 : 0.4)
                return
            }
            dupStreak = 0
            // Có câu mới thật: câu cũ nào không còn trên màn hình là đã được thay thế → quên ngay.
            recent.removeAll { $0.missingSince != nil }
            for f in fresh { recent.append((f, nil)) }
            if recent.count > 6 { recent.removeFirst(recent.count - 6) }
            let dropped = fresh.joined(separator: " ").count < text.count - 3
            Log.info("OCR[\(region.name)] \(String(format: "%.0f", r.ms))ms conf=\(String(format: "%.2f", r.confidence)) \(r.level == .fast ? "fast" : "acc")\(fresh.count > 1 ? " [\(fresh.count) câu]" : "")\(dropped ? " [bỏ câu cũ]" : ""): \(fresh.joined(separator: " ⏎ "))")
            // Học cỡ chữ phụ đề từ những hàng chắc chắn là lời thoại (từ 4 từ trở lên).
            let sure = zip(r.lines, r.lineHeights).filter { $0.0.split(separator: " ").count >= 4 }.map(\.1)
            if let h = sure.max() { subtitleHeight = subtitleHeight.map { $0 * 0.7 + h * 0.3 } ?? h }
            onText?(fresh.joined(separator: "\n"), region)
            hold(Self.holdAfterSubtitle(fresh.joined(separator: " "), lag: lag))
        }
    }
}

/// Bản dịch mới nhất của một khu vực dịch thêm, hiện ngay tại khung đó trên hình PS5.
struct RegionCaption: Equatable {
    var source: String
    var translated: String
    var at: Date
}

@MainActor
final class Pipeline: ObservableObject {
    static let shared = Pipeline()

    @Published private(set) var isRunning = false
    @Published private(set) var ocrCount = 0
    @Published private(set) var translateCount = 0
    @Published private(set) var lastSource = ""
    @Published private(set) var lastTranslated = ""
    @Published private(set) var lastBackend: BackendKind? = nil
    @Published private(set) var lastMs = 0
    @Published private(set) var lastAt: Date? = nil
    @Published private(set) var workerErrors: [UUID: String] = [:]
    @Published private(set) var inactiveRegions: [UUID: Bool] = [:]   // true = app gắn không ở phía trước
    @Published private(set) var skippedUI: [UUID: String] = [:]        // vùng đang hiện chữ giao diện (bị bỏ qua)
    @Published private(set) var skippedCount = 0
    /// Bản dịch mới nhất của từng khu vực dịch thêm (hiện ngay tại khung trên hình PS5).
    @Published private(set) var regionCaptions: [UUID: RegionCaption] = [:]

    let settings = AppSettings.shared
    let apple: AppleTranslationBackend
    let router: TranslationRouter
    let speaker = Speaker()
    let overlay = SubtitleOverlay()
    let analyzer: ScreenAnalyzer
    private var workers: [RegionWorker] = []
    /// Giữ app không bị App Nap hãm khi chạy nền (mạng/timer bị trì hoãn vài giây nếu không có).
    private var activity: NSObjectProtocol?
    private var warmTimer: Timer?

    private init() {
        apple = AppleTranslationBackend(targetCode: settings.targetLanguage)
        router = TranslationRouter(apple: apple)
        analyzer = ScreenAnalyzer(router: router, speaker: speaker)
    }

    // MARK: control

    func toggle() {
        if isRunning { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRunning else { return }
        guard await SessionCheck.shared.authorizeAction() else { return }
        if settings.subtitleRegions.contains(where: { $0.enabled && !$0.embedded }), !CGPreflightScreenCaptureAccess() {
            Log.warn("Screen Recording permission not granted yet → requesting")
            let granted = CGRequestScreenCaptureAccess()
            Log.info("CGRequestScreenCaptureAccess → \(granted)")
            if !granted { showPermissionAlert(); return }
        }
        let regions = settings.subtitleRegions.filter(\.enabled)
        guard !regions.isEmpty else { showAlert("Chưa có vùng phụ đề", "Mở tab Màn hình: chọn vùng game (hoặc kết nối PS5) rồi vẽ khung phụ đề."); return }
        if settings.geminiAPIKey.isEmpty && apple.installed != true && !router.ai.isAvailable {
            Log.warn("No translation backend available")
            showNoBackendAlert()
        }
        resetQueue()
        applyVoiceSettings()
        router.seedContextFromHistory()
        router.prewarm()
        workerErrors = [:]
        inactiveRegions = [:]
        skippedUI = [:]
        var started: [RegionWorker] = []
        let gen = queueGeneration      // Dừng / chạy lại làm số này tăng → câu OCR xong muộn của lần chạy cũ bị bỏ
        for r in regions {
            let w = RegionWorker(region: r, settings: settings)
            w.onText = { [weak self] text, region in
                Task { @MainActor in
                    guard let self, self.queueGeneration == gen else { return }
                    self.skippedUI.removeValue(forKey: region.id)
                    self.submit(text, region: region)
                }
            }
            w.onSkipped = { [weak self] text, region in
                Task { @MainActor in
                    guard let self, self.queueGeneration == gen else { return }
                    self.logSkipped(text, region: region)
                }
            }
            w.onCaptureError = { [weak self] msg in
                Task { @MainActor in
                    guard let self, self.queueGeneration == gen else { return }
                    self.workerErrors[r.id] = msg
                }
            }
            w.onEmpty = { [weak self] region in
                Task { @MainActor in self?.skippedUI.removeValue(forKey: region.id); self?.overlay.hide() }
            }
            let st = settings
            // Khu vực dịch thêm (r.extra): không lấy tên nhân vật, chỉ OCR rồi dịch.
            w.speakerNames = { st.speakers }
            w.usesNames = { st.showsSpeakerNames && !r.extra }
            w.namesAbove = { st.showsSpeakerNames && st.speakerAbove && !r.extra }
            w.onUI = { [weak self] text, region in
                Task { @MainActor in
                    guard let self else { return }
                    if self.skippedUI[region.id] == nil { self.skippedCount += 1 }
                    self.skippedUI[region.id] = text
                    self.overlay.hide()
                }
            }
            w.onActiveChange = { [weak self] active in
                Task { @MainActor in
                    self?.inactiveRegions[r.id] = !active
                    if !active { self?.overlay.hide(); self?.speaker.stop() }
                }
            }
            w.onOCR = { [weak self] in Task { @MainActor in self?.ocrCount += 1 } }
            do {
                try await w.start()
                started.append(w)
            } catch {
                Log.error("Không start được vùng '\(r.name)': \(error.localizedDescription)")
                workerErrors[r.id] = error.localizedDescription
            }
        }
        workers = started
        isRunning = !started.isEmpty
        if isRunning, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Dịch phụ đề thời gian thực")
            Log.info("App Nap: đã tắt (latencyCritical) trong khi pipeline chạy")
        }
        if isRunning {
            applyVoiceSettings()
            speaker.preloadLocal()
            speaker.keepWarm()
            warmTimer?.invalidate()
            warmTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning, self.settings.voiceOn else { return }
                    // Chỉ giữ kết nối Edge khi vừa có thoại; im lặng lâu thì thôi (câu kế tiếp tự mở lại trong lúc dịch).
                    guard Date().timeIntervalSince(self.lastSubmitAt) < 120 else { return }
                    self.applyVoiceSettings()
                    self.speaker.keepWarm()
                }
            }
        }
        RegionPreviewProvider.shared.pipelineRunning = isRunning
        Log.info("Pipeline running with \(started.count) region(s)")
    }

    func stop() {
        guard isRunning else { return }
        Log.info("Pipeline.stop() called from: \(Thread.callStackSymbols.dropFirst().prefix(4).map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(2).joined(separator: " ")) }.joined(separator: " <- "))")
        let ws = workers
        workers = []
        isRunning = false
        warmTimer?.invalidate(); warmTimer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        RegionPreviewProvider.shared.pipelineRunning = false
        resetQueue()
        speaker.stop()
        speaker.releaseResources()
        overlay.hide()
        skippedUI = [:]
        regionCaptions = [:]
        Task { for w in ws { await w.stop() } }
        Log.info("Pipeline stopped")
    }

    func restartIfRunning() {
        guard isRunning else { return }
        stop()
        Task { try? await Task.sleep(nanoseconds: 300_000_000); await start() }
    }

    /// Xoá bản dịch đang hiện của một khu vực (khi người dùng xoá khu vực đó).
    func clearRegionCaption(_ id: UUID) { regionCaptions.removeValue(forKey: id) }

    /// Dịch thủ công toàn bộ vùng manual đang bật.
    func analyzeScreen() {
        let regions = settings.manualRegions.filter(\.enabled)
        guard !regions.isEmpty else {
            showAlert("Chưa có màn hình game", "Mở tab Màn hình: chọn vùng game (hoặc kết nối PS5) trước.")
            return
        }
        Task {
            guard await SessionCheck.shared.authorizeAction() else { return }
            if settings.overlayOn { overlay.hud("Đang phân tích màn hình…", seconds: 3) }
            if let a = await analyzer.analyze(regions: regions) {
                if settings.overlayOn {
                    overlay.hud("Xong: \(a.summary.prefix(120))", seconds: 8)
                }
            } else if let e = analyzer.lastError, settings.overlayOn {
                overlay.hud("Không phân tích được: \(e)", seconds: 4)
            }
        }
    }

    var overlayStyle: OverlayStyle {
        OverlayStyle(fontSize: settings.overlayFontSize, opacity: settings.overlayOpacity, showSource: settings.overlayShowSource,
                     maxWidth: settings.overlayMaxWidth, position: settings.overlayPosition, hideAfter: settings.overlayHideAfter)
    }

    func previewOverlay() {
        overlay.show(translated: "Đây là bản dịch hiển thị trên overlay.", source: "This is how the overlay looks.",
                     near: settings.subtitleRegions.first, style: overlayStyle)
    }

    // MARK: processing

    // MARK: hàng đợi dịch có thứ tự
    //
    // Mỗi câu thoại (và mỗi đoạn của câu dài) là một việc có số thứ tự. Việc được dịch lần lượt hoặc song song tuỳ engine,
    // nhưng luôn được ĐỌC đúng thứ tự: đoạn nào tới lượt mà đã dịch xong thì đọc ngay, không chờ cả khối.

    private struct Job {
        let seq: Int
        let text: String            // đoạn nguồn gửi đi dịch
        let speakerName: String?    // chỉ đoạn đầu của câu thoại mới có
        let region: Region
        let utterance: Int          // các đoạn cùng một câu thoại chung số này
        let lastOfUtterance: Bool
        let firstOfBatch: Bool
        let fullSource: String      // cả câu thoại (ghi nhật ký)
    }
    private var jobSeq = 0, utteranceSeq = 0
    private var nextToEmit = 0
    private var pendingJobs: [Job] = []
    private var inFlight = 0
    private var finished: [Int: (Job, TranslationRouter.Output?)] = [:]
    private var utteranceParts: [Int: [String]] = [:]
    private var utteranceMs: [Int: Int] = [:]
    private var utteranceBackend: [Int: BackendKind] = [:]
    private var batchSource = "", batchOutput = ""
    private var lastEmittedUtterance = -1
    private var queueGeneration = 0
    private var lastSubmitAt = Date()

    /// `batch` có thể gồm nhiều câu thoại (ngăn bởi xuống dòng) khi hai người nói hiện cùng lúc.
    private func submit(_ batch: String, region: Region) {
        lastSubmitAt = Date()
        if settings.queueMode == .latestWins {
            // Chế độ "chỉ giữ câu mới nhất": bỏ các việc chưa bắt đầu dịch.
            for j in pendingJobs { finished[j.seq] = (j, nil) }
            pendingJobs.removeAll()
        }
        var first = true
        for rawText in batch.split(separator: "\n").map(String.init) {
            var text = rawText
            var speakerName: String? = nil
            if settings.showsSpeakerNames && !region.extra {
                if let name = SpeakerNames.learn(from: rawText) { settings.learnSpeaker(name) }
                let n = SpeakerNames.normalize(rawText, speakers: settings.speakers)
                text = n.text
                speakerName = n.speaker
                if text != rawText { Log.info("Chuẩn hoá tên người nói: \(rawText.prefix(40)) → \(text.prefix(40))") }
            }
            let chunks = [text]     // mỗi câu thoại dịch và hiển thị nguyên vẹn (đã thử cắt đoạn: hiển thị rời rạc, bỏ)
            utteranceSeq += 1
            for (i, c) in chunks.enumerated() {
                pendingJobs.append(Job(seq: jobSeq, text: c, speakerName: i == 0 ? speakerName : nil, region: region,
                                       utterance: utteranceSeq, lastOfUtterance: i == chunks.count - 1,
                                       firstOfBatch: first, fullSource: text))
                jobSeq += 1
                first = false
            }
        }
        if settings.voiceOn { applyVoiceSettings(); speaker.prewarm() }
        pump()
    }

    private func pump() {
        let limit = max(1, router.parallelism)
        while inFlight < limit, !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            inFlight += 1
            let gen = queueGeneration
            Task { @MainActor in
                let out = await router.translate(job.text)
                guard gen == queueGeneration else { return }       // đã Dừng / đổi game trong lúc dịch
                inFlight -= 1
                if out == nil { Log.warn("No translation for: \(job.text)") }
                finished[job.seq] = (job, out)
                drain()
                pump()
            }
        }
    }

    /// Phát các việc đã xong theo đúng thứ tự.
    private func drain() {
        while let (job, out) = finished[nextToEmit] {
            finished.removeValue(forKey: nextToEmit)
            nextToEmit += 1
            if let out { emit(job, out) }
            if job.lastOfUtterance { finishUtterance(job) }
        }
    }

    private func emit(_ job: Job, _ out: TranslationRouter.Output) {
        if job.firstOfBatch { batchSource = ""; batchOutput = "" }
        // Các đoạn của cùng một câu nối liền bằng khoảng trắng; câu thoại khác thì xuống dòng.
        let sep = batchOutput.isEmpty ? "" : (job.utterance == lastEmittedUtterance ? " " : "\n")
        batchSource += sep + job.text
        batchOutput += sep + out.text
        lastEmittedUtterance = job.utterance
        utteranceParts[job.utterance, default: []].append(out.text)
        utteranceMs[job.utterance, default: 0] += out.ms
        utteranceBackend[job.utterance] = out.backend
        translateCount += 1
        Log.info("TR[\(out.backend.rawValue)] \(out.ms)ms: \(out.text)")
        // Khu vực dịch thêm: chỉ hiện bản dịch ngay tại khung (không vào dải phụ đề chung, không đọc, không gửi web).
        if job.region.extra {
            regionCaptions[job.region.id] = RegionCaption(source: batchSource, translated: batchOutput, at: Date())
            return
        }
        lastSource = batchSource
        lastTranslated = batchOutput
        lastBackend = out.backend
        lastMs = out.ms
        lastAt = Date()
        WebServer.shared.subtitle(source: batchSource, translated: batchOutput, first: job.firstOfBatch)
        if settings.voiceOn {
            applyVoiceSettings()
            let toSpeak = (settings.voiceSkipSpeaker && settings.showsSpeakerNames && job.speakerName != nil)
                ? SpeakerNames.stripForVoice(out.text, speaker: job.speakerName, speakers: settings.speakers)
                : out.text
            // Chỉ đoạn đầu của một lô mới được phép cắt câu đang đọc (nếu người dùng bật "ngắt"); các đoạn sau đọc nối tiếp.
            speaker.speak(toSpeak, enqueue: !job.firstOfBatch)
        }
        if settings.overlayOn, !job.region.embedded {   // nguồn PS5: phụ đề hiện ngay trong tab Màn hình
            overlay.show(translated: lastTranslated, source: lastSource, near: job.region, style: overlayStyle)
        }
    }

    private func finishUtterance(_ job: Job) {
        guard let parts = utteranceParts.removeValue(forKey: job.utterance), !parts.isEmpty else { return }
        let ms = utteranceMs.removeValue(forKey: job.utterance) ?? 0
        let backend = utteranceBackend.removeValue(forKey: job.utterance) ?? .apple
        HistoryStore.shared.add(region: job.region.name, source: job.fullSource, translated: parts.joined(separator: " "),
                                backend: backend, ms: ms, kind: .subtitle, target: settings.targetLanguage,
                                profile: settings.activeProfile.id.uuidString)
    }

    /// Câu quá đơn giản: ghi nguyên câu gốc vào nhật ký (không dịch, không đọc, không hiện overlay).
    private func logSkipped(_ batch: String, region: Region) {
        for raw in batch.split(separator: "\n").map(String.init) {
            var text = raw
            if settings.showsSpeakerNames {
                if let name = SpeakerNames.learn(from: raw) { settings.learnSpeaker(name) }
                text = SpeakerNames.normalize(raw, speakers: settings.speakers).text
            }
            HistoryStore.shared.add(region: region.name, source: text, translated: text, backend: .skipped, ms: 0,
                                    kind: .subtitle, target: settings.targetLanguage, profile: settings.activeProfile.id.uuidString)
        }
    }

    /// Dùng cho cờ kiểm thử --feed: đưa thẳng văn bản vào hàng đợi dịch như thể OCR vừa đọc được.
    func testFeed(_ batch: String) {
        let r = settings.subtitleRegions.first ?? Region(name: "Test", displayID: 0, x: 0, y: 0, width: 1, height: 1)
        submit(batch, region: r)
    }

    private func resetQueue() {
        queueGeneration += 1
        pendingJobs.removeAll(); finished.removeAll(); inFlight = 0
        nextToEmit = jobSeq
        utteranceParts.removeAll(); utteranceMs.removeAll(); utteranceBackend.removeAll()
    }

    private func applyVoiceSettings() {
        speaker.rate = Float(settings.voiceRate)
        speaker.interrupt = settings.interruptSpeech
        speaker.voiceIdentifier = settings.voiceIdentifier
        speaker.language = settings.targetLanguage
        speaker.adaptiveRate = settings.voiceAdaptiveRate
        speaker.catchUpBoost = settings.catchUpPercent / 100
        speaker.silent = settings.forceMute
        speaker.engine = settings.forceEngine ?? settings.voiceEngine
        speaker.edgeRatePercent = settings.edgeRatePercent
        speaker.localVoiceID = settings.localVoiceID
        speaker.localSpeed = settings.localSpeed
        speaker.edgeVoice = settings.edgeVoice.isEmpty ? EdgeTTS.defaultVoice(for: settings.targetLanguage) : settings.edgeVoice
        if speaker.onEngineFallback == nil {
            speaker.onEngineFallback = { [weak self] msg in Task { @MainActor in self?.overlay.hud(msg, seconds: 3) } }
        }
        // Giọng đọc trên TV / điện thoại: chỉ khi có máy đang xem, không thì đọc ra loa máy này như cũ.
        speaker.remote = settings.voiceOnRemote && settings.webServerOn && WebServer.shared.hasViewers
        if speaker.onRemoteAudio == nil {
            speaker.onRemoteAudio = { data, mime, flush, text in WebServer.shared.audio(data, mime: mime, flush: flush, text: text) }
        }
    }

    // MARK: alerts

    private func showPermissionAlert() {
        if settings.suppressAlerts { Log.warn("ALERT suppressed: cần quyền Ghi màn hình"); return }
        let a = NSAlert()
        a.messageText = "Cần quyền Ghi màn hình"
        a.informativeText = "Vào System Settings → Privacy & Security → Screen & System Audio Recording, bật ScreenTranslator, rồi bấm Bắt đầu lại."
        a.addButton(withTitle: "Mở System Settings")
        a.addButton(withTitle: "Đóng")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func showNoBackendAlert() {
        if settings.suppressAlerts { Log.warn("ALERT suppressed: chưa có engine dịch"); return }
        let a = NSAlert()
        a.messageText = "Chưa có engine dịch"
        a.informativeText = "Nhập Gemini API key (miễn phí tại aistudio.google.com/apikey) hoặc tải gói ngôn ngữ Apple trong Cài đặt → tab Dịch."
        a.addButton(withTitle: "Mở Cài đặt")
        a.addButton(withTitle: "Để sau")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { WindowManager.shared.showSettings() }
    }

    func showAlert(_ title: String, _ msg: String) {
        if settings.suppressAlerts { Log.warn("ALERT suppressed: \(title) – \(msg)"); return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
