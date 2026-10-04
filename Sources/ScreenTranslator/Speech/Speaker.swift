import Foundation
import AVFoundation

final class Speaker: NSObject, AVAudioPlayerDelegate {
    enum Engine: String, Codable, CaseIterable, Identifiable {
        case apple, local, edge
        var id: String { rawValue }
        var label: String {
            switch self {
            case .apple: return "Apple (offline, tức thì)"
            case .local: return "Giọng AI offline (tải về máy, ~0,2 s)"
            case .edge: return "Microsoft Edge neural (đám mây, trễ 3–5 s)"
            }
        }
    }

    private let synth = AVSpeechSynthesizer()
    private let edge = EdgeTTS()
    private var player: AVAudioPlayer?
    private let streamPlayer = MP3StreamPlayer()
    private var edgeTask: Task<Void, Never>?
    private var edgeGeneration = 0          // tăng mỗi câu; mẩu âm thanh của câu cũ bị bỏ
    private var edgeFailures = 0
    private let local = LocalTTS()
    private let pcmPlayer = PCMStreamPlayer()
    private var localGeneration = 0
    var localVoiceID = VoiceCatalog.defaultVoiceID
    var localSpeed: Double = 1.15           // 1 = tốc độ gốc của model
    var edgeRatePercent: Double = 40        // tốc độ nói riêng cho giọng Edge
    var engine: Engine = .apple
    var edgeVoice: String = "vi-VN-NamMinhNeural"
    var onEngineFallback: ((String) -> Void)?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var interrupt = true
    var voiceIdentifier = ""
    var language = "vi"
    var adaptiveRate = true
    /// Khi câu trước chưa đọc xong (đọc lần lượt, không ngắt): câu kế tiếp nhanh thêm chừng này để bắt kịp.
    var catchUpBoost: Double = 0.10
    var silent = false          // --mute: vẫn tổng hợp (để log/test) nhưng volume 0
    /// Phát giọng đọc trên TV / điện thoại: tạo âm thanh của câu rồi gửi qua máy chủ web thay vì phát ra loa máy này.
    var remote = false
    /// (âm thanh, kiểu MIME, ngắt câu đang đọc?, câu) → máy chủ web.
    var onRemoteAudio: ((Data, String, Bool, String) -> Void)?
    private var remoteChain: Task<Void, Never>?
    /// Tăng khi dừng hoặc khi câu mới cắt câu cũ: mọi câu tạo trước mốc đó bị bỏ, kể cả câu đang chờ trong chuỗi.
    /// Chỉ đọc/ghi trên main thread (speak/stop được gọi từ Pipeline).
    private var remoteEpoch = 0

    /// Mã ngôn ngữ đích → BCP-47 của voice hệ thống.
    static func bcp47(_ code: String) -> String {
        switch code {
        case "vi": return "vi-VN"; case "en": return "en-US"; case "ja": return "ja-JP"; case "ko": return "ko-KR"
        case "zh-Hans": return "zh-CN"; case "zh-Hant": return "zh-TW"; case "fr": return "fr-FR"; case "de": return "de-DE"
        case "es": return "es-ES"; case "th": return "th-TH"; case "id": return "id-ID"
        default: return code
        }
    }

    static func voices(for code: String) -> [AVSpeechSynthesisVoice] {
        let want = bcp47(code).lowercased()
        let prefix = want.split(separator: "-").first.map(String.init) ?? want
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { v in
                let l = v.language.lowercased()
                if want.hasPrefix("zh") { return l == want }
                return l.hasPrefix(prefix)
            }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    /// Giọng tốt nhất sẽ dùng khi người dùng để "Mặc định".
    static func bestVoice(for code: String) -> AVSpeechSynthesisVoice? {
        voices(for: code).first ?? AVSpeechSynthesisVoice(language: bcp47(code))
    }

    static func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q { case .premium: return "Premium"; case .enhanced: return "Enhanced"; default: return "Compact" }
    }

    /// Giọng đã chọn cho (ngôn ngữ, voice id) hiện tại; liệt kê giọng hệ thống khá chậm nên không làm lại mỗi câu.
    private var voiceCache: (key: String, voice: AVSpeechSynthesisVoice?)?

    private var voice: AVSpeechSynthesisVoice? {
        let key = "\(language)|\(voiceIdentifier)"
        if let c = voiceCache, c.key == key { return c.voice }
        let v = resolveVoice()
        voiceCache = (key, v)
        return v
    }

    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty {
            if let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier),
               v.language.lowercased().hasPrefix(String(Self.bcp47(language).lowercased().prefix(2))) { return v }
            Log.warn("Voice id '\(voiceIdentifier)' không dùng được cho \(language) → chọn tự động")
        }
        let cands = Self.voices(for: language)
        Log.info("Voice candidates for \(language): \(cands.map { "\($0.name)/\(Self.qualityName($0.quality))" }.joined(separator: ", "))")
        return cands.first ?? AVSpeechSynthesisVoice(language: Self.bcp47(language))
    }

    /// `enqueue` = đọc nối tiếp sau câu đang đọc (không cắt), dùng cho câu thứ 2 trở đi của cùng một lô phụ đề.
    func speak(_ text: String, enqueue: Bool = false) {
        guard !text.isEmpty else { return }
        let savedInterrupt = interrupt
        if enqueue { interrupt = false }
        defer { interrupt = savedInterrupt }
        if remote, onRemoteAudio != nil {
            speakRemote(text)
            return
        }
        if engine == .edge, edgeFailures < 3 {
            speakEdge(text)
            return
        }
        streamPlayer.stop()
        if engine == .local, language == "vi" {
            speakLocal(text)
            return
        }
        speakApple(text)
    }

    /// Giọng AI offline: tổng hợp cả câu trên hàng đợi riêng (~0,1–0,3 s) rồi phát.
    private func speakLocal(_ text: String) {
        let voiceID = localVoiceID, flush = interrupt, silent = silent
        var speed = Float(localSpeed)
        if adaptiveRate {
            let words = text.split(separator: " ").count
            if words > 30 { speed *= 1.3 } else if words > 20 { speed *= 1.2 } else if words > 12 { speed *= 1.1 }
        }
        localGeneration += 1
        let gen = localGeneration
        let t0 = Date()
        if flush { synth.stopSpeaking(at: .immediate) }
        local.queue.async { [weak self] in
            guard let self else { return }
            if flush, gen != self.localGeneration { return }       // đã có câu mới hơn → bỏ
            var speed = speed
            let backlog = !flush && self.pcmPlayer.busyUntil > Date()
            if backlog { speed *= Float(1 + self.catchUpBoost) }  // còn câu đang đọc → nhanh hơn để bắt kịp
            guard self.local.load(voiceID: voiceID), let samples = self.local.synthesize(text, speed: speed) else {
                Log.warn("Giọng AI offline '\(voiceID)' chưa tải hoặc lỗi → Apple")
                DispatchQueue.main.async {
                    self.onEngineFallback?("Chưa tải giọng AI offline, tạm dùng giọng Apple")
                    self.speakApple(text)
                }
                return
            }
            if flush, gen != self.localGeneration { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let dur = Double(samples.count) / self.local.sampleRate
            self.pcmPlayer.volume = silent ? 0 : 1
            self.pcmPlayer.play(samples: samples, sampleRate: self.local.sampleRate, flush: flush)
            Log.info("SPEAK local \(voiceID)\(backlog ? " [bắt kịp]" : "") speed=\(String(format: "%.2f", speed)) tổng hợp=\(ms)ms âm thanh=\(String(format: "%.1f", dur))s: \(text.prefix(40))")
        }
    }

    /// Nạp sẵn model giọng offline để câu đầu không bị trễ.
    func preloadLocal() {
        guard engine == .local else { return }
        let id = localVoiceID
        local.queue.async { [weak self] in _ = self?.local.load(voiceID: id) }
    }

    private func edgeRate(for text: String) -> Int {
        var pct = Int(edgeRatePercent.rounded())
        if !interrupt, edgeTask != nil { pct += Int((catchUpBoost * 100).rounded()) }
        if adaptiveRate {
            let words = text.split(separator: " ").count
            if words > 30 { pct += 30 } else if words > 20 { pct += 20 } else if words > 12 { pct += 10 }
        }
        return max(-40, min(100, pct))
    }

    /// Giữ một kết nối Edge luôn sẵn sàng (gọi định kỳ khi pipeline chạy).
    func keepWarm() {
        if engine == .edge, edgeFailures < 3 { edge.keepWarm() }
    }

    /// Mở sẵn kết nối Edge (gọi khi vừa OCR được câu mới, trong lúc đang dịch).
    func prewarm() {
        if engine == .edge, edgeFailures < 3 { edge.prewarm() }
    }

    private func speakEdge(_ text: String) {
        let voice = edgeVoice, pct = edgeRate(for: text), silent = silent, flush = interrupt
        let prev = edgeTask
        if flush { prev?.cancel() }
        edgeGeneration += 1
        let gen = edgeGeneration
        let t0 = Date()
        edgeTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if !flush { await prev?.value }            // chế độ đọc lần lượt: đợi câu trước nhận xong
            if Task.isCancelled { return }
            await MainActor.run {
                if flush { self.synth.stopSpeaking(at: .immediate); self.player?.stop(); self.player = nil }
                self.streamPlayer.volume = silent ? 0 : 1
                self.streamPlayer.begin(flush: flush)
            }
            var firstMs: Int?
            do {
                let mp3 = try await self.edge.synthesize(text, voice: voice, ratePercent: pct) { chunk in
                    guard gen == self.edgeGeneration || !flush else { return }   // câu đã bị ngắt → bỏ
                    if firstMs == nil { firstMs = Int(Date().timeIntervalSince(t0) * 1000) }
                    self.streamPlayer.feed(chunk)
                }
                self.edgeFailures = 0
                if Task.isCancelled { return }
                if self.streamPlayer.scheduledFrames == 0 {
                    // Lưới an toàn: giải mã streaming không ra âm thanh → phát cả file theo cách cũ.
                    Log.warn("Edge streaming không giải mã được → phát cả file")
                    let p = try AVAudioPlayer(data: mp3)
                    p.volume = silent ? 0 : 1
                    await MainActor.run { self.player = p; p.play() }
                }
                let m = self.edge.lastMarks
                Log.info("SPEAK edge \(voice) rate=+\(pct)% warm=\(m.warm) sent=\(m.sentMs)ms firstAudio=\(m.firstMs)ms (từ lúc gọi: first=\(firstMs ?? -1)ms total=\(Int(Date().timeIntervalSince(t0) * 1000))ms) \(mp3.count / 1024)KB: \(text.prefix(40))")
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                self.edgeFailures += 1
                Log.warn("Edge TTS lỗi (\(self.edgeFailures)/3): \(error.localizedDescription) → Apple")
                if self.edgeFailures >= 3 { self.onEngineFallback?("Edge TTS lỗi liên tiếp, tạm dùng giọng Apple") }
                await MainActor.run { self.speakApple(text) }
            }
        }
    }

    /// Cho phép thử lại Edge sau khi đã lỗi 3 lần (ví dụ khi có mạng lại).
    func resetEdgeFailures() { edgeFailures = 0 }

    private func speakApple(_ text: String) {
        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let backlog = !interrupt && synth.isSpeaking
        let u = AVSpeechUtterance(string: text)
        let v = voice
        if v == nil { Log.warn("No voice for \(language); using system default") }
        u.voice = v
        var r = rate
        if adaptiveRate {
            let words = text.split(separator: " ").count
            if words > 30 { r *= 1.35 } else if words > 20 { r *= 1.25 } else if words > 12 { r *= 1.12 }
        }
        if backlog { r *= Float(1 + catchUpBoost) }
        u.rate = min(r, AVSpeechUtteranceMaximumSpeechRate)
        Log.info("SPEAK voice=\(v?.name ?? "default") [\(v?.identifier ?? "-")] q=\(v.map { Self.qualityName($0.quality) } ?? "-")\(backlog ? " [bắt kịp]" : "") rate=\(String(format: "%.2f", u.rate)): \(text.prefix(60))")
        if silent { u.volume = 0 }
        u.prefersAssistiveTechnologySettings = false
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        edgeTask?.cancel(); edgeTask = nil
        edgeGeneration += 1
        streamPlayer.stop()
        localGeneration += 1
        pcmPlayer.stop()
        player?.stop(); player = nil
        remoteChain?.cancel(); remoteChain = nil
        remoteEpoch += 1
    }

    /// Gọi khi pipeline dừng hẳn: trả lại RAM của model giọng offline (lần chạy sau `preloadLocal` nạp lại)
    /// và bỏ giọng Apple đã nhớ (người dùng có thể vừa tải giọng mới trong System Settings).
    func releaseResources() {
        voiceCache = nil
        local.queue.async { [local] in local.unload() }
    }
}

// MARK: - Phát giọng đọc trên TV / điện thoại

extension Speaker {
    /// Tạo âm thanh của câu bằng đúng engine đang chọn (cùng giọng, cùng tốc độ như khi đọc ra loa) rồi gửi đi.
    /// Các câu được tạo song song nhưng gửi đúng thứ tự; `interrupt` = bảo bên nhận bỏ câu đang đọc.
    fileprivate func speakRemote(_ text: String) {
        let flush = interrupt
        let prev = remoteChain
        if flush { prev?.cancel(); remoteEpoch += 1 }
        let epoch = remoteEpoch
        let useEngine: Engine = (engine == .edge && edgeFailures < 3) ? .edge : (engine == .local && language == "vi" ? .local : .apple)
        // Câu trước còn đang chờ gửi → câu này đọc nhanh hơn chút để bắt kịp (giống khi đọc ra loa).
        let backlog = !flush && prev != nil
        let edgePct = edgeRate(for: text)
        let t0 = Date()
        remoteChain = Task { [weak self] in
            guard let self else { return }
            let audio = await self.renderAudio(text, engine: useEngine, backlog: backlog, edgePercent: edgePct)
            if !flush { await prev?.value }
            guard !Task.isCancelled else { return }
            guard let (data, mime) = audio else {
                Log.warn("Không tạo được âm thanh để gửi lên TV: \(text.prefix(40))")
                return
            }
            // Đã Dừng hoặc có câu mới cắt ngang trong lúc tạo âm thanh → bỏ câu này.
            let sent = await MainActor.run { () -> Bool in
                guard epoch == self.remoteEpoch else { return false }
                self.onRemoteAudio?(data, mime, flush, text)
                return true
            }
            guard sent else { return }
            Log.info("SPEAK→TV \(useEngine.rawValue) \(data.count / 1024)KB \(Int(Date().timeIntervalSince(t0) * 1000))ms: \(text.prefix(40))")
        }
    }

    private func renderAudio(_ text: String, engine: Engine, backlog: Bool, edgePercent: Int) async -> (Data, String)? {
        switch engine {
        case .edge:
            do {
                let mp3 = try await edge.synthesize(text, voice: edgeVoice, ratePercent: edgePercent)
                return (mp3, "audio/mpeg")
            } catch {
                Log.warn("Edge TTS (gửi TV) lỗi: \(error.localizedDescription) → giọng Apple")
                return await renderApple(text, backlog: backlog)
            }
        case .local:
            var speed = Float(localSpeed)
            if adaptiveRate {
                let words = text.split(separator: " ").count
                if words > 30 { speed *= 1.3 } else if words > 20 { speed *= 1.2 } else if words > 12 { speed *= 1.1 }
            }
            if backlog { speed *= Float(1 + catchUpBoost) }
            let voiceID = localVoiceID, sp = speed
            let result: ([Float], Double)? = await withCheckedContinuation { cont in
                local.queue.async { [local] in
                    guard local.load(voiceID: voiceID), let s = local.synthesize(text, speed: sp) else { cont.resume(returning: nil); return }
                    cont.resume(returning: (s, local.sampleRate))
                }
            }
            if let (samples, rate) = result { return (Self.wav(samples, sampleRate: Int(rate)), "audio/wav") }
            return await renderApple(text, backlog: backlog)
        case .apple:
            return await renderApple(text, backlog: backlog)
        }
    }

    /// Giọng Apple: AVSpeechSynthesizer.write ghi âm thanh vào bộ nhớ (không phát ra loa), cùng giọng và tốc độ như speakApple.
    private func renderApple(_ text: String, backlog: Bool) async -> (Data, String)? {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        var r = rate
        if adaptiveRate {
            let words = text.split(separator: " ").count
            if words > 30 { r *= 1.35 } else if words > 20 { r *= 1.25 } else if words > 12 { r *= 1.12 }
        }
        if backlog { r *= Float(1 + catchUpBoost) }
        u.rate = min(r, AVSpeechUtteranceMaximumSpeechRate)
        u.prefersAssistiveTechnologySettings = false
        // Mỗi câu một bộ tổng hợp riêng: các câu được tạo song song, dùng chung một bộ thì câu sau có thể cắt câu trước.
        // Bộ tổng hợp được giữ sống tới khi xong (closure tham chiếu nó). Không có buffer kết thúc sau 15 s → bỏ, để
        // chuỗi gửi lên TV không bị kẹt mãi ở câu này.
        let writer = AVSpeechSynthesizer()
        let result: ([Float], Double)? = await withCheckedContinuation { cont in
            var samples: [Float] = []
            var sampleRate = 22_050.0
            var done = false
            let lock = NSLock()
            func finish(_ r: ([Float], Double)?) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: r)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { _ = writer; finish(nil) }
            writer.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    // Buffer rỗng = đã tổng hợp xong câu.
                    lock.lock(); let s = samples, sr = sampleRate; lock.unlock()
                    finish(s.isEmpty ? nil : (s, sr))
                    return
                }
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                sampleRate = pcm.format.sampleRate
                let n = Int(pcm.frameLength)
                if let f = pcm.floatChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
                } else if let i = pcm.int16ChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32768 })
                } else if let i = pcm.int32ChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 2_147_483_648 })
                }
            }
        }
        guard let (samples, rate) = result else { return nil }
        return (Self.wav(samples, sampleRate: Int(rate)), "audio/wav")
    }

    /// WAV PCM 16-bit mono.
    static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataSize = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
