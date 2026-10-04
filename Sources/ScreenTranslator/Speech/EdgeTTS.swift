import Foundation
import CryptoKit

/// Microsoft Edge "Read Aloud" neural TTS (endpoint không chính thức, miễn phí). Trả về MP3.
final class EdgeTTS {
    struct Voice: Identifiable, Equatable {
        let id: String       // ví dụ vi-VN-NamMinhNeural
        let name: String
        let lang: String     // mã ngôn ngữ đích của app (vi, en, ...)
    }

    static let voices: [Voice] = [
        .init(id: "vi-VN-NamMinhNeural", name: "Nam Minh (nam)", lang: "vi"),
        .init(id: "vi-VN-HoaiMyNeural", name: "Hoài My (nữ)", lang: "vi"),
        .init(id: "en-US-GuyNeural", name: "Guy (male)", lang: "en"),
        .init(id: "en-US-AndrewNeural", name: "Andrew (male)", lang: "en"),
        .init(id: "en-US-JennyNeural", name: "Jenny (female)", lang: "en"),
        .init(id: "en-US-AriaNeural", name: "Aria (female)", lang: "en"),
        .init(id: "ja-JP-KeitaNeural", name: "Keita (男)", lang: "ja"),
        .init(id: "ja-JP-NanamiNeural", name: "Nanami (女)", lang: "ja"),
        .init(id: "ko-KR-InJoonNeural", name: "InJoon (남)", lang: "ko"),
        .init(id: "ko-KR-SunHiNeural", name: "SunHi (여)", lang: "ko"),
        .init(id: "zh-CN-YunxiNeural", name: "云希 (男)", lang: "zh-Hans"),
        .init(id: "zh-CN-XiaoxiaoNeural", name: "晓晓 (女)", lang: "zh-Hans"),
        .init(id: "zh-TW-YunJheNeural", name: "雲哲 (男)", lang: "zh-Hant"),
        .init(id: "zh-TW-HsiaoChenNeural", name: "曉臻 (女)", lang: "zh-Hant"),
        .init(id: "fr-FR-HenriNeural", name: "Henri (homme)", lang: "fr"),
        .init(id: "fr-FR-DeniseNeural", name: "Denise (femme)", lang: "fr"),
        .init(id: "de-DE-ConradNeural", name: "Conrad (Mann)", lang: "de"),
        .init(id: "de-DE-KatjaNeural", name: "Katja (Frau)", lang: "de"),
        .init(id: "es-ES-AlvaroNeural", name: "Álvaro (hombre)", lang: "es"),
        .init(id: "es-ES-ElviraNeural", name: "Elvira (mujer)", lang: "es"),
        .init(id: "th-TH-NiwatNeural", name: "Niwat (ชาย)", lang: "th"),
        .init(id: "th-TH-PremwadeeNeural", name: "Premwadee (หญิง)", lang: "th"),
        .init(id: "id-ID-ArdiNeural", name: "Ardi (pria)", lang: "id"),
        .init(id: "id-ID-GadisNeural", name: "Gadis (wanita)", lang: "id"),
    ]

    static func voices(for lang: String) -> [Voice] { voices.filter { $0.lang == lang } }
    static func defaultVoice(for lang: String) -> String { voices(for: lang).first?.id ?? "en-US-GuyNeural" }

    enum EdgeError: LocalizedError {
        case noAudio, badStatus(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: return "Edge TTS không trả âm thanh"
            case .badStatus(let s): return "Edge TTS: \(s)"
            }
        }
    }

    /// Gọi với tên mốc ("sent", "first-audio", "end") để đo độ trễ.
    var onEvent: ((String) -> Void)?

    private static let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromeVersion = "143.0.3650.75"
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.networkServiceType = .responsiveData      // dữ liệu tương tác, không phải nền
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    /// Mốc thời gian (ms) của lần tổng hợp gần nhất, để ghi log: đã dùng kết nối ấm?, gửi xong, gói âm thanh đầu.
    private(set) var lastMarks: (warm: Bool, sentMs: Int, firstMs: Int) = (false, -1, -1)

    /// Sec-MS-GEC: SHA256(ticks làm tròn 5 phút + token), theo cách Edge làm.
    private static func gecToken() -> String {
        var ticks = UInt64((Date().timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
        ticks -= ticks % 3_000_000_000
        let s = "\(ticks)\(token)"
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private static func timestamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: kết nối giữ sẵn ("ấm")

    private var t0 = Date()
    private var warm: (task: URLSessionWebSocketTask, at: Date)?
    private let warmLock = NSLock()
    private let warmMaxAge: TimeInterval = 50

    private func makeSocket() -> URLSessionWebSocketTask {
        var comps = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        comps.queryItems = [
            .init(name: "TrustedClientToken", value: Self.token),
            .init(name: "Sec-MS-GEC", value: Self.gecToken()),
            .init(name: "Sec-MS-GEC-Version", value: "1-\(Self.chromeVersion)"),
            .init(name: "ConnectionId", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        let major = Self.chromeVersion.split(separator: ".").first ?? "143"
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("MUID=\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", forHTTPHeaderField: "Cookie")
        let ws = session.webSocketTask(with: req)
        ws.priority = URLSessionTask.highPriority
        ws.resume()
        return ws
    }

    /// Gọi định kỳ khi đang chạy: ping kết nối ấm, nếu chết hoặc quá cũ thì mở cái mới. Luôn có sẵn một kết nối đã bắt tay xong.
    func keepWarm() {
        warmLock.lock()
        let w = warm
        warmLock.unlock()
        guard let w, w.task.state == .running, Date().timeIntervalSince(w.at) < 45 else {
            replaceWarm()
            return
        }
        w.task.sendPing { [weak self] err in
            if err != nil { self?.replaceWarm() }
        }
    }

    private func replaceWarm() {
        warmLock.lock(); defer { warmLock.unlock() }
        warm?.task.cancel(with: .goingAway, reason: nil)
        warm = (makeSocket(), Date())
    }

    /// Mở sẵn một kết nối để câu kế tiếp không mất thời gian bắt tay TLS/WebSocket.
    func prewarm() {
        warmLock.lock(); defer { warmLock.unlock() }
        if let w = warm, Date().timeIntervalSince(w.at) < warmMaxAge, w.task.state == .running { return }
        warm?.task.cancel(with: .goingAway, reason: nil)
        warm = (makeSocket(), Date())
    }

    private func takeSocket() -> (URLSessionWebSocketTask, Bool) {
        warmLock.lock(); defer { warmLock.unlock() }
        if let w = warm, Date().timeIntervalSince(w.at) < warmMaxAge, w.task.state == .running {
            warm = nil
            return (w.task, true)
        }
        warm?.task.cancel(with: .goingAway, reason: nil)
        warm = nil
        return (makeSocket(), false)
    }

    /// `ratePercent`: -50…+100 (0 = bình thường). `onAudio` được gọi với từng mẩu MP3 ngay khi tới (streaming).
    func synthesize(_ text: String, voice: String, ratePercent: Int, onAudio: ((Data) -> Void)? = nil) async throws -> Data {
        let (ws, wasWarm) = takeSocket()
        t0 = Date()
        lastMarks = (wasWarm, -1, -1)
        do {
            return try await run(ws, text: text, voice: voice, ratePercent: ratePercent, onAudio: onAudio)
        } catch {
            ws.cancel(with: .normalClosure, reason: nil)
            // Kết nối giữ sẵn có thể đã bị server đóng → thử lại một lần với kết nối mới.
            guard wasWarm, !(error is CancellationError) else { throw error }
            lastMarks = (false, -1, -1)
            let fresh = makeSocket()
            defer { fresh.cancel(with: .normalClosure, reason: nil) }
            return try await run(fresh, text: text, voice: voice, ratePercent: ratePercent, onAudio: onAudio)
        }
    }

    private func run(_ ws: URLSessionWebSocketTask, text: String, voice: String, ratePercent: Int,
                     onAudio: ((Data) -> Void)?) async throws -> Data {
        let cfg = "X-Timestamp:\(Self.timestamp())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" +
            #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
        try await ws.send(.string(cfg))

        let rate = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='https://www.w3.org/2001/mstts' xml:lang='en-US'><voice name='\(voice)'><prosody pitch='+0Hz' rate='\(rate)' volume='+0%'>\(Self.escape(text))</prosody></voice></speak>"
        let reqID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let msg = "X-RequestId:\(reqID)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(Self.timestamp())Z\r\nPath:ssml\r\n\r\n\(ssml)"
        try await ws.send(.string(msg))
        lastMarks.sentMs = Int(Date().timeIntervalSince(t0) * 1000)
        replaceWarm()  // chuẩn bị luôn kết nối cho câu sau

        var audio = Data()
        while true {
            let m = try await ws.receive()
            switch m {
            case .string(let s):
                if s.contains("Path:turn.end") {
                    ws.cancel(with: .normalClosure, reason: nil)
                    if audio.isEmpty { throw EdgeError.noAudio }
                    return audio
                }
            case .data(let d):
                // 2 byte big-endian độ dài header, rồi header text, rồi audio
                guard d.count > 2 else { continue }
                let hlen = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
                guard d.count > 2 + hlen else { continue }
                let header = String(data: d.subdata(in: (d.startIndex + 2)..<(d.startIndex + 2 + hlen)), encoding: .utf8) ?? ""
                if header.contains("Path:audio") {
                    let chunk = d.subdata(in: (d.startIndex + 2 + hlen)..<d.endIndex)
                    if audio.isEmpty { lastMarks.firstMs = Int(Date().timeIntervalSince(t0) * 1000) }
                    audio.append(chunk)
                    onAudio?(chunk)
                }
            @unknown default: break
            }
        }
    }
}
