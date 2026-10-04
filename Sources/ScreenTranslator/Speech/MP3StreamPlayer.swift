import Foundation
import AVFoundation
import AudioToolbox

/// Phát MP3 dạng streaming: nhận từng mẩu dữ liệu, giải mã và xếp vào AVAudioPlayerNode ngay,
/// không cần đợi đủ file. Dùng cho Edge TTS để có tiếng sau ~0,2–0,3 s.
final class MP3StreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var streamID: AudioFileStreamID?
    private var srcFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private(set) var scheduledFrames: AVAudioFrameCount = 0
    /// Thời điểm ước tính phát xong mọi thứ đã xếp hàng.
    private var busyUntil = Date.distantPast
    private var idleWork: DispatchWorkItem?
    private let idleQueue = DispatchQueue(label: "mp3.idle")

    var volume: Float = 1 { didSet { node.volume = volume } }

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outFormat)
    }

    /// Bắt đầu một câu mới. `flush` = cắt ngay câu đang phát; false = xếp nối tiếp sau câu trước.
    func begin(flush: Bool) {
        lock.lock(); defer { lock.unlock() }
        if flush { node.stop(); busyUntil = Date() }
        closeStreamLocked()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(ctx, mp3PropertyProc, mp3PacketsProc, kAudioFileMP3Type, &streamID)
        scheduledFrames = 0
        startEngineLocked()
        scheduleIdlePauseLocked()
    }

    private func startEngineLocked() {
        if !engine.isRunning {
            do { try engine.start() } catch { Log.error("AVAudioEngine start: \(error.localizedDescription)") }
        }
        if !node.isPlaying { node.play() }
    }

    /// Engine chạy không tải vẫn render im lặng liên tục (tốn CPU, giữ thiết bị âm thanh thức)
    /// → tạm dừng khi đã phát xong 5 s; mẩu âm thanh kế tiếp tự bật lại.
    private func scheduleIdlePauseLocked() {
        idleWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard Date() >= self.busyUntil, self.engine.isRunning else { return }
            self.node.stop()
            self.engine.pause()
        }
        idleWork = item
        idleQueue.asyncAfter(deadline: .now() + max(0, busyUntil.timeIntervalSinceNow) + 5, execute: item)
    }

    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let s = streamID, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            _ = AudioFileStreamParseBytes(s, UInt32(data.count), raw.baseAddress, [])
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        node.stop()
        closeStreamLocked()
        idleWork?.cancel(); idleWork = nil
        busyUntil = .distantPast
        if engine.isRunning { engine.pause() }
    }

    private func closeStreamLocked() {
        if let s = streamID { AudioFileStreamClose(s); streamID = nil }
        converter = nil
        srcFormat = nil
    }

    // MARK: callbacks (gọi trong feed → đang giữ lock)

    fileprivate func handleProperty(_ id: AudioFileStreamPropertyID) {
        guard id == kAudioFileStreamProperty_DataFormat, let s = streamID else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(s, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
              let f = AVAudioFormat(streamDescription: &asbd) else { return }
        srcFormat = f
        converter = AVAudioConverter(from: f, to: outFormat)
    }

    fileprivate func handlePackets(bytes: UInt32, count: UInt32, data: UnsafeRawPointer,
                                   descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let src = srcFormat, let conv = converter, count > 0, bytes > 0, let descs else { return }
        let comp = AVAudioCompressedBuffer(format: src, packetCapacity: count, maximumPacketSize: Int(bytes))
        memcpy(comp.data, data, Int(bytes))
        comp.byteLength = bytes
        comp.packetCount = count
        if let pd = comp.packetDescriptions {
            for i in 0..<Int(count) { pd[i] = descs[i] }
        }
        let fpp = max(src.streamDescription.pointee.mFramesPerPacket, 576)
        let ratio = outFormat.sampleRate / max(src.sampleRate, 1)
        let cap = AVAudioFrameCount(Double(count * fpp) * ratio) + 2048
        guard let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: pcm, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return comp
        }
        guard status != .error, pcm.frameLength > 0 else { return }
        scheduledFrames += pcm.frameLength
        let now = Date()
        busyUntil = (busyUntil < now ? now : busyUntil).addingTimeInterval(Double(pcm.frameLength) / outFormat.sampleRate)
        node.scheduleBuffer(pcm, completionHandler: nil)
        startEngineLocked()      // có thể đã tạm dừng vì im lặng trong lúc chờ mẩu âm thanh đầu
        scheduleIdlePauseLocked()
    }
}

private func mp3PropertyProc(_ ctx: UnsafeMutableRawPointer, _ stream: AudioFileStreamID,
                             _ prop: AudioFileStreamPropertyID,
                             _ flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    Unmanaged<MP3StreamPlayer>.fromOpaque(ctx).takeUnretainedValue().handleProperty(prop)
}

private func mp3PacketsProc(_ ctx: UnsafeMutableRawPointer, _ bytes: UInt32, _ count: UInt32,
                            _ data: UnsafeRawPointer,
                            _ descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    Unmanaged<MP3StreamPlayer>.fromOpaque(ctx).takeUnretainedValue()
        .handlePackets(bytes: bytes, count: count, data: data, descs: descs)
}
