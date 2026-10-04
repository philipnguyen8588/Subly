import Foundation
import CoreVideo

/// Chữ ký 64×8 (độ sáng trung bình theo ô) để phát hiện thay đổi rẻ tiền.
/// Việc "chờ ổn định" do RegionWorker xử lý bằng timer, vì SCStream chỉ gửi frame khi màn hình đổi.
final class FrameGate {
    enum Verdict { case first, changed(Double), unchanged(Double) }

    var threshold: Double
    private let gw = 64, gh = 8
    private var last: [UInt8]?

    init(threshold: Double = 4) { self.threshold = threshold }

    func reset() { last = nil }

    func process(_ pb: CVPixelBuffer) -> Verdict? {
        guard let sig = signature(pb) else { return nil }
        defer { last = sig }
        guard let prev = last else { return .first }
        let diff = meanAbsDiff(sig, prev)
        // Phụ đề đổi trên nền đứng yên chỉ làm đổi vài chục ô trong 512 ô nên trung bình cả vùng vẫn dưới ngưỡng
        // → xét thêm số ô đổi rõ: từ `minCells` ô lệch quá `cellDelta` mức sáng cũng coi là đổi.
        if diff <= threshold, changedCells(sig, prev) >= minCells { return .changed(diff) }
        return diff > threshold ? .changed(diff) : .unchanged(diff)
    }

    private let cellDelta = 12, minCells = 5
    private func changedCells(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        for i in 0..<min(a.count, b.count) where abs(Int(a[i]) - Int(b[i])) > cellDelta { n += 1 }
        return n
    }

    private func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0
        for i in 0..<min(a.count, b.count) { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(max(1, a.count))
    }

    private func signature(_ pb: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)

        var out = [UInt8](repeating: 0, count: gw * gh)
        let cellW = max(1, w / gw), cellH = max(1, h / gh)
        let step = max(1, min(cellW, cellH) / 4)
        for gy in 0..<gh {
            let y0 = gy * h / gh, y1 = min(h, (gy + 1) * h / gh)
            for gx in 0..<gw {
                let x0 = gx * w / gw, x1 = min(w, (gx + 1) * w / gw)
                var acc = 0, n = 0
                var y = y0
                while y < y1 {
                    let row = p + y * bpr
                    var x = x0
                    while x < x1 {
                        let px = row + x * 4
                        acc += (Int(px[2]) * 77 + Int(px[1]) * 150 + Int(px[0]) * 29) >> 8
                        n += 1
                        x += step
                    }
                    y += step
                }
                out[gy * gw + gx] = UInt8(clamping: n > 0 ? acc / n : 0)
            }
        }
        return out
    }
}
