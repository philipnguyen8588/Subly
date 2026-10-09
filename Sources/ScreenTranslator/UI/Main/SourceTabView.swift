import SwiftUI
import AVFoundation
import CoreMedia

// MARK: - Hiển thị khung hình

/// Lớp hiển thị video: nhận khung BGRA và đưa thẳng lên AVSampleBufferDisplayLayer.
final class FrameDisplayNSView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private var sink: UUID?
    private var occlusionObserver: NSObjectProtocol?
    /// false khi cửa sổ bị thu nhỏ / che kín / ở Space khác → không đẩy khung lên màn hình (đỡ GPU).
    private var visible = true
    private let broadcaster: FrameBroadcaster

    init(broadcaster: FrameBroadcaster) {
        self.broadcaster = broadcaster
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        if let w = window {
            visible = w.occlusionState.contains(.visible)
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                       object: w, queue: .main) { [weak self] n in
                guard let self, let w = n.object as? NSWindow else { return }
                self.visible = w.occlusionState.contains(.visible)
            }
            if sink == nil { sink = broadcaster.addDisplaySink { [weak self] pb in self?.enqueue(pb) } }
        } else if let s = sink {
            broadcaster.removeDisplaySink(s); sink = nil
            display.flushAndRemoveImage()
        }
    }

    private func enqueue(_ pb: CVPixelBuffer) {
        guard visible else { return }
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr,
              let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if display.status == .failed { display.flush() }
        display.enqueue(sb)
    }

    deinit {
        if let s = sink { broadcaster.removeDisplaySink(s) }
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
    }
}

struct FrameDisplayView: NSViewRepresentable {
    let broadcaster: FrameBroadcaster
    func makeNSView(context: Context) -> FrameDisplayNSView { FrameDisplayNSView(broadcaster: broadcaster) }
    func updateNSView(_ nsView: FrameDisplayNSView, context: Context) {}
}

// MARK: - Thành phần dùng chung cho PS5 và app ngoài

/// Hình trực tiếp của game + khung phụ đề; bật `editing` rồi kéo chuột để vẽ lại khung phụ đề.
struct GameScreenView<Placeholder: View>: View {
    var broadcaster: FrameBroadcaster? = nil    // video trực tiếp (PS5)
    var stillImage: CGImage? = nil              // hoặc ảnh chụp tĩnh (app ngoài)
    let contentSize: CGSize
    let live: Bool
    let subtitleRect: CGRect?          // chuẩn hoá 0...1 theo hình
    @Binding var editing: Bool
    let onDraw: (CGRect) -> Void
    @ViewBuilder var placeholder: Placeholder

    /// Kéo chuột trên hình: vẽ khung mới (khi bật "Vẽ khung phụ đề"), kéo khung đang có để di chuyển,
    /// hoặc kéo một góc của khung để phóng to / thu nhỏ.
    private enum DragMode { case draw, move, resize(anchor: CGPoint) }
    @State private var mode: DragMode?
    @State private var liveRect: CGRect?       // khung đang kéo, theo toạ độ của view
    @State private var hovering = false
    private let handle: CGFloat = 14           // vùng bắt góc (pt)

    var body: some View {
        GeometryReader { geo in
            let vs = contentSize.width > 0 ? contentSize : CGSize(width: 16, height: 9)
            let scale = min(geo.size.width / vs.width, geo.size.height / vs.height)
            let fit = CGSize(width: vs.width * scale, height: vs.height * scale)
            let origin = CGPoint(x: (geo.size.width - fit.width) / 2, y: (geo.size.height - fit.height) / 2)
            let image = CGRect(origin: origin, size: fit)
            let frame = subtitleRect.map { r in
                CGRect(x: origin.x + r.minX * fit.width, y: origin.y + r.minY * fit.height, width: r.width * fit.width, height: r.height * fit.height)
            }
            let shown = liveRect ?? frame
            ZStack(alignment: .topLeading) {
                Color.black
                if let broadcaster { FrameDisplayView(broadcaster: broadcaster) }
                if let stillImage {
                    Image(decorative: stillImage, scale: 1).resizable().interpolation(.high)
                        .frame(width: fit.width, height: fit.height).offset(x: origin.x, y: origin.y)
                }
                if !live { placeholder.frame(maxWidth: .infinity, maxHeight: .infinity) }
                if live, let f = shown {
                    let active = editing || liveRect != nil || hovering
                    Rectangle()
                        .fill(Color.yellow.opacity(liveRect != nil ? 0.12 : 0))
                        .overlay(Rectangle().strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: liveRect != nil ? [] : [6, 4])))
                        .foregroundStyle(active ? Color.yellow : Color.yellow.opacity(0.45))
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                        .allowsHitTesting(false)
                    // Bốn ô vuông ở góc: kéo để đổi cỡ.
                    ForEach(0..<4, id: \.self) { k in
                        let c = CGPoint(x: k % 2 == 0 ? f.minX : f.maxX, y: k < 2 ? f.minY : f.maxY)
                        Rectangle().fill(Color.yellow.opacity(active ? 0.95 : 0.5))
                            .frame(width: 8, height: 8)
                            .offset(x: c.x - 4, y: c.y - 4)
                            .allowsHitTesting(false)
                    }
                    if liveRect == nil, !editing, hovering {
                        Text("Kéo để di chuyển · kéo góc để đổi cỡ")
                            .font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.yellow)
                            .offset(x: f.minX + 4, y: max(origin.y, f.minY - 22))
                            .allowsHitTesting(false)
                    }
                }
                if editing, live {
                    Text("Kéo chuột quanh chỗ phụ đề xuất hiện")
                        .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.yellow)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case .active(let p) = phase, live, let f = frame else { hovering = false; return }
                hovering = f.insetBy(dx: -handle, dy: -handle).contains(p)
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { v in
                    guard live else { return }
                    if mode == nil { mode = startMode(at: v.startLocation, frame: frame) }
                    guard let mode else { return }
                    switch mode {
                    case .draw:
                        liveRect = Self.rect(v.startLocation, v.location).intersection(image)
                    case .move:
                        guard let f = frame else { return }
                        var r = f.offsetBy(dx: v.translation.width, dy: v.translation.height)
                        r.origin.x = min(max(r.minX, image.minX), image.maxX - r.width)
                        r.origin.y = min(max(r.minY, image.minY), image.maxY - r.height)
                        liveRect = r
                    case .resize(let anchor):
                        let p = CGPoint(x: min(max(v.location.x, image.minX), image.maxX), y: min(max(v.location.y, image.minY), image.maxY))
                        liveRect = Self.rect(anchor, p)
                    }
                }
                .onEnded { _ in
                    defer { mode = nil; liveRect = nil }
                    guard live, let m = mode, let r = liveRect else { return }
                    var n = CGRect(x: (r.minX - origin.x) / fit.width, y: (r.minY - origin.y) / fit.height,
                                   width: r.width / fit.width, height: r.height / fit.height)
                    n = n.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard n.width > 0.05, n.height > 0.03 else { return }
                    onDraw(n)
                    if case .draw = m { editing = false }
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bắt đầu kéo ở đâu: góc khung → đổi cỡ (giữ góc đối diện), trong khung → di chuyển, ngoài khung → vẽ mới (nếu đang bật vẽ).
    private func startMode(at p: CGPoint, frame: CGRect?) -> DragMode? {
        if let f = frame {
            let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
            if let k = corners.indices.first(where: { abs(corners[$0].x - p.x) <= handle && abs(corners[$0].y - p.y) <= handle }) {
                return .resize(anchor: corners[3 - k])
            }
            if f.contains(p) { return .move }
        }
        return editing ? .draw : nil
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Dải phụ đề dưới hình: chỉ hiện bản dịch.
struct SubtitleStrip: View {
    @ObservedObject var pipeline = Pipeline.shared
    @ObservedObject var analyzer: ScreenAnalyzer = Pipeline.shared.analyzer
    @ObservedObject var router: TranslationRouter = Pipeline.shared.router
    let idleHint: String

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            if let e = router.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
            }
            // Luồng chụp / nhận dạng chữ hỏng (ví dụ Vision treo) và lỗi của lần Dịch màn hình gần nhất.
            ForEach(Array(pipeline.workerErrors.values.sorted()), id: \.self) { e in
                Label(e, systemImage: "exclamationmark.octagon.fill").font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
            }
            if let e = analyzer.lastError, !analyzer.isRunning {
                Label("Dịch màn hình: \(e)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
            }
            if let skipped = pipeline.skippedUI.values.first {
                Label("Đang bỏ qua chữ giao diện (menu/cài đặt): \(skipped.prefix(70))", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if pipeline.lastTranslated.isEmpty {
                Text(pipeline.isRunning ? "Đang chờ phụ đề xuất hiện…" : idleHint)
                    .font(.title3).foregroundStyle(.tertiary)
            } else {
                Text(SpeakerColors.styled(pipeline.lastTranslated, size: 21, weight: .semibold))
                    .textSelection(.enabled).lineLimit(4)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 72, alignment: .top)
    }
}

/// Nút vẽ khung phụ đề trên hình. (Nút Dịch màn hình nằm ở thanh trên cùng của cửa sổ, dùng được ở mọi tab.)
struct ScreenActions: View {
    @Binding var editing: Bool
    let enabled: Bool

    var body: some View {
        Toggle(isOn: $editing) { Label("Vẽ khung phụ đề", systemImage: "rectangle.dashed") }
            .toggleStyle(.button).disabled(!enabled)
            .help("Bật rồi kéo chuột trên hình để chọn chỗ phụ đề xuất hiện")
    }
}

// MARK: - Tab Màn hình

struct SourceTabView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            switch settings.source {
            case .ps5: PS5SourceView()
            case .external: ExternalSourceView()
            }
        }
    }
}

/// Bộ chọn nguồn hình, đặt ở đầu thanh điều khiển của cả hai chế độ.
struct SourcePicker: View {
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Picker("", selection: Binding(get: { settings.source }, set: { AppNav.shared.setSource($0) })) {
            ForEach(ProfileSource.allCases) { s in Label(s.label, systemImage: s.icon).tag(s) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Nguồn hình của game “\(settings.activeProfile.name)”")
    }
}

// MARK: PS5

struct PS5SourceView: View {
    @ObservedObject var stream = PS5Stream.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var editing = false
    @State private var pin = ""

    private var statusColor: Color {
        switch stream.state {
        case .streaming: return .green
        case .failed: return Theme.danger
        case .idle: return .secondary
        default: return .orange
        }
    }
    private var subtitleRegion: Region? { settings.regions.first { $0.embedded && $0.kind == .subtitle } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SourcePicker()
                if stream.host != nil {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stream.host?.nickname ?? "PS5").font(.callout.weight(.semibold))
                        Text(stream.isStreaming ? "\(Int(stream.videoSize.width))×\(Int(stream.videoSize.height)) · \(stream.fps) fps" : stream.state.label)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                if stream.host != nil {
                    if case .needsPin = stream.state {
                        SecureField("Mã PIN đăng nhập PS5", text: $pin).frame(width: 150)
                        Button("Gửi") { stream.sendPin(pin); pin = "" }.disabled(pin.isEmpty)
                    }
                    ScreenActions(editing: $editing, enabled: stream.isStreaming)
                    Menu {
                        Picker("Độ phân giải", selection: $settings.ps5Resolution) {
                            Text("1080p (chữ nét nhất)").tag(4)
                            Text("720p (nhẹ hơn)").tag(3)
                        }
                        Picker("Khung hình", selection: $settings.ps5FPS) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                        Toggle("Tự bắt đầu dịch khi có hình", isOn: $settings.ps5AutoTranslate)
                        Divider()
                        Button("Quên máy này…", role: .destructive) { stream.disconnect(); stream.setHost(nil) }
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderedButton).fixedSize()
                    .help("Chất lượng hình có hiệu lực ở lần kết nối sau")
                    if stream.state.isBusy {
                        Button("Ngắt") { stream.disconnect() }
                    } else {
                        Button { PS5Coordinator.connect() } label: { Label("Kết nối", systemImage: "play.fill") }
                            .buttonStyle(GradientButtonStyle(compact: true))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if stream.host == nil {
                PS5SetupView()
            } else {
                GameScreenView(broadcaster: stream, contentSize: stream.videoSize, live: stream.isStreaming,
                               subtitleRect: subtitleRegion?.rect, editing: $editing,
                               onDraw: { PS5Coordinator.setSubtitleRect($0) }) {
                    VStack(spacing: 8) {
                        Image(systemName: "playstation.logo").font(.system(size: 42)).foregroundStyle(.white.opacity(0.5))
                        Text(stream.state == .idle ? "Bấm Kết nối để lấy hình từ PS5" : stream.state.label)
                            .foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 40)
                        Text("App chỉ nhận hình để dịch. Bạn điều khiển bằng tay cầm nối thẳng với PS5.")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                    }
                }
                Divider()
                SubtitleStrip(idleHint: stream.isStreaming ? "Bấm Bắt đầu để dịch phụ đề." : " ")
            }
        }
        .onChange(of: stream.state) { _, s in PS5Coordinator.stateChanged(s) }
    }
}

// MARK: App ngoài

struct ExternalSourceView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var mirror = ExternalMirror.shared
    @ObservedObject var pipeline = Pipeline.shared
    @State private var editing = false

    /// Khung phụ đề theo tỉ lệ bên trong khung màn hình game.
    private var subtitleRect: CGRect? {
        guard let area = settings.externalArea, let sub = settings.externalSubtitle else { return nil }
        let a = WindowFinder.currentRect(of: area), s = WindowFinder.currentRect(of: sub)
        guard a.width > 1, a.height > 1 else { return nil }
        return CGRect(x: (s.minX - a.minX) / a.width, y: (s.minY - a.minY) / a.height, width: s.width / a.width, height: s.height / a.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SourcePicker()
                if let area = settings.externalArea {
                    Circle().fill(mirror.error == nil ? Color.green : Theme.danger).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(area.appName ?? "Vùng màn hình").font(.callout.weight(.semibold)).lineLimit(1)
                        Text(mirror.error ?? "\(Int(area.width))×\(Int(area.height))\(area.followsWindow ? " · bám theo cửa sổ" : "")\(mirror.capturedAt.map { " · ảnh lúc \($0.hms)" } ?? "")")
                            .font(.caption).foregroundStyle(mirror.error == nil ? Color.secondary : Theme.danger).lineLimit(1).monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                if let area = settings.externalArea {
                    Button { mirror.capture(area) } label: {
                        Label(mirror.capturing ? "Đang chụp…" : "Chụp màn hình game", systemImage: "camera")
                    }
                    .disabled(mirror.capturing)
                    .help("Chụp lại hình hiện tại của game để xem và đặt khung phụ đề. App không chụp toàn màn hình liên tục để máy nhẹ.")
                    ScreenActions(editing: $editing, enabled: mirror.image != nil)
                    Button { RegionActions.pickGameArea() } label: { Image(systemName: "viewfinder") }
                        .help("Chọn lại vùng game: vẽ lại khung toàn bộ khu vực hiển thị game trên màn hình")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if settings.externalArea == nil {
                VStack(spacing: 14) {
                    Spacer()
                    EmptyStateView(icon: "viewfinder", title: "Chọn vùng hiển thị game",
                                   message: "Mở game hoặc phim trên máy này, rồi vẽ một khung quanh toàn bộ khu vực hình của nó. App chụp một tấm ảnh của vùng đó để bạn đặt khung phụ đề.",
                                   steps: ["Bấm “Chọn vùng game” và kéo chuột quanh màn hình game", "Kéo chuột trên ảnh để đặt khung phụ đề (đã có sẵn ở dải dưới)", "Bấm Bắt đầu"])
                    Button { RegionActions.pickGameArea() } label: { Label("Chọn vùng game", systemImage: "viewfinder") }
                        .buttonStyle(GradientButtonStyle())
                    if settings.externalSubtitle != nil {
                        Text("Game này đã có khung phụ đề từ trước nên vẫn dịch được; chọn vùng game để xem hình trong app và dùng Dịch màn hình.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GameScreenView(stillImage: mirror.image,
                               contentSize: mirror.image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                               live: mirror.image != nil, subtitleRect: subtitleRect, editing: $editing,
                               onDraw: { RegionActions.setExternalSubtitle(normalized: $0) }) {
                    VStack(spacing: 8) {
                        Image(systemName: "camera").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                        Text(mirror.error ?? (mirror.capturing ? "Đang chụp…" : "Bấm “Chụp màn hình game” để lấy hình hiện tại"))
                            .foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 40)
                    }
                }
                Divider()
                SubtitleStrip(idleHint: "Bấm Bắt đầu để dịch phụ đề.")
            }
        }
        .onAppear { mirror.ensure(settings.externalArea) }
        .onChange(of: settings.externalArea) { _, a in mirror.ensure(a) }
    }
}
