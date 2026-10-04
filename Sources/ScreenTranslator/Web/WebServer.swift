import Foundation
import AppKit
import Network
import Combine

/// Máy chủ web nhỏ trong mạng nội bộ: iPhone/iPad mở bằng Safari để xem phụ đề thời gian thực, xem lại nhật ký
/// và bấm "Dịch màn hình". HTTP thuần trên Network.framework; sự kiện đẩy xuống bằng Server-Sent Events (GET /events).
final class WebServer: ObservableObject, @unchecked Sendable {
    static let shared = WebServer()

    enum Status: Equatable {
        case off, starting
        case running(port: Int)
        case failed(String)
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var clientCount = 0

    private let queue = DispatchQueue(label: "web")
    private var listener: NWListener?                              // chỉ dùng trên main
    private var port = 0                                           // chỉ dùng trên main
    private var cancellables: Set<AnyCancellable> = []             // chỉ dùng trên main
    private var streams: [ObjectIdentifier: NWConnection] = [:]    // các máy đang mở /events; chỉ dùng trên `queue`
    private var heartbeat: DispatchSourceTimer?                    // chỉ dùng trên `queue`
    private var lastSubtitle: Data?                                // chỉ dùng trên `queue`
    private var lastState: Data?                                   // chỉ dùng trên `queue`
    private var icon: Data?                                        // chỉ dùng trên `queue`

    private struct SubtitleDTO: Encodable { let source, translated: String; let first: Bool; let at: Double }
    /// `speakers` + `names`: để trang web tô màu tên nhân vật giống trên app (màu theo thứ tự tên đã học của game).
    private struct StateDTO: Encodable, Equatable {
        let running, analyzing: Bool; let profile, profileID: String; let names: Bool; let speakers: [String]
    }
    private var sentState: StateDTO?                               // chỉ dùng trên main
    private struct EntryDTO: Encodable {
        let id: Int64; let at: Double; let source, translated: String
        let skipped: Bool      // câu quá đơn giản: không dịch, chỉ có câu gốc
        init(_ e: TranslationEntry) {
            id = e.id; at = e.timestamp.timeIntervalSince1970; source = e.source; translated = e.translated
            skipped = e.backend == BackendKind.skipped.rawValue
        }
    }
    /// Một lần dịch màn hình. `image`: còn ảnh chụp (GET /api/shot/<id>.jpg); `items`: vị trí khối chữ theo tỉ lệ 0...1 của ảnh.
    private struct AnalysisDTO: Encodable {
        let id: Int64; let at: Double; let summary: String; let lines: [AnalysisLine]; let ms: Int
        let image: Bool; let width, height: Int; let items: [ShotItem]
        init(_ a: ScreenAnalysis) {
            id = a.id; at = a.timestamp.timeIntervalSince1970; summary = a.summary; lines = a.lines; ms = a.latencyMs
            image = a.hasImage; width = a.imageWidth; height = a.imageHeight; items = a.hasImage ? a.items : []
        }
    }
    private struct ResultDTO: Encodable { let ok: Bool; let error: String?; var id: Int64? = nil }
    private struct AudioDTO: Encodable { let id: Int; let mime: String; let flush: Bool; let text: String }
    private var clips: [Int: (Data, String)] = [:]                 // giọng đọc gửi TV; chỉ dùng trên `queue`
    private var clipSeq = 0                                        // chỉ dùng trên `queue`
    /// Trang web chỉ thấy nhật ký của game đang chọn trên app.
    private static var activeProfile: String { AppSettings.shared.activeProfile.id.uuidString }

    // MARK: bật / tắt

    /// Bật, tắt hoặc đổi cổng theo cài đặt hiện tại. Gọi lúc mở app và mỗi khi cài đặt web đổi.
    @MainActor func apply() {
        let s = AppSettings.shared
        let wanted = s.webServerOn ? s.webPort : 0
        if wanted > 0, wanted == port, listener != nil { return }
        stop()
        guard wanted > 0 else { return }
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: wanted)), wanted <= 65535 else {
            status = .failed("Cổng \(wanted) không hợp lệ"); return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Chỉ IPv4: cùng với kiểm tra dải địa chỉ nội bộ bên dưới, máy ngoài mạng nhà không vào được.
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        do {
            let l = try NWListener(using: params, on: p)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.listener === l else { return }
                    switch state {
                    case .ready:
                        self.status = .running(port: wanted)
                        Log.info("Web: đang phục vụ tại \(WebServer.urls(port: wanted).joined(separator: ", "))")
                    case .failed(let e):
                        Log.error("Web: không mở được cổng \(wanted): \(e.localizedDescription)")
                        self.status = .failed("Không mở được cổng \(wanted) (đang bị app khác dùng?)")
                        l.cancel(); self.listener = nil; self.port = 0
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            status = .starting
            listener = l
            port = wanted
            observe()
            l.start(queue: queue)
        } catch {
            status = .failed(error.localizedDescription)
            Log.error("Web: \(error.localizedDescription)")
        }
    }

    @MainActor private func stop() {
        guard listener != nil else { status = .off; return }
        listener?.cancel(); listener = nil; port = 0
        status = .off
        queue.async { [self] in
            for c in streams.values { c.cancel() }
            streams.removeAll()
            heartbeat?.cancel(); heartbeat = nil
            reportClients()
        }
        Log.info("Web: đã tắt")
    }

    /// Theo dõi trạng thái app để đẩy xuống các máy đang xem (đăng ký một lần).
    @MainActor private func observe() {
        guard cancellables.isEmpty else { return }
        let pipeline = Pipeline.shared, history = HistoryStore.shared
        // @Published báo trước khi giá trị đổi → chuyển sang vòng lặp main kế tiếp rồi mới đọc trạng thái.
        Publishers.Merge3(pipeline.$isRunning.map { _ in () }, pipeline.analyzer.$isRunning.map { _ in () },
                          AppSettings.shared.objectWillChange.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in Task { @MainActor in self?.pushState() } }
            .store(in: &cancellables)
        pushState()
        var lastEntry = history.entries.first?.id ?? 0
        history.$entries.dropFirst()
            .sink { [weak self] entries in
                if entries.isEmpty { self?.broadcast("cleared", Data("{}".utf8)) }
                for e in entries.prefix(while: { $0.id > lastEntry }).reversed() where e.profile == Self.activeProfile {
                    self?.broadcast("entry", Self.json(EntryDTO(e)))
                }
                lastEntry = entries.first?.id ?? 0
            }
            .store(in: &cancellables)
        history.$analyses.dropFirst()
            .sink { [weak self] _ in self?.broadcast("analysis", Data("{}".utf8)) }
            .store(in: &cancellables)
    }

    @MainActor private func pushState() {
        let p = Pipeline.shared, s = AppSettings.shared
        let state = StateDTO(running: p.isRunning, analyzing: p.analyzer.isRunning, profile: s.activeProfile.name,
                             profileID: s.activeProfile.id.uuidString, names: s.showsSpeakerNames, speakers: s.speakers)
        guard state != sentState else { return }
        let switched = sentState != nil && sentState?.profileID != state.profileID
        sentState = state
        let data = Self.json(state)
        queue.async { [self] in
            if switched { lastSubtitle = nil }      // đổi game: câu phụ đề của game cũ không gửi cho máy mới vào nữa
            lastState = data
            send("state", data, to: Array(streams.values))
        }
    }

    // MARK: sự kiện

    /// Pipeline gọi mỗi khi có bản dịch mới. `first` = câu đầu của một lượt phụ đề (các câu sau nối thêm vào cùng lượt).
    func subtitle(source: String, translated: String, first: Bool) {
        let data = Self.json(SubtitleDTO(source: source, translated: translated, first: first, at: Date().timeIntervalSince1970))
        queue.async { [self] in
            lastSubtitle = data
            send("subtitle", data, to: Array(streams.values))
        }
    }

    /// Giọng đọc phát trên TV / điện thoại: giữ tạm các đoạn âm thanh gần nhất (GET /api/audio/<id>) và báo cho máy đang xem.
    /// `flush` = bỏ câu đang đọc dở để đọc câu này ngay.
    func audio(_ data: Data, mime: String, flush: Bool, text: String) {
        queue.async { [self] in
            clipSeq += 1
            clips[clipSeq] = (data, mime)
            if clips.count > 30 { clips = clips.filter { $0.key > clipSeq - 30 } }
            send("audio", Self.json(AudioDTO(id: clipSeq, mime: mime, flush: flush, text: text)), to: Array(streams.values))
        }
    }

    /// Có máy nào (TV, điện thoại) đang mở trang / app xem phụ đề không.
    var hasViewers: Bool { clientCount > 0 }

    private func broadcast(_ event: String, _ data: Data) {
        queue.async { [self] in send(event, data, to: Array(streams.values)) }
    }

    /// Chạy trên `queue`.
    private func send(_ event: String, _ data: Data, to targets: [NWConnection]) {
        guard !targets.isEmpty else { return }
        var msg = Data("event: \(event)\ndata: ".utf8)
        msg.append(data)
        msg.append(Data("\n\n".utf8))
        for c in targets { c.send(content: msg, completion: .contentProcessed { err in if err != nil { c.cancel() } }) }
    }

    private static func json<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data("{}".utf8) }

    // MARK: kết nối (chạy trên `queue`)

    private func accept(_ c: NWConnection) {
        guard Self.isLocal(c.endpoint) else {
            Log.warn("Web: từ chối kết nối từ ngoài mạng nội bộ: \(c.endpoint)")
            c.cancel(); return
        }
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self, self.streams.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
                self.reportClients()
            default: break
            }
        }
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.route(c, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || err != nil || buf.count > 32_768 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func route(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0])
        let target = parts[1].split(separator: "?", maxSplits: 1)
        let path = String(target.first ?? "/")
        let query = target.count > 1 ? String(target[1]) : ""

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(c, type: "text/html; charset=utf-8", body: Data(WebPage.html.utf8))
        case ("GET", "/events"):
            openStream(c)
        case ("GET", "/icon.png"):
            if let icon { respond(c, type: "image/png", body: icon, cache: true); return }
            Task { @MainActor in
                let png = Self.iconPNG()
                self.queue.async {
                    self.icon = png
                    if let png { self.respond(c, type: "image/png", body: png, cache: true) } else { self.respond(c, status: "404 Not Found", type: "text/plain", body: Data()) }
                }
            }
        case ("GET", "/api/log"):
            let limit = query.split(separator: "&").first { $0.hasPrefix("limit=") }.flatMap { Int($0.dropFirst(6)) } ?? 300
            Task { @MainActor in
                let profile = Self.activeProfile
                let body = Self.json(HistoryStore.shared.entries.lazy.filter { $0.profile == profile }.prefix(max(1, min(limit, 2000))).map(EntryDTO.init))
                self.queue.async { self.respond(c, type: "application/json", body: body) }
            }
        case ("GET", "/api/analyses"):
            Task { @MainActor in
                let profile = Self.activeProfile
                let body = Self.json(HistoryStore.shared.analyses.lazy.filter { $0.profile == profile }.prefix(100).map(AnalysisDTO.init))
                self.queue.async { self.respond(c, type: "application/json", body: body) }
            }
        case ("GET", _) where path.hasPrefix("/api/shot/") && path.hasSuffix(".jpg"):
            // Ảnh chụp đã lưu; ?thumb=1 trả ảnh thu nhỏ cho danh sách.
            guard let id = Int64(path.dropFirst("/api/shot/".count).dropLast(4)) else { c.cancel(); return }
            let data = query.contains("thumb=1") ? ShotImages.thumbnailJPEG(id, maxPixel: 480) : try? Data(contentsOf: HistoryStore.shotURL(id))
            guard let data else { respond(c, status: "404 Not Found", type: "text/plain", body: Data()); return }
            respond(c, type: "image/jpeg", body: data, cache: true)
        case ("GET", _) where path.hasPrefix("/api/audio/"):
            // Giọng đọc của một câu (WAV hoặc MP3), TV / điện thoại tải về để phát.
            let name = path.dropFirst("/api/audio/".count)
            guard let id = Int(name.split(separator: ".").first ?? ""), let clip = clips[id] else {
                respond(c, status: "404 Not Found", type: "text/plain", body: Data()); return
            }
            respond(c, type: clip.1, body: clip.0)
        case ("POST", _) where !lines.contains(where: { $0.lowercased().hasPrefix("x-screentranslator:") }):
            // Header riêng buộc trình duyệt phải hỏi trước (preflight) nếu trang web khác gọi tới → trang lạ không bấm hộ được.
            respond(c, status: "403 Forbidden", type: "text/plain", body: Data())
        case ("POST", "/api/toggle"):
            Task { @MainActor in
                let p = Pipeline.shared
                var error: String?
                if p.isRunning {
                    p.stop()
                } else {
                    let regions = p.settings.subtitleRegions.filter(\.enabled)
                    if regions.isEmpty {
                        error = "Chưa có vùng phụ đề. Mở tab Màn hình trên Mac để vẽ khung phụ đề."
                    } else if regions.contains(where: { !$0.embedded }), !CGPreflightScreenCaptureAccess() {
                        error = "App trên Mac chưa có quyền Ghi màn hình."
                    } else {
                        await p.start()
                        if !p.isRunning { error = "Không bắt đầu được. Xem thông báo trên Mac." }
                    }
                }
                Log.info("Web: bật/tắt dịch phụ đề từ xa → \(error ?? (p.isRunning ? "đang chạy" : "đã dừng"))")
                let body = Self.json(ResultDTO(ok: error == nil, error: error))
                self.queue.async { self.respond(c, type: "application/json", body: body) }
            }
        case ("POST", "/api/analyze"):
            Task { @MainActor in
                let p = Pipeline.shared
                let regions = p.settings.manualRegions.filter(\.enabled)
                var error: String?
                var shot: ScreenAnalysis?
                if regions.isEmpty {
                    error = "Chưa chọn màn hình game. Mở tab Màn hình trên Mac để chọn vùng game hoặc kết nối PS5."
                } else if p.analyzer.isRunning {
                    error = "Đang dịch, đợi một chút."
                } else {
                    shot = await p.analyzer.analyze(regions: regions, present: false)
                    if shot == nil { error = p.analyzer.lastError ?? "Không dịch được." }
                }
                Log.info("Web: dịch màn hình từ xa → \(error ?? "xong")")
                let body = Self.json(ResultDTO(ok: error == nil, error: error, id: shot?.id))
                self.queue.async { self.respond(c, type: "application/json", body: body) }
            }
        default:
            respond(c, status: "404 Not Found", type: "text/plain; charset=utf-8", body: Data("Không có trang này".utf8))
        }
    }

    private func respond(_ c: NWConnection, status: String = "200 OK", type: String, body: Data, cache: Bool = false) {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: \(cache ? "max-age=86400" : "no-store")\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func openStream(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 2000\n\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { err in if err != nil { c.cancel() } })
        streams[ObjectIdentifier(c)] = c
        // Máy vừa mở trang thấy ngay trạng thái và câu phụ đề gần nhất.
        if let lastState { send("state", lastState, to: [c]) }
        if let lastSubtitle { send("subtitle", lastSubtitle, to: [c]) }
        reportClients()
        if heartbeat == nil {
            // Dòng chú thích định kỳ: giữ kết nối sống và phát hiện máy đã rời đi.
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 20, repeating: 20)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if self.streams.isEmpty { self.heartbeat?.cancel(); self.heartbeat = nil; return }
                let ping = Data(": ping\n\n".utf8)
                for c in self.streams.values { c.send(content: ping, completion: .contentProcessed { err in if err != nil { c.cancel() } }) }
            }
            t.resume()
            heartbeat = t
        }
    }

    private func reportClients() {
        let n = streams.count
        DispatchQueue.main.async { self.clientCount = n }
    }

    // MARK: địa chỉ

    /// Chỉ nhận máy trong mạng nội bộ (dải địa chỉ riêng, link-local, loopback, và 100.64/10 của VPN kiểu Tailscale).
    private static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let v4: IPv4Address
        switch host {
        case .ipv4(let a): v4 = a
        case .ipv6(let a):
            guard let mapped = a.asIPv4 else { return a.isLoopback }
            v4 = mapped
        default: return false
        }
        let b = [UInt8](v4.rawValue)
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    /// Địa chỉ IPv4 của máy trong mạng nội bộ (ưu tiên en0, en1…).
    static func lanAddresses() -> [String] {
        var out: [(name: String, ip: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var p = list
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let flags = Int32(i.pointee.ifa_flags)
            guard let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            out.append((String(cString: i.pointee.ifa_name), String(cString: host)))
        }
        return out.sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }.map(\.ip)
    }

    /// Các địa chỉ mở được từ iPhone: IP trước (chắc chắn nhất), rồi tên máy .local.
    static func urls(port: Int) -> [String] {
        var hosts = lanAddresses()
        let name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { hosts.append(name) }
        return hosts.map { "http://\($0):\(port)" }
    }

    @MainActor private static func iconPNG() -> Data? {
        let size = NSSize(width: 180, height: 180)
        let img = NSImage(size: size)
        img.lockFocus()
        NSApp.applicationIconImage.draw(in: NSRect(origin: .zero, size: size))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
