import SwiftUI
import AppKit

@main
struct ScreenTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Chính file chạy này cũng là tiến trình phụ làm OCR (`--ocr-helper`), xem OCRHelper.
    init() { if OCRHelper.isHelper { OCRHelper.runHelper() } }

    // Không còn icon trên thanh menu (trước đây cập nhật theo thời gian thực, tốn tài nguyên của MenuBarAgent).
    // App chỉ có cửa sổ chính + icon Dock; scene Settings rỗng chỉ để SwiftUI có một scene và gắn menu lệnh.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Cài đặt…") { WindowManager.shared.showSettings() }.keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {
                    Button("Mở cửa sổ chính") { WindowManager.shared.showMain() }.keyboardShortcut("1", modifiers: .command)
                    Button("Game mới…") { WindowManager.shared.showMain(); AppNav.shared.showNewProfile = true }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
    }
}

/// Quản lý cửa sổ chính (tạo bằng AppKit để đóng/mở lại mà không mất state) và cửa sổ Settings.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var main: NSWindow?
    private var settings: NSWindow?
    private var translationHost: NSWindow?

    func setup() {
        // Cửa sổ ẩn 1×1 giữ TranslationSession (Apple Translation) sống suốt phiên.
        let h = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        h.alphaValue = 0
        h.ignoresMouseEvents = true
        h.hasShadow = false
        h.isExcludedFromWindowsMenu = true
        h.hidesOnDeactivate = false
        h.isReleasedWhenClosed = false
        h.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        h.contentView = NSHostingView(rootView: TranslationHostView(backend: Pipeline.shared.apple))
        h.orderFrontRegardless()
        translationHost = h
    }

    func showMain() {
        if main == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "ScreenTranslator"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 860, height: 560)
            w.contentView = NSHostingView(rootView: MainWindowView())
            w.setFrameAutosaveName("MainWindowV3")
            if !w.setFrameUsingName("MainWindowV3") { w.center() }
            main = w
        }
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Cài đặt"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.setFrameAutosaveName("SettingsWindow")
            if !w.setFrameUsingName("SettingsWindow") { w.center() }
            settings = w
        }
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        WindowManager.shared.setup()
        Log.info("ScreenTranslator launched. Profile '\(AppSettings.shared.activeProfile.name)', regions: \(AppSettings.shared.regions.count)")
        handleCommandLine()
        WebServer.shared.apply()
        RegionActions.fillMissingWindowOffsets()
        registerHotkeys()
        if !CommandLine.arguments.contains("--hidden") { WindowManager.shared.showMain() }
        if CommandLine.arguments.contains("--open-settings") { WindowManager.shared.showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMain()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Pipeline.shared.stop()
        return .terminateNow
    }

    // MARK: hotkeys

    private var hotkeyObserver: Any?

    @MainActor private func registerHotkeys() {
        let s = AppSettings.shared
        let hm = HotkeyManager.shared
        hm.unregisterAll()
        guard s.hotkeysEnabled else { return }
        hm.register(.toggle, combo: s.hotkeyToggle) { Pipeline.shared.toggle() }
        hm.register(.analyze, combo: s.hotkeyAnalyze) { Pipeline.shared.analyzeScreen() }
        hm.register(.voice, combo: s.hotkeyVoice) {
            s.voiceEnabled.toggle()
            Pipeline.shared.overlay.hud(s.voiceEnabled ? "Voice: bật" : "Voice: tắt", seconds: 1.5)
        }
        hm.register(.overlay, combo: s.hotkeyOverlay) {
            s.overlayEnabled.toggle()
            if s.overlayEnabled { Pipeline.shared.overlay.hud("Overlay: bật", seconds: 1.5) } else { Pipeline.shared.overlay.hide() }
        }
        if hotkeyObserver == nil {
            var last = (s.hotkeyToggle, s.hotkeyAnalyze, s.hotkeyVoice, s.hotkeyOverlay, s.hotkeysEnabled)
            hotkeyObserver = s.objectWillChange
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    let now = (s.hotkeyToggle, s.hotkeyAnalyze, s.hotkeyVoice, s.hotkeyOverlay, s.hotkeysEnabled)
                    if now != last { last = now; self?.registerHotkeys() }
                }
        }
    }

    // MARK: command line (test / automation)
    //   --add-region x,y,w,h[,Tên[,manual]]   toạ độ CG toàn cục (gốc trên-trái, point)
    //   --test-region x,y,w,h[,Tên]          vùng tạm, không lưu
    //   --clear-regions  --autostart  --mute  --quiet  --hidden  --analyze-once  --no-web  --web-port N
    //   --gemini-base-url <url>  --gemini-key <key>
    @MainActor private func handleCommandLine() {
        let args = CommandLine.arguments
        let settings = AppSettings.shared
        if args.contains("--mute") { settings.forceMute = true; Log.info("Muted by --mute") }
        if args.contains("--quiet") { settings.suppressAlerts = true }
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count {
            // Tên tab cũ vẫn dùng được: ps5/regions → Màn hình, live/analysis → Nhật ký.
            let map: [String: MainTab] = ["source": .source, "ps5": .source, "regions": .source, "log": .log, "live": .log, "analysis": .log, "speakers": .speakers, "glossary": .glossary]
            if let t = map[args[i + 1]] { AppNav.shared.tab = t }
        }
        if args.contains("--no-overlay") { settings.forceNoOverlay = true }
        if args.contains("--no-web") { settings.forceNoWeb = true }
        if let i = args.firstIndex(of: "--web-port"), i + 1 < args.count { settings.forceWebPort = Int(args[i + 1]) }
        if let i = args.firstIndex(of: "--voice-engine"), i + 1 < args.count { settings.forceEngine = Speaker.Engine(rawValue: args[i + 1]) }
        if let i = args.firstIndex(of: "--translate-engine"), i + 1 < args.count { settings.forceTranslationEngine = TranslationEngine(rawValue: args[i + 1]) }
        // --profile "Tên": chuyển sang game đó (tạo mới với nguồn app ngoài nếu chưa có). --delete-profile "Tên": xoá.
        if let i = args.firstIndex(of: "--delete-profile"), i + 1 < args.count, settings.profiles.count > 1 {
            settings.profiles.removeAll { $0.name == args[i + 1] }
            if !settings.profiles.contains(where: { $0.id == settings.activeProfileID }) { settings.activeProfileID = settings.profiles.first?.id }
        }
        if let i = args.firstIndex(of: "--profile"), i + 1 < args.count {
            if let p = settings.profiles.first(where: { $0.name == args[i + 1] }) { settings.activeProfileID = p.id }
            else { let p = Profile(name: args[i + 1]); settings.profiles.append(p); settings.activeProfileID = p.id }
        }
        if args.contains("--clear-regions") { settings.regions = [] }
        if let i = args.firstIndex(of: "--gemini-base-url"), i + 1 < args.count { settings.geminiBaseURL = args[i + 1] }
        if let i = args.firstIndex(of: "--gemini-key"), i + 1 < args.count { settings.geminiAPIKey = args[i + 1] }
        var i = 0
        while i < args.count {
            if args[i] == "--test-region", i + 1 < args.count {
                let parts = args[i + 1].split(separator: ",").map(String.init)
                if parts.count >= 4, let x = Double(parts[0]), let y = Double(parts[1]),
                   let w = Double(parts[2]), let h = Double(parts[3]) {
                    let display = NSScreen.screens[0].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? CGMainDisplayID()
                    var r = Region(name: parts.count > 4 ? parts[4] : "Test", displayID: display, x: x, y: y, width: w, height: h)
                    RegionActions.attachWindow(&r)
                    settings.ephemeralRegions.append(r)
                    Log.info("Test region '\(r.name)' app=\(r.appName ?? "-") offset=\(r.winOffsetX.map { Int($0) } ?? -1),\(r.winOffsetY.map { Int($0) } ?? -1)")
                }
                i += 1
            }
            if args[i] == "--add-region", i + 1 < args.count {
                let parts = args[i + 1].split(separator: ",").map(String.init)
                if parts.count >= 4, let x = Double(parts[0]), let y = Double(parts[1]),
                   let w = Double(parts[2]), let h = Double(parts[3]) {
                    let kind: RegionKind = parts.count > 5 && parts[5] == "manual" ? .manual : .subtitle
                    let name = parts.count > 4 ? parts[4] : "Vùng \(settings.regions.count + 1)"
                    let display = NSScreen.screens[0].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? CGMainDisplayID()
                    var r = Region(name: name, displayID: display, x: x, y: y, width: w, height: h, kind: kind)
                    RegionActions.attachWindow(&r)
                    settings.regions.append(r)
                    Log.info("Added \(kind.rawValue) region '\(name)' \(x),\(y) \(w)x\(h) app=\(r.appName ?? "-")")
                }
                i += 1
            }
            i += 1
        }
        // --translate "câu 1|câu 2": dịch thử qua router (không OCR, không voice), ghi kết quả vào log.
        if let i = args.firstIndex(of: "--translate"), i + 1 < args.count {
            let lines = args[i + 1].split(separator: "|").map(String.init)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let router = Pipeline.shared.router
                router.prewarm()
                for l in lines {
                    if let o = await router.translate(l) { Log.info("TEST-TR[\(o.backend.rawValue)] \(o.ms)ms: \(l) → \(o.text)") }
                    else { Log.warn("TEST-TR thất bại: \(l) (\(router.state.label))") }
                }
                Log.info("TEST-TR xong, trạng thái: \(router.state.label)")
            }
        }
        if let i = args.firstIndex(of: "--download-voice"), i + 1 < args.count { VoiceCatalog.shared.download(args[i + 1]) }
        // --speak "câu 1|câu 2": đọc thử bằng engine giọng hiện tại (kèm --mute để không phát tiếng).
        if let i = args.firstIndex(of: "--speak"), i + 1 < args.count {
            let lines = args[i + 1].split(separator: "|").map(String.init)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                while !VoiceCatalog.shared.downloading.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
                let sp = Pipeline.shared.speaker
                sp.engine = settings.forceEngine ?? settings.voiceEngine
                sp.language = settings.targetLanguage
                sp.silent = settings.forceMute
                sp.interrupt = false
                sp.localVoiceID = settings.localVoiceID
                sp.localSpeed = settings.localSpeed
                for l in lines { sp.speak(l); try? await Task.sleep(nanoseconds: 1_200_000_000) }
            }
        }
        // --feed "khối 1|khối 2": đưa lần lượt từng khối vào hàng đợi dịch (cách nhau 0,3 s) để kiểm thứ tự + thời gian.
        if let i = args.firstIndex(of: "--feed"), i + 1 < args.count {
            let batches = args[i + 1].split(separator: "|").map(String.init)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                Pipeline.shared.router.prewarm()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                Log.info("FEED bắt đầu")
                for b in batches { Pipeline.shared.testFeed(b); try? await Task.sleep(nanoseconds: 300_000_000) }
            }
        }
        if args.contains("--ps5-import") { Log.info("PS5 import: \(PS5Stream.shared.importFromChiaki())") }
        if args.contains("--ps5-connect") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PS5Coordinator.connect()
            }
        }
        // --show-shot: mở modal ảnh "dịch màn hình" mới nhất còn lưu (kiểm tra giao diện).
        if args.contains("--show-shot"), let a = HistoryStore.shared.analyses.first(where: \.hasImage) { ShotViewer.shared.show(a.id) }
        if args.contains("--show-frames") { RegionEditor.shared.showAll(settings.regions) }
        if args.contains("--autostart") { Task { @MainActor in await Pipeline.shared.start() } }
        if args.contains("--analyze-once") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Pipeline.shared.analyzeScreen()
            }
        }
    }
}
