import Foundation
import AVFoundation

/// Phát mẫu PCM Float32 mono (giọng AI offline). Xếp nối tiếp hoặc cắt câu đang phát.
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let lock = NSLock()
    /// Thời điểm ước tính phát xong mọi thứ đã xếp hàng (để biết có đang tồn câu không).
    private(set) var busyUntil = Date.distantPast
    private var idleWork: DispatchWorkItem?
    private let idleQueue = DispatchQueue(label: "pcm.idle")

    var volume: Float = 1 { didSet { node.volume = volume } }

    init() { engine.attach(node) }

    func play(samples: [Float], sampleRate: Double, flush: Bool) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if format?.sampleRate != sampleRate {
            node.stop()
            if format != nil { engine.disconnectNodeOutput(node) }
            let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            engine.connect(node, to: engine.mainMixerNode, format: f)
            format = f
        }
        guard let format, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if flush { node.stop() }
        if !engine.isRunning {
            do { try engine.start() } catch { Log.error("AVAudioEngine start: \(error.localizedDescription)"); return }
        }
        node.volume = volume
        let now = Date()
        busyUntil = (flush || busyUntil < now ? now : busyUntil).addingTimeInterval(Double(samples.count) / sampleRate)
        node.scheduleBuffer(buf, completionHandler: nil)
        if !node.isPlaying { node.play() }
        scheduleIdlePauseLocked()
    }

    /// Engine chạy không tải vẫn render im lặng liên tục (tốn CPU, giữ thiết bị âm thanh thức)
    /// → tạm dừng khi đã phát xong 5 s; câu kế tiếp tự bật lại.
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

    func stop() {
        lock.lock(); defer { lock.unlock() }
        node.stop()
        busyUntil = .distantPast
        idleWork?.cancel(); idleWork = nil
        if engine.isRunning { engine.pause() }
    }
}
