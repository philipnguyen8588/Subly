import Foundation
import CoreVideo
import CChiakiBridge

/// Phiên Remote Play nhúng trong app (qua libchiaki): chỉ nhận hình để hiển thị và OCR. Không gửi điều khiển, không âm thanh.
final class PS5Stream: ObservableObject, @unchecked Sendable {
    static let shared = PS5Stream()

    enum State: Equatable {
        case idle
        case searching(String)
        case connecting
        case streaming
        case needsPin(Bool)        // true = PIN vừa nhập sai
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Chưa kết nối"
            case .searching(let s): return s
            case .connecting: return "Đang kết nối…"
            case .streaming: return "Đang nhận hình"
            case .needsPin(let wrong): return wrong ? "Mã PIN đăng nhập sai, nhập lại" : "PS5 yêu cầu mã PIN đăng nhập"
            case .failed(let s): return s
            }
        }
        var isBusy: Bool {
            switch self { case .searching, .connecting, .streaming, .needsPin: return true; default: return false }
        }
    }

    struct Found: Identifiable, Equatable {
        let addr: String, name: String, hostID: String, ps5: Bool, state: Int
        var id: String { hostID.isEmpty ? addr : hostID }
        var stateLabel: String { state == 1 ? "đang bật" : state == 2 ? "chế độ nghỉ" : "không rõ" }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var host: PS5Host? = PS5Store.load()
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var fps: Int = 0
    @Published private(set) var registering = false
    @Published var registMessage = ""

    private var session: OpaquePointer?
    private var regist: OpaquePointer?
    private let decoder = H264Decoder()
    private let work = DispatchQueue(label: "ps5.stream")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private(set) var frameIndex = 0
    private var displaySinks: [UUID: (CVPixelBuffer) -> Void] = [:]
    private var framesThisSecond = 0
    private var fpsTimer: Timer?
    private var generation = 0
    private var needKeyframe = false

    private init() {
        decoder.onFrame = { [weak self] pb in self?.deliver(pb) }
    }

    // MARK: khung hình

    private func deliver(_ pb: CVPixelBuffer) {
        lock.lock()
        latest = pb
        frameIndex += 1
        framesThisSecond += 1
        let sinks = Array(displaySinks.values)
        lock.unlock()
        for s in sinks { s(pb) }
        let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        if size != videoSize { DispatchQueue.main.async { self.videoSize = size } }
    }

    /// Khung mới nhất và số thứ tự của nó (để biết đã có khung mới chưa).
    func latestFrame() -> (CVPixelBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        return latest.map { ($0, frameIndex) }
    }

    func addDisplaySink(_ f: @escaping (CVPixelBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); displaySinks[id] = f; let cur = latest; lock.unlock()
        if let cur { f(cur) }
        return id
    }
    func removeDisplaySink(_ id: UUID) { lock.lock(); displaySinks[id] = nil; lock.unlock() }

    var isStreaming: Bool { state == .streaming }

    // MARK: máy đã đăng ký

    func setHost(_ h: PS5Host?) {
        PS5Store.save(h)
        DispatchQueue.main.async { self.host = h }
    }

    func importFromChiaki() -> Bool {
        guard var h = PS5Store.importFromChiaki() else { return false }
        h.host = host?.host ?? ""
        PS5Store.save(h)
        host = h
        Log.info("PS5: nhập máy '\(h.nickname)' từ chiaki-ng")
        return true
    }

    // MARK: tìm máy / đánh thức

    /// Địa chỉ broadcast của các card mạng IPv4 đang hoạt động.
    static func broadcastAddresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return ["255.255.255.255"] }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let ifa = p {
            let f = Int32(ifa.pointee.ifa_flags)
            if f & IFF_UP != 0, f & IFF_BROADCAST != 0, f & IFF_LOOPBACK == 0,
               let dst = ifa.pointee.ifa_dstaddr, dst.pointee.sa_family == UInt8(AF_INET) {
                var addr = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let s = String(cString: buf)
                    if !out.contains(s) { out.append(s) }
                }
            }
            p = ifa.pointee.ifa_next
        }
        return out.isEmpty ? ["255.255.255.255"] : out
    }

    /// Tìm IP ứng với địa chỉ MAC trong bảng ARP của hệ điều hành.
    static func arpLookup(mac: Data) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let want = mac.map { Int($0) }
        for line in out.split(separator: "\n") {
            // "? (192.168.1.20) at 0:11:22:33:44:55 on en0 ..."
            let parts = line.split(separator: " ")
            guard parts.count >= 4, parts[2] == "at" else { continue }
            let bytes = parts[3].split(separator: ":").compactMap { Int($0, radix: 16) }
            if bytes == want { return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
        }
        return nil
    }

    /// Chặn ~`ms` mili giây cho mỗi địa chỉ. Gọi ngoài main thread.
    static func discover(_ targets: [String], ms: Int32 = 1200) -> [Found] {
        final class Box { var items: [Found] = [] }
        let box = Box()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        for t in targets {
            _ = st_discover(t, ms, { addr, name, hid, ps5, state, user in
                let b = Unmanaged<Box>.fromOpaque(user!).takeUnretainedValue()
                let f = Found(addr: String(cString: addr!), name: String(cString: name!), hostID: String(cString: hid!),
                              ps5: ps5 != 0, state: Int(state))
                if !b.items.contains(where: { $0.id == f.id }) { b.items.append(f) }
            }, ctx)
        }
        return box.items
    }

    private func setState(_ s: State) {
        DispatchQueue.main.async {
            if self.state != s { Log.info("PS5: \(s.label)") }
            self.state = s
        }
    }

    // MARK: kết nối

    func connect(resolution: Int, fps: Int) {
        guard let h0 = host, session == nil, !state.isBusy else { return }
        generation += 1
        let gen = generation
        setState(.searching("Đang tìm \(h0.nickname)…"))
        work.async { [self] in
            var h = h0
            // 1. Tìm máy: thử IP đã lưu, không thấy thì hỏi cả mạng và khớp theo địa chỉ MAC.
            var found = h.host.isEmpty ? nil : Self.discover([h.host], ms: 900).first
            if found == nil {
                found = Self.discover(Self.broadcastAddresses()).first { $0.hostID.uppercased() == h.hostID } 
            }
            guard gen == generation else { return }
            // PS5 đang nghỉ có thể không trả lời tìm kiếm: lấy IP từ bảng ARP của máy theo địa chỉ MAC để còn đánh thức.
            if found == nil, h.host.isEmpty, let ip = Self.arpLookup(mac: h.mac) {
                h.host = ip
                setHost(h)
                Log.info("PS5: địa chỉ \(ip) (từ bảng ARP)")
            }
            if let f = found, f.addr != h.host, !f.addr.isEmpty {
                h.host = f.addr
                setHost(h)
                Log.info("PS5: địa chỉ \(f.addr)")
            }
            guard !h.host.isEmpty else {
                setState(.failed("Không tìm thấy \(h.nickname) trong mạng. Bật PS5 (hoặc để chế độ nghỉ có bật mạng) rồi thử lại."))
                return
            }
            // 2. Đang nghỉ (hoặc không trả lời) → gửi gói đánh thức và đợi máy sẵn sàng.
            if found?.state != 1 {
                setState(.searching(found == nil ? "Không thấy PS5 trả lời, thử đánh thức…" : "Đang đánh thức PS5…"))
                var ready = false
                for i in 0..<30 {
                    guard gen == generation else { return }
                    if i % 5 == 0 { h.registKey.withUnsafeBytes { _ = st_wakeup(h.host, $0.bindMemory(to: UInt8.self).baseAddress, h.ps5 ? 1 : 0) } }
                    if let f = Self.discover([h.host], ms: 900).first, f.state == 1 { ready = true; break }
                    Thread.sleep(forTimeInterval: 1)
                }
                guard ready else {
                    setState(.failed("PS5 không trả lời. Máy đang tắt hẳn, hoặc chế độ nghỉ chưa bật “Stay Connected to the Internet” và “Enable Turning On PS5 from Network”."))
                    return
                }
                Thread.sleep(forTimeInterval: 3)   // vừa thức dậy: đợi dịch vụ Remote Play lên
            }
            guard gen == generation else { return }
            // 3. Mở phiên.
            setState(.connecting)
            decoder.invalidate()
            needKeyframe = false
            let me = Unmanaged.passUnretained(self).toOpaque()
            let s: OpaquePointer? = h.registKey.withUnsafeBytes { rk in
                h.rpKey.withUnsafeBytes { mk in
                    h.accountID.withUnsafeBytes { acc in
                        st_session_start(h.host, h.ps5 ? 1 : 0, rk.bindMemory(to: UInt8.self).baseAddress,
                                         mk.bindMemory(to: UInt8.self).baseAddress, acc.bindMemory(to: UInt8.self).baseAddress,
                                         Int32(resolution), Int32(fps), 0,
                                         { buf, size, user in
                                             let me = Unmanaged<PS5Stream>.fromOpaque(user!).takeUnretainedValue()
                                             me.handleVideo(buf!, size)
                                         },
                                         { type, msg, user in
                                             let me = Unmanaged<PS5Stream>.fromOpaque(user!).takeUnretainedValue()
                                             me.handleEvent(type, msg.map { String(cString: $0) } ?? "")
                                         }, me)
                    }
                }
            }
            guard let s else { setState(.failed("Không mở được phiên Remote Play")); return }
            session = s
            DispatchQueue.main.async { self.startFPSTimer() }
        }
    }

    private func handleVideo(_ buf: UnsafePointer<UInt8>, _ size: Int) {
        let ok = decoder.decode(buf, count: size)
        if !ok, !needKeyframe {
            needKeyframe = true
            if let s = session { st_session_request_idr(s) }
        } else if ok { needKeyframe = false }
    }

    private func handleEvent(_ type: Int32, _ msg: String) {
        switch type {
        case 0:   // ST_EVENT_LOG
            if msg.contains("rror") || msg.contains("ailed") { Log.warn("chiaki: \(msg)") }
        case 1:   // ST_EVENT_CONNECTED
            setState(.streaming)
        case 3:   // ST_EVENT_PIN_REQUEST
            setState(.needsPin(msg == "incorrect"))
        case 2:   // ST_EVENT_QUIT
            let parts = msg.split(separator: "|", maxSplits: 1).map(String.init)
            let code = Int(parts.first ?? "") ?? -1
            let text = parts.count > 1 ? parts[1] : msg
            Log.info("PS5: phiên kết thúc (\(msg))")
            // Không được join luồng phiên ngay trong callback của nó → dọn ở hàng đợi khác.
            work.async { [self] in
                teardown()
                switch code {
                case 1: setState(.idle)
                case 4: setState(.failed("PS5 đang có một phiên Remote Play khác. Thoát chiaki-ng / PS Remote Play rồi thử lại."))
                case 12: setState(.failed("PS5 đã tắt hoặc vào chế độ nghỉ."))
                default: setState(.failed("Mất kết nối: \(text)"))
                }
            }
        default: break
        }
    }

    func sendPin(_ pin: String) {
        guard let s = session else { return }
        st_session_set_pin(s, pin)
        setState(.connecting)
    }

    func disconnect() {
        generation += 1
        work.async { [self] in
            teardown()
            setState(.idle)
        }
    }

    /// Gọi trên `work`.
    private func teardown() {
        if let s = session {
            session = nil
            st_session_stop(s)
        }
        decoder.invalidate()
        lock.lock(); latest = nil; lock.unlock()
        DispatchQueue.main.async { self.fpsTimer?.invalidate(); self.fpsTimer = nil; self.fps = 0 }
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let n = self.framesThisSecond; self.framesThisSecond = 0; self.lock.unlock()
            if self.fps != n { self.fps = n }
        }
    }

    // MARK: đăng ký máy

    /// `pin`: 8 chữ số hiện ở Settings → System → Remote Play → Link Device trên PS5.
    func register(hostAddr: String, accountID: Data, pin: UInt32, ps5: Bool = true) {
        guard regist == nil else { return }
        registering = true
        registMessage = "Đang đăng ký với \(hostAddr)…"
        final class Ctx { var addr = ""; var account = Data(); var ps5 = true }
        let ctx = Ctx(); ctx.addr = hostAddr; ctx.account = accountID; ctx.ps5 = ps5
        registCtx = ctx
        let me = Unmanaged.passUnretained(self).toOpaque()
        pendingRegist = (hostAddr, accountID, ps5)
        regist = accountID.withUnsafeBytes { acc in
            st_regist_start(hostAddr, ps5 ? 1 : 0, acc.bindMemory(to: UInt8.self).baseAddress, pin,
                            { ok, nick, mac, rk, key, user in
                                let me = Unmanaged<PS5Stream>.fromOpaque(user!).takeUnretainedValue()
                                var result: (String, Data, Data, Data)?
                                if ok != 0, let nick, let mac, let rk, let key {
                                    result = (String(cString: nick), Data(bytes: mac, count: 6), Data(bytes: rk, count: 16), Data(bytes: key, count: 16))
                                }
                                me.registFinished(result)
                            },
                            { _, msg, _ in if let msg { Log.info("chiaki regist: \(String(cString: msg))") } }, me)
        }
        if regist == nil {
            registering = false
            registMessage = "Không bắt đầu được việc đăng ký"
        }
    }

    private var registCtx: AnyObject?
    private var pendingRegist: (String, Data, Bool)?

    private func registFinished(_ r: (String, Data, Data, Data)?) {
        let pending = pendingRegist
        // Callback chạy trên luồng của regist → dọn ở hàng đợi khác.
        work.async { [self] in
            if let rg = regist { regist = nil; st_regist_finish(rg) }
            DispatchQueue.main.async {
                self.registering = false
                if let r, let p = pending {
                    let h = PS5Host(host: p.0, nickname: r.0, mac: r.1, registKey: r.2, rpKey: r.3, accountID: p.1, ps5: p.2)
                    PS5Store.save(h)
                    self.host = h
                    self.registMessage = "Đã đăng ký \(r.0)"
                    Log.info("PS5: đăng ký thành công '\(r.0)'")
                } else {
                    self.registMessage = "Đăng ký thất bại. Kiểm tra mã PIN (8 số, còn hạn), PSN Account ID và địa chỉ IP."
                }
            }
        }
    }
}
