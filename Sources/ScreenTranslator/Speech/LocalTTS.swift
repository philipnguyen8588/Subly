import Foundation
import CSherpaOnnx

/// Giọng AI chạy ngay trên máy: sherpa-onnx + model Piper/VITS tiếng Việt (~60 MB/giọng).
/// Đo trên M4: tạo 6,5 s âm thanh mất ~0,3 s (nhanh hơn thời gian thực ~20 lần).
final class LocalTTS {
    private var tts: OpaquePointer?
    private var loadedVoice = ""
    private(set) var sampleRate: Double = 22_050
    let queue = DispatchQueue(label: "local.tts", qos: .userInitiated)

    /// Gọi trên `queue`. Nạp model nếu chưa nạp / đổi giọng. Trả về false nếu thiếu file.
    func load(voiceID: String) -> Bool {
        if tts != nil, loadedVoice == voiceID { return true }
        unload()
        guard VoiceCatalog.isInstalled(voiceID) else { return false }
        let t0 = Date()
        let model = VoiceCatalog.modelURL(voiceID).path
        let tokens = VoiceCatalog.tokensURL.path
        let data = VoiceCatalog.espeakURL.path
        var config = SherpaOnnxOfflineTtsConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineTtsConfig>.size)
        let created: OpaquePointer? = model.withCString { m in
            tokens.withCString { t in
                data.withCString { d in
                    "cpu".withCString { p in
                        config.model.vits.model = m
                        config.model.vits.tokens = t
                        config.model.vits.data_dir = d
                        config.model.vits.noise_scale = 0.667
                        config.model.vits.noise_scale_w = 0.8
                        config.model.vits.length_scale = 1.0
                        config.model.num_threads = 2
                        config.model.provider = p
                        config.max_num_sentences = 2
                        return SherpaOnnxCreateOfflineTts(&config)
                    }
                }
            }
        }
        guard let created else { Log.error("LocalTTS: không nạp được model \(voiceID)"); return false }
        tts = created
        loadedVoice = voiceID
        sampleRate = Double(SherpaOnnxOfflineTtsSampleRate(created))
        Log.info("LocalTTS: nạp giọng \(voiceID) trong \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(Int(sampleRate)) Hz")
        return true
    }

    /// Gọi trên `queue`.
    func synthesize(_ text: String, speed: Float) -> [Float]? {
        guard let tts else { return nil }
        guard let audio = text.withCString({ SherpaOnnxOfflineTtsGenerate(tts, $0, 0, speed) }) else { return nil }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let n = Int(audio.pointee.n)
        guard n > 0, let p = audio.pointee.samples else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    func unload() {
        if let tts { SherpaOnnxDestroyOfflineTts(tts) }
        tts = nil
        loadedVoice = ""
    }

    deinit { unload() }
}
