import Foundation

/// Nói chuyện thẳng với sdbd trên TV Samsung (cổng 26101) — thay cho sdb của Tizen Studio (bản macOS chỉ có x86_64,
/// không chạy trên Apple Silicon khi không có Rosetta). Giao thức là bản tách từ adb: gói 24 byte (lệnh, arg0, arg1,
/// độ dài, tổng byte, lệnh ^ 0xFFFFFFFF) + dữ liệu; mỗi luồng mở bằng OPEN "<dịch vụ>", trả lời từng WRTE bằng OKAY.
/// Chỉ cần: `shell:<lệnh>` (getduid, vd_appinstall…) và `sync:` (đẩy file .wgt lên TV).
/// Gọi đồng bộ trên luồng nền; `close()` từ luồng khác làm lệnh đang chờ báo lỗi ngay (dùng để huỷ).
final class SdbClient {
    enum Cmd: UInt32 {
        case cnxn = 0x4e584e43, open = 0x4e45504f, okay = 0x59414b4f, clse = 0x45534c43, wrte = 0x45545257
    }
    struct SdbError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let fd: Int32
    private var maxData = 4096
    private var nextId: UInt32 = 1
    /// Banner của TV khi bắt tay ("device::…").
    private(set) var banner = ""

    /// Mở TCP tới TV và bắt tay CNXN. TV chỉ nhận máy có IP trùng ô "Host PC IP" trong Developer Mode.
    init(host: String, port: UInt16 = 26101, timeout: TimeInterval = 8) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw SdbError(message: "IP không hợp lệ: \(host)") }
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SdbError(message: "Không tạo được socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        // connect có hạn giờ: non-blocking + poll.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 {
            guard errno == EINPROGRESS else { Darwin.close(fd); throw SdbError(message: "Không kết nối được \(host): \(String(cString: strerror(errno)))") }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if n <= 0 || err != 0 {
                Darwin.close(fd)
                throw SdbError(message: n <= 0 ? "Hết thời gian kết nối \(host):\(port)" : "Không kết nối được \(host): \(String(cString: strerror(err)))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeout(timeout)

        try send(.cnxn, 0x0200_0000, UInt32(256 * 1024), Data("host::\0".utf8))
        while true {
            let m = try read()
            if m.cmd == Cmd.cnxn.rawValue {
                maxData = max(1024, min(Int(m.arg1), 256 * 1024))
                banner = String(decoding: m.data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                break
            }
        }
    }

    deinit { close() }

    private var closed = false
    private let lock = NSLock()
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    func setTimeout(_ t: TimeInterval) {
        var tv = timeval(tv_sec: Int(t), tv_usec: Int32((t - Double(Int(t))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: Dịch vụ

    /// Chạy lệnh shell trên TV (vd. "0 getduid"), trả về toàn bộ đầu ra. `timeout`: tối đa chờ mỗi gói (cài app lâu).
    func shell(_ command: String, timeout: TimeInterval = 180) throws -> String {
        setTimeout(timeout)
        let (local, remote) = try openStream("shell:" + command)
        var out = Data()
        while true {
            let m = try readStream(local)
            if m.cmd == Cmd.wrte.rawValue {
                out.append(m.data)
                try send(.okay, local, remote)
            } else if m.cmd == Cmd.clse.rawValue {
                try? send(.clse, local, remote)
                break
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Đẩy `data` thành file `remotePath` trên TV (dịch vụ sync: SEND / DATA / DONE).
    func push(_ data: Data, to remotePath: String, mode: Int = 0o644) throws {
        setTimeout(60)
        let (local, remote) = try openStream("sync:")
        func packet(_ id: String, _ n: UInt32, _ body: Data = Data()) -> Data {
            var d = Data(id.utf8); d.append(le(n)); d.append(body); return d
        }
        let spec = Data("\(remotePath),\(mode)".utf8)
        var stream = packet("SEND", UInt32(spec.count), spec)
        var off = 0
        repeat {
            let chunk = data[data.startIndex + off ..< data.startIndex + min(data.count, off + 64 * 1024)]
            stream.append(packet("DATA", UInt32(chunk.count), Data(chunk)))
            off += chunk.count
        } while off < data.count
        stream.append(packet("DONE", UInt32(Date().timeIntervalSince1970)))
        try write(stream, local, remote)

        // Trả lời: OKAY + 4 byte, hoặc FAIL + độ dài + lý do.
        var reply = Data()
        while reply.count < 8 {
            let m = try readStream(local)
            if m.cmd == Cmd.wrte.rawValue { reply.append(m.data); try send(.okay, local, remote) }
            else if m.cmd == Cmd.clse.rawValue { throw SdbError(message: "TV đóng kết nối khi đang nhận file") }
        }
        let id = String(decoding: reply.prefix(4), as: UTF8.self)
        if id != "OKAY" {
            let n = Int(u32(reply, 4))
            while reply.count < 8 + n, let m = try? readStream(local), m.cmd == Cmd.wrte.rawValue { reply.append(m.data); try? send(.okay, local, remote) }
            throw SdbError(message: "TV từ chối nhận file: " + String(decoding: reply.dropFirst(8), as: UTF8.self))
        }
        try? write(packet("QUIT", 0), local, remote)
        try? send(.clse, local, remote)
    }

    // MARK: Luồng

    private func openStream(_ service: String) throws -> (UInt32, UInt32) {
        let local = nextId; nextId += 1
        try send(.open, local, 0, Data((service + "\0").utf8))
        while true {
            let m = try read()
            guard m.arg1 == local else { continue }
            if m.cmd == Cmd.okay.rawValue { return (local, m.arg0) }
            if m.cmd == Cmd.clse.rawValue { throw SdbError(message: "TV từ chối lệnh '\(service)'") }
        }
    }

    /// Gói kế tiếp của luồng `local` (bỏ qua gói của luồng khác).
    private func readStream(_ local: UInt32) throws -> (cmd: UInt32, arg0: UInt32, arg1: UInt32, data: Data) {
        while true {
            let m = try read()
            if m.arg1 == local { return m }
        }
    }

    /// Gửi dữ liệu theo từng WRTE ≤ maxData, mỗi gói chờ TV OKAY rồi mới gửi tiếp.
    private func write(_ data: Data, _ local: UInt32, _ remote: UInt32) throws {
        var off = 0
        while off < data.count {
            let n = min(maxData, data.count - off)
            try send(.wrte, local, remote, data.subdata(in: data.startIndex + off ..< data.startIndex + off + n))
            off += n
            while true {
                let m = try readStream(local)
                if m.cmd == Cmd.okay.rawValue { break }
                if m.cmd == Cmd.clse.rawValue { throw SdbError(message: "TV đóng kết nối") }
                if m.cmd == Cmd.wrte.rawValue { throw SdbError(message: "TV báo lỗi: " + String(decoding: m.data.dropFirst(8), as: UTF8.self)) }
            }
        }
    }

    // MARK: Gói tin

    private func send(_ cmd: Cmd, _ arg0: UInt32, _ arg1: UInt32, _ data: Data = Data()) throws {
        var h = Data()
        let check = data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for v in [cmd.rawValue, arg0, arg1, UInt32(data.count), check, cmd.rawValue ^ 0xFFFF_FFFF] { h.append(le(v)) }
        try writeAll(h + data)
    }

    private func read() throws -> (cmd: UInt32, arg0: UInt32, arg1: UInt32, data: Data) {
        let h = try readExactly(24)
        let cmd = u32(h, 0), len = Int(u32(h, 12))
        guard u32(h, 20) == cmd ^ 0xFFFF_FFFF, len <= 1 << 20 else { throw SdbError(message: "TV gửi gói sdb không hợp lệ") }
        return (cmd, u32(h, 4), u32(h, 8), len > 0 ? try readExactly(len) : Data())
    }

    private func writeAll(_ d: Data) throws {
        try d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { throw SdbError(message: "Mất kết nối TV (gửi): \(String(cString: strerror(errno)))") }
                off += n
            }
        }
    }

    private func readExactly(_ n: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + off, n - off) }
            if r == 0 { throw SdbError(message: "TV đóng kết nối") }
            if r < 0 {
                throw SdbError(message: errno == EAGAIN ? "TV không trả lời (hết thời gian chờ)" : "Mất kết nối TV: \(String(cString: strerror(errno)))")
            }
            off += r
        }
        return Data(buf)
    }

    private func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}
